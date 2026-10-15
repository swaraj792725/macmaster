import AppKit
import CoreGraphics
import Carbon.HIToolbox
import os

// MARK: - Tap runner (own thread)

private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardTapRunner>.fromOpaque(refcon).takeUnretainedValue().dispatch(type, event)
}

/// Owns a CGEventTap and the thread/run loop it lives on. Re-enables the tap when the system disables it.
final class KeyboardTapRunner: @unchecked Sendable {
    private let name: String
    private let mask: CGEventMask
    private let handler: (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private let onDisabled: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private let doneSem = DispatchSemaphore(value: 0)

    init(name: String, types: [CGEventType], extraRawTypes: [UInt32] = [],
         onDisabled: @escaping () -> Void = {},
         handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        self.name = name
        var m = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        for raw in extraRawTypes { m |= CGEventMask(1) << CGEventMask(raw) }
        self.mask = m
        self.handler = handler
        self.onDisabled = onDisabled
    }

    var isEnabled: Bool {
        guard let t = tap else { return false }
        return CGEvent.tapIsEnabled(tap: t)
    }

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
        th.name = name
        th.qualityOfService = .userInteractive
        th.start()
        _ = ready.wait(timeout: .now() + 3)
        if !ok.withLock({ $0 }) {
            _ = doneSem.wait(timeout: .now() + 1)
            runLoop = nil
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
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyboardTapCallback,
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

    fileprivate func dispatch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            onDisabled()
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}

// MARK: - Main tap: Hyper, snippets, visualizer, ⌘Q guard

struct KeyboardTapSnippet {
    let chars: [UInt16]
    let text: String
}

/// Immutable snapshot of what the tap should do. Swapped atomically from the main actor.
final class KeyboardTapConfig: @unchecked Sendable {
    let hyper: KeyboardHyperKey?
    let tapEscape: Bool
    let snippets: [KeyboardTapSnippet]
    let visualizer: Bool
    let cmdQ: Bool

    init(hyper: KeyboardHyperKey?, tapEscape: Bool, snippets: [KeyboardTapSnippet], visualizer: Bool, cmdQ: Bool) {
        self.hyper = hyper; self.tapEscape = tapEscape; self.snippets = snippets
        self.visualizer = visualizer; self.cmdQ = cmdQ
    }

    var needsTap: Bool { hyper != nil || !snippets.isEmpty || visualizer || cmdQ }
    static let off = KeyboardTapConfig(hyper: nil, tapEscape: false, snippets: [], visualizer: false, cmdQ: false)
}

enum KeyboardTapOutput: Sendable {
    case snippet(text: String, backspaces: Int)
    case key(code: UInt16, flags: UInt64, char: UInt16)
    case cmdQBegan(token: UInt64)
    case cmdQEnded
}

final class KeyboardMainTap: @unchecked Sendable {
    private static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let modMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let bufferCap = 32

    private let config = OSAllocatedUnfairLock<KeyboardTapConfig>(initialState: .off)
    /// Token of the ⌘Q press that is currently held (0 = none). Read on the main thread.
    let cmdQToken = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let output: @Sendable (KeyboardTapOutput) -> Void
    private var runner: KeyboardTapRunner?

    // State below is only touched on the tap thread.
    private var hyperDown = false
    private var hyperOther = false
    private var hyperStart: UInt64 = 0
    private var qDown = false
    private var qCounter: UInt64 = 0
    private var swallowUp = -1
    private let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: KeyboardMainTap.bufferCap)
    private var bufferCount = 0
    private let scratch = UnsafeMutablePointer<UniChar>.allocate(capacity: 8)

    init(output: @escaping @Sendable (KeyboardTapOutput) -> Void) {
        self.output = output
    }

    deinit {
        buffer.deallocate()
        scratch.deallocate()
    }

    var isRunning: Bool { runner != nil }
    var isEnabled: Bool { runner?.isEnabled ?? false }

    func update(_ cfg: KeyboardTapConfig) { config.withLock { $0 = cfg } }

    func start() -> Bool {
        guard runner == nil else { return true }
        let r = KeyboardTapRunner(name: "MacMaster.KeyboardTap",
                                  types: [.keyDown, .keyUp, .flagsChanged],
                                  onDisabled: { [weak self] in self?.resetState() },
                                  handler: { [weak self] type, event in
                                      self?.handle(type, event) ?? Unmanaged.passUnretained(event)
                                  })
        guard r.start() else { return false }
        runner = r
        return true
    }

    func stop() {
        runner?.stop()
        runner = nil // breaks the runner -> handler -> self cycle
        cmdQToken.withLock { $0 = 0 }
    }

    private func resetState() {
        hyperDown = false; hyperOther = false; qDown = false; swallowUp = -1; bufferCount = 0
        cmdQToken.withLock { $0 = 0 }
    }

    // MARK: Callback (keep fast: no allocations on the hot path)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardKeyPoster.marker { return pass }
        let cfg = config.withLock { $0 }

        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let raw = event.flags.rawValue
            if cfg.hyper == .rightCommand, code == 54 { hyperDown = raw & 0x10 != 0; hyperOther = false }
            else if cfg.hyper == .rightOption, code == 61 { hyperDown = raw & 0x40 != 0; hyperOther = false }
            if qDown, !event.flags.contains(.maskCommand) { endCmdQ() }
            return pass

        case .keyDown, .keyUp:
            let isDown = type == .keyDown
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

            if cfg.hyper == .caps, code == 79 { return handleF18(isDown: isDown, event: event, cfg: cfg) }
            if cfg.hyper == nil { hyperDown = false }
            if hyperDown {
                hyperOther = true
                event.flags = event.flags.union(Self.hyperFlags)
            }
            if !isDown, code == swallowUp { swallowUp = -1; return nil }

            let flags = event.flags
            if cfg.cmdQ, code == 12, handleCmdQ(isDown: isDown, flags: flags) { return nil }

            if isDown {
                if cfg.visualizer, !IsSecureEventInputEnabled() {
                    let ch = flags.contains(.maskCommand) || flags.contains(.maskControl) ? 0 : firstChar(event)
                    output(.key(code: UInt16(truncatingIfNeeded: code), flags: flags.rawValue, char: ch))
                }
                if !cfg.snippets.isEmpty, handleSnippets(code: code, flags: flags, event: event, cfg: cfg) {
                    swallowUp = code
                    return nil
                }
            }
            return pass

        default:
            return pass
        }
    }

    // MARK: Hyper

    private func handleF18(isDown: Bool, event: CGEvent, cfg: KeyboardTapConfig) -> Unmanaged<CGEvent>? {
        if isDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            if !hyperDown { hyperDown = true; hyperOther = false; hyperStart = DispatchTime.now().uptimeNanoseconds }
        } else {
            let was = hyperDown
            hyperDown = false
            let held = DispatchTime.now().uptimeNanoseconds &- hyperStart
            if was, !hyperOther, cfg.tapEscape, held < 700_000_000 { KeyboardKeyPoster.tap(53) }
        }
        return nil
    }

    // MARK: ⌘Q guard

    private func handleCmdQ(isDown: Bool, flags: CGEventFlags) -> Bool {
        if isDown {
            guard flags.intersection(Self.modMask) == .maskCommand else { return false }
            if qDown { return true } // auto-repeat
            qDown = true
            qCounter &+= 1
            let token = qCounter
            cmdQToken.withLock { $0 = token }
            output(.cmdQBegan(token: token))
            return true
        }
        if qDown { endCmdQ(); return true }
        return false
    }

    private func endCmdQ() {
        qDown = false
        cmdQToken.withLock { $0 = 0 }
        output(.cmdQEnded)
    }

    // MARK: Snippets (rolling buffer of at most 32 UTF-16 units, memory only)

    private func firstChar(_ event: CGEvent) -> UInt16 {
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: scratch)
        return len > 0 ? scratch[0] : 0
    }

    private func handleSnippets(code: Int, flags: CGEventFlags, event: CGEvent, cfg: KeyboardTapConfig) -> Bool {
        if IsSecureEventInputEnabled() { bufferCount = 0; return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { bufferCount = 0; return false }
        switch code {
        case 51: // delete
            if bufferCount > 0 { bufferCount -= 1 }
            return false
        case 36, 76, 48, 53, 117, 115, 116, 119, 121, 123, 124, 125, 126:
            bufferCount = 0
            return false
        default: break
        }
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: scratch)
        guard len > 0 else { return false }
        for i in 0..<len {
            let c = scratch[i]
            if c < 32 { bufferCount = 0; return false }
            if bufferCount == Self.bufferCap {
                buffer.update(from: buffer + 1, count: Self.bufferCap - 1)
                bufferCount -= 1
            }
            buffer[bufferCount] = c
            bufferCount += 1
        }
        for s in cfg.snippets {
            let n = s.chars.count
            guard n > 0, bufferCount >= n else { continue }
            var match = true
            let base = bufferCount - n
            for i in 0..<n where buffer[base + i] != s.chars[i] { match = false; break }
            if match {
                bufferCount = 0
                output(.snippet(text: s.text, backspaces: n - 1)) // last char is swallowed, not typed
                return true
            }
        }
        return false
    }
}

