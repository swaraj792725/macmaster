import AppKit
import CoreGraphics
import os

private let tilingModDragCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TilingModifierDragTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

/// Linux-style window drag: hold the modifier and left-drag to move, right-drag to resize from the nearest
/// corner. Events are consumed only while the exact modifier combo is held. Runs on its own thread.
final class TilingModifierDragTap: @unchecked Sendable {
    private let modifier: OSAllocatedUnfairLock<CGEventFlags>

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private let doneSem = DispatchSemaphore(value: 0)

    // Tap-thread state
    private enum Mode { case none, move, resize }
    private var mode: Mode = .none
    private var window: TilingWindow?
    private var startMouse = CGPoint.zero
    private var startFrame = CGRect.zero
    private var anchorLeft = false   // resize: grabbing the left edge
    private var anchorTop = false    // resize: grabbing the top edge

    // Work handed to the AX queue (latest value wins).
    private let applyQueue = DispatchQueue(label: "MacMaster.Tiling.modDrag.apply", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: (TilingWindow, CGRect, Bool)?
    private var scheduled = false

    private static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init(modifier: CGEventFlags) { self.modifier = OSAllocatedUnfairLock(initialState: modifier) }

    func setModifier(_ f: CGEventFlags) { modifier.withLock { $0 = f } }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let ok = OSAllocatedUnfairLock(initialState: false)
        let th = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            ok.withLock { $0 = install() }
            ready.signal()
            if ok.withLock({ $0 }) { CFRunLoopRun() }
            doneSem.signal()
        }
        th.name = "MacMaster.TilingModDragTap"
        th.qualityOfService = .userInteractive
        th.start()
        _ = ready.wait(timeout: .now() + 3)
        if !ok.withLock({ $0 }) {
            _ = doneSem.wait(timeout: .now() + 1)
            return false
        }
        return true
    }

    func stop() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let src = source { CFRunLoopRemoveSource(rl, src, .commonModes); CFRunLoopSourceInvalidate(src) }
            if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
            source = nil
            tap = nil
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
        _ = doneSem.wait(timeout: .now() + 1.5)
        runLoop = nil
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tilingModDragCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) else {
            CFMachPortInvalidate(t)
            return false
        }
        tap = t
        source = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    // MARK: Event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            mode = .none
            window = nil
            return pass

        case .leftMouseDown, .rightMouseDown:
            let flags = event.flags.intersection(Self.relevant)
            guard flags == modifier.withLock({ $0 }).intersection(Self.relevant), mode == .none else { return pass }
            let p = event.location
            guard let w = TilingAX.window(at: p), let f = TilingAX.frame(w.element) else { return pass }
            window = w
            startMouse = p
            startFrame = f
            if type == .leftMouseDown {
                mode = .move
            } else {
                mode = .resize
                anchorLeft = p.x < f.midX
                anchorTop = p.y < f.midY
            }
            applyQueue.async { TilingAX.raise(w) }
            return nil

        case .leftMouseDragged:
            guard mode == .move, let w = window else { return pass }
            let p = event.location
            let r = CGRect(x: startFrame.minX + p.x - startMouse.x, y: startFrame.minY + p.y - startMouse.y,
                           width: startFrame.width, height: startFrame.height)
            submit(w, r, resize: false)
            return nil

        case .rightMouseDragged:
            guard mode == .resize, let w = window else { return pass }
            let p = event.location
            let dx = p.x - startMouse.x, dy = p.y - startMouse.y
            var r = startFrame
            let minW: CGFloat = 140, minH: CGFloat = 90
            if anchorLeft {
                let nw = max(minW, startFrame.width - dx)
                r.origin.x = startFrame.maxX - nw
                r.size.width = nw
            } else {
                r.size.width = max(minW, startFrame.width + dx)
            }
            if anchorTop {
                let nh = max(minH, startFrame.height - dy)
                r.origin.y = startFrame.maxY - nh
                r.size.height = nh
            } else {
                r.size.height = max(minH, startFrame.height + dy)
            }
            submit(w, r, resize: true)
            return nil

        case .leftMouseUp:
            guard mode == .move else { return pass }
            finish()
            return nil

        case .rightMouseUp:
            guard mode == .resize else { return pass }
            finish()
            return nil

        default:
            return pass
        }
    }

    private func finish() {
        mode = .none
        window = nil
    }

    // MARK: AX worker

    private func submit(_ w: TilingWindow, _ r: CGRect, resize: Bool) {
        pendingLock.lock()
        pending = (w, r, resize)
        let needsSchedule = !scheduled
        scheduled = true
        pendingLock.unlock()
        if needsSchedule { applyQueue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard let job = pending else { scheduled = false; pendingLock.unlock(); return }
            pending = nil
            pendingLock.unlock()
            let (w, r, resize) = job
            if resize { TilingAX.setSize(w.element, r.size) }
            TilingAX.setPosition(w.element, r.origin)
        }
    }
}