// MARK: - Cleaning-mode tap (swallows keyboard, mouse and trackpad input)

final class KeyboardCleaningTap: @unchecked Sendable {
    /// Uptime (ns) at which ⌘⌥⌃ went down; 0 when not all three are held.
    let holdStart = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let deadline: UInt64
    private var runner: KeyboardTapRunner?
    private var localHold: UInt64 = 0

    init(deadlineUptime: UInt64) { deadline = deadlineUptime }

    func start() -> Bool {
        // 14 = system-defined (media keys), 29...32 = gestures, 34 = pressure
        let r = KeyboardTapRunner(
            name: "MacMaster.KeyboardCleaningTap",
            types: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                    .mouseMoved, .scrollWheel],
            extraRawTypes: [14, 29, 30, 31, 32, 34],
            handler: { [weak self] type, event in
                self?.handle(type, event) ?? Unmanaged.passUnretained(event)
            })
        guard r.start() else { return false }
        runner = r
        return true
    }

    var isEnabled: Bool { runner?.isEnabled ?? false }

    func stop() {
        runner?.stop()
        runner = nil
        holdStart.withLock { $0 = 0 }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = DispatchTime.now().uptimeNanoseconds
        // Safety net: never swallow anything past the deadline, even if the main thread is stuck.
        if now >= deadline { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardKeyPoster.marker { return Unmanaged.passUnretained(event) }
        if type == .flagsChanged {
            let f = event.flags
            if f.contains(.maskCommand) && f.contains(.maskAlternate) && f.contains(.maskControl) {
                if localHold == 0 { localHold = now; holdStart.withLock { $0 = now } }
            } else if localHold != 0 {
                localHold = 0
                holdStart.withLock { $0 = 0 }
            }
        }
        return nil
    }
}
