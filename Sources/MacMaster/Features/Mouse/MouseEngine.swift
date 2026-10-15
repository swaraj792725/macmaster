import AppKit
import CoreGraphics
import os

private let mouseLog = Logger(subsystem: "com.macmaster.app", category: "mouse")

// MARK: - Engine (main actor facade)

@MainActor
final class MouseEngine: ObservableObject {
    static let shared = MouseEngine()

    enum Status: Equatable {
        case off, running, needsAccessibility, failed
        var text: String {
            switch self {
            case .off: return "Off"
            case .running: return "Running"
            case .needsAccessibility: return "Needs Accessibility"
            case .failed: return "Couldn’t start"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var pointerStatus: String = "System default"

    private var core: MouseTapCore?
    private var pollTask: Task<Void, Never>?
    private var started = false

    private var terminateObserver: NSObjectProtocol?

    private init() {}

    /// Idempotent. Honors the master toggle; keeps polling until Accessibility is granted.
    func start() {
        started = true
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MousePointerControl.reset()
                    MouseEngine.shared.stop()
                }
            }
        }
        guard MouseSettings.shared.enabled else {
            tearDownCore()
            status = .off
            return
        }
        attemptStart()
        beginPolling()
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        tearDownCore()
        MousePointerControl.reset()
        pointerStatus = "System default"
        status = .off
    }

    /// Called by `MouseSettings` whenever anything changes.
    func settingsChanged() {
        guard started else { return }
        if MouseSettings.shared.enabled {
            if core == nil { attemptStart() } else { applyPointer() }
            beginPolling()
        } else {
            tearDownCore()
            MousePointerControl.reset()
            pointerStatus = "System default"
            status = .off
        }
    }

    func resetPointer() {
        var c = MouseSettings.shared.config
        c.disableAcceleration = false
        c.customPointerSpeed = false
        MouseSettings.shared.config = c
        pointerStatus = MousePointerControl.reset()
    }

    // MARK: Internals

    private func attemptStart() {
        guard MouseSettings.shared.enabled else { return }
        guard Permissions.isGranted(.accessibility) else {
            tearDownCore()
            status = .needsAccessibility
            return
        }
        if core != nil { return }
        let c = MouseTapCore(config: MouseSettings.shared.snapshot)
        if c.start() {
            core = c
            status = .running
            MouseStatsStore.shared.startFlushing()
            applyPointer()
        } else {
            status = .failed
        }
    }

    private func applyPointer() {
        pointerStatus = MousePointerControl.apply(MouseSettings.shared.config)
    }

    private func tearDownCore() {
        guard let c = core else { return }
        c.stop()
        core = nil
        MouseStatsStore.shared.stopFlushing()
    }

    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard MouseSettings.shared.enabled else { continue }
                if self.core == nil {
                    self.attemptStart()
                } else if !Permissions.isGranted(.accessibility) {
                    // Permission revoked while running.
                    self.tearDownCore()
                    self.status = .needsAccessibility
                } else if let c = self.core, !c.isHealthy {
                    // Tap died or stayed disabled (e.g. after Accessibility was toggled): rebuild it.
                    mouseLog.error("mouse tap unhealthy; restarting")
                    self.tearDownCore()
                    self.attemptStart()
                }
            }
        }
    }
}

// MARK: - Tap core (runs entirely off the main thread)

private let mouseTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let core = Unmanaged<MouseTapCore>.fromOpaque(refcon).takeUnretainedValue()
    return core.handle(type: type, event: event)
}

final class MouseTapCore: @unchecked Sendable {
    private let config: OSAllocatedUnfairLock<MouseConfig>
    private let scroller = MouseSmoothScroller()
    private let stats = MouseStatsStore.shared
    private let telemetry = MouseTelemetry.shared

    // Tap-thread-only state
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let doneSem = DispatchSemaphore(value: 0)

    private struct ButtonState {
        var mapping = MouseButtonMapping()
        var firedOnDown = false
        var holdFired = false
        /// Moved past the slop with a drag mode set: no click on release.
        var dragging = false
        var totalX = 0.0, totalY = 0.0      // since the press, for the slop test
        var accX = 0.0, accY = 0.0          // since the last fired drag step
        var firedDirections: Set<Int> = []  // non-repeatable actions fire once per direction
        var scrollBegan = false
        var remX = 0.0, remY = 0.0          // fractional scroll pixels carried over
        var anchor = CGPoint.zero
        var frozeCursor = false
        var holdTimer: CFRunLoopTimer?
        var pressedAt = 0.0
        /// A drag step ran a discrete action (Space switch, Mission Control, custom): the press was a gesture.
        var dragFired = false
    }
    private var buttons: [Int: ButtonState] = [:]
    private var pendingClicks: [Int: CFRunLoopTimer] = [:]

    private var lastWheelTime = 0.0
    private var emaRate = 0.0

    private static let pixelsPerTick = 56.0
    private static let holdDelay = 0.4
    private static let doubleClickWindow = 0.28
    private static let dragSlop = 10.0
    /// A press this short that moved this little is a click, even if the hand nudged the mouse past the slop.
    private static let tapTime = 0.35
    private static let tapMove = 30.0

    init(config: OSAllocatedUnfairLock<MouseConfig>) {
        self.config = config
    }

    // MARK: Lifecycle

    /// False when the tap's port died or macOS left it disabled. Read off the tap thread: `tap` is only
    /// written before `start` returns and inside `stop`.
    var isHealthy: Bool {
        guard let t = tap else { return false }
        return CFMachPortIsValid(t) && CGEvent.tapIsEnabled(tap: t)
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let ok = OSAllocatedUnfairLock(initialState: false)
        let th = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            ok.withLock { $0 = installTap() }
            ready.signal()
            if ok.withLock({ $0 }) { CFRunLoopRun() }
            doneSem.signal()
        }
        th.name = "MacMaster.MouseTap"
        th.qualityOfService = .userInteractive
        thread = th
        th.start()
        _ = ready.wait(timeout: .now() + 3)
        if !ok.withLock({ $0 }) {
            _ = doneSem.wait(timeout: .now() + 1)
            thread = nil
            return false
        }
        return true
    }

    func stop() {
        if let rl = runLoop {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [self] in
                for (_, t) in pendingClicks { CFRunLoopTimerInvalidate(t) }
                pendingClicks.removeAll()
                for (_, s) in buttons {
                    if let t = s.holdTimer { CFRunLoopTimerInvalidate(t) }
                    if s.frozeCursor { CGAssociateMouseAndMouseCursorPosition(1) }
                }
                buttons.removeAll()
                if let src = source { CFRunLoopRemoveSource(rl, src, .commonModes); CFRunLoopSourceInvalidate(src) }
                if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
                source = nil
                tap = nil
                CFRunLoopStop(rl)
            }
            CFRunLoopWakeUp(rl)
            _ = doneSem.wait(timeout: .now() + 1.5)
        }
        scroller.shutdown()
        runLoop = nil
        thread = nil
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp,
                                    .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: mouseTapCallback,
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
            return pass
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == mouseSyntheticMagic { return pass }

        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .leftMouseDown:
            stats.recordClick(button: 0)
            return pass
        case .rightMouseDown:
            stats.recordClick(button: 1)
            return pass
        case .otherMouseDown:
            return handleButtonDown(event)
        case .otherMouseUp:
            return handleButtonUp(event)
        case .otherMouseDragged:
            return handleButtonDrag(event)
        default:
            return pass
        }
    }

    // MARK: Scrolling

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if continuous || phase != 0 || momentum != 0 {
            // Trackpad / Magic Mouse: never touched.
            if telemetry.isRecording {
                let py = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                let px = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                if py != 0 || px != 0 { telemetry.recordRaw(hypot(py, px), device: "Trackpad / Magic Mouse") }
            }
            return pass
        }

        let cfg = config.withLock { $0 }
        let flags = event.flags

        var dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if dy == 0 { dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) }
        if dx == 0 { dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) }
        if dy == 0 && dx == 0 { return pass }
        telemetry.recordRaw(hypot(dy, dx) * Self.pixelsPerTick, device: "Mouse wheel")

        // ⌘ + scroll → zoom in apps; leave untouched except direction.
        let commandPass = cfg.commandZoomPassthrough && flags.contains(.maskCommand)

        var newFlags = flags
        var swapped = false
        if cfg.shiftHorizontal && flags.contains(.maskShift) && !commandPass {
            swap(&dy, &dx)
            newFlags.remove(.maskShift)
            swapped = true
        }
        if cfg.reverseVertical { dy = -dy }
        if cfg.reverseHorizontal { dx = -dx }
        // When axes were swapped the user's "vertical" intent is now horizontal; direction flags above
        // already apply to the resulting axes.

        var speedFactor = 1.0
        if !commandPass {
            if cfg.optionPrecise && flags.contains(.maskAlternate) {
                speedFactor = cfg.preciseFactor
                newFlags.remove(.maskAlternate)
            } else if cfg.controlFast && flags.contains(.maskControl) {
                speedFactor = cfg.fastFactor
                newFlags.remove(.maskControl)
            }
        }

        if cfg.smoothEnabled && !commandPass {
            // Smooth path: swallow the wheel tick, feed the animator.
            let now = MouseSmoothScroller.now()
            let interval = now - lastWheelTime
            lastWheelTime = now
            let rate = 1 / max(interval, 0.004)
            emaRate = interval > 0.3 ? 0 : (emaRate == 0 ? rate : emaRate * 0.5 + rate * 0.5)
            let t = max(0, min(1, (emaRate - 5) / 30))
            let accel = 1 + cfg.acceleration.gain * (t * t * (3 - 2 * t))

            func px(_ d: Double) -> Double {
                guard d != 0 else { return 0 }
                let ticks = max(-4, min(4, d))
                return ticks * Self.pixelsPerTick * cfg.speed * speedFactor * accel
            }
            if scroller.add(dy: px(dy), dx: px(dx), flags: newFlags,
                            params: .init(tau: cfg.smoothness.tau, inertia: cfg.inertia)) {
                return nil
            }
            // Animator was stalled and has been restarted: let this tick through as a plain scroll.
        }

        writeInPlace(event, swapped: swapped, negY: cfg.reverseVertical, negX: cfg.reverseHorizontal,
                     scale: commandPass ? 1 : speedFactor, flags: newFlags)
        let pts = hypot(Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                        Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)))
        stats.recordScroll(pixels: pts)
        return pass
    }

    /// Rewrite a discrete wheel event (reverse / swap / scale) without smoothing.
    private func writeInPlace(_ e: CGEvent, swapped: Bool, negY: Bool, negX: Bool, scale: Double, flags: CGEventFlags) {
        let line1 = Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let line2 = Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let pt1 = Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let pt2 = Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let fx1 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fx2 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let (l1, l2) = swapped ? (line2, line1) : (line1, line2)
        let (p1, p2) = swapped ? (pt2, pt1) : (pt1, pt2)
        let (f1, f2) = swapped ? (fx2, fx1) : (fx1, fx2)

        func scaled(_ v: Double, _ neg: Bool) -> Double { v * scale * (neg ? -1 : 1) }
        func whole(_ v: Double) -> Int64 {
            let r = Int64(v.rounded())
            return r == 0 && v != 0 ? (v < 0 ? -1 : 1) : r
        }
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: whole(scaled(l1, negY)))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: whole(scaled(l2, negX)))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: whole(scaled(p1, negY)))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: whole(scaled(p2, negX)))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: scaled(f1, negY))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: scaled(f2, negX))
        e.flags = flags
    }

    // MARK: Buttons

    private func handleButtonDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        stats.recordClick(button: b)
        telemetry.recordButton(b, down: true)
        let cfg = config.withLock { $0 }
        let mapping = cfg.mappings[b] ?? MouseButtonMapping()
        guard mapping.isManaged else { return Unmanaged.passUnretained(event) }

        var st = ButtonState()
        st.mapping = mapping
        st.anchor = event.location
        st.pressedAt = CFAbsoluteTimeGetCurrent()
        if mapping.hold.kind != .none {
            st.holdTimer = makeTimer(after: Self.holdDelay) { [weak self] in self?.holdFired(b) }
        }
        let clickIsReplay = mapping.click.kind == .none || mapping.click.kind == .middleClick
        let deferred = mapping.drag != .none || mapping.hold.kind != .none || mapping.doubleClick.kind != .none || clickIsReplay
        if !deferred {
            MouseActionRunner.run(mapping.click, button: b)
            st.firedOnDown = true
        }
        buttons[b] = st
        return nil
    }

    private func handleButtonDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard var st = buttons[b] else { return Unmanaged.passUnretained(event) }
        let mode = st.mapping.drag
        // The original drag is always suppressed while a managed button is down.
        guard mode != .none, !st.holdFired, !st.firedOnDown else { return nil }
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        st.totalX += dx; st.totalY += dy
        st.accX += dx; st.accY += dy

        if !st.dragging {
            guard hypot(st.totalX, st.totalY) >= Self.dragSlop else { buttons[b] = st; return nil }
            st.dragging = true
            if let t = st.holdTimer { CFRunLoopTimerInvalidate(t); st.holdTimer = nil }
            if mode == .scroll || mode == .horizontalScroll {
                // Keep the pointer still so the scroll target stays under it (like grabbing the page).
                CGAssociateMouseAndMouseCursorPosition(0)
                st.frozeCursor = true
            }
        }

        let cfg = config.withLock { $0 }
        let threshold = max(10, cfg.gestureThreshold)
        switch mode {
        case .none:
            break
        case .scroll, .horizontalScroll:
            postDragScroll(&st, dx: st.accX, dy: mode == .horizontalScroll ? 0 : st.accY, phaseEnd: false)
            st.accX = 0; st.accY = 0
        case .spaces:
            if abs(st.accX) >= threshold, abs(st.accX) >= abs(st.accY) {
                // Drag left → the Space on the right comes in, like a trackpad swipe.
                MouseActionRunner.run(MouseAction(st.accX < 0 ? .spaceRight : .spaceLeft), button: b)
                st.dragFired = true
                st.accX = 0; st.accY = 0
            } else if abs(st.accY) >= threshold, abs(st.accY) > abs(st.accX) {
                let dir = st.accY < 0 ? 2 : 3
                if !st.firedDirections.contains(dir) {
                    st.firedDirections.insert(dir)
                    MouseActionRunner.run(MouseAction(dir == 2 ? .missionControl : .appExpose), button: b)
                    st.dragFired = true
                }
                st.accX = 0; st.accY = 0
            }
        case .custom:
            if hypot(st.accX, st.accY) >= threshold {
                let m = st.mapping
                let dir: Int
                let action: MouseAction
                if abs(st.accX) > abs(st.accY) {
                    dir = st.accX < 0 ? 0 : 1
                    action = dir == 0 ? m.dragLeft : m.dragRight
                } else {
                    dir = st.accY < 0 ? 2 : 3
                    action = dir == 2 ? m.dragUp : m.dragDown
                }
                if action.kind.repeatsWhileDragging || !st.firedDirections.contains(dir) {
                    st.firedDirections.insert(dir)
                    MouseActionRunner.run(action, button: b)
                    st.dragFired = true
                }
                st.accX = 0; st.accY = 0
            }
        }
        buttons[b] = st
        return nil
    }

    /// Grab-and-drag scrolling: pixel-precise, trackpad-like (continuous + phases) scroll events at the press point.
    private func postDragScroll(_ st: inout ButtonState, dx: Double, dy: Double, phaseEnd: Bool) {
        st.remX += dx; st.remY += dy
        let ix = st.remX.rounded(.towardZero), iy = st.remY.rounded(.towardZero)
        st.remX -= ix; st.remY -= iy
        if !phaseEnd && ix == 0 && iy == 0 { return }
        if phaseEnd && !st.scrollBegan { return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseEnd ? 4 : (st.scrollBegan ? 2 : 1))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        e.location = st.anchor
        e.post(tap: .cgSessionEventTap)
        st.scrollBegan = true
    }

    private func handleButtonUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        telemetry.recordButton(b, down: false)
        guard var st = buttons[b] else { return Unmanaged.passUnretained(event) }
        buttons[b] = nil
        if let t = st.holdTimer { CFRunLoopTimerInvalidate(t) }
        if st.frozeCursor { CGAssociateMouseAndMouseCursorPosition(1) }
        if st.scrollBegan { postDragScroll(&st, dx: 0, dy: 0, phaseEnd: true) }
        if st.firedOnDown || st.holdFired { return nil }
        if st.dragging {
            let quick = CFAbsoluteTimeGetCurrent() - st.pressedAt < Self.tapTime
            guard !st.dragFired, quick, hypot(st.totalX, st.totalY) < Self.tapMove else { return nil }
        }

        let m = st.mapping
        if m.doubleClick.kind != .none {
            if let pending = pendingClicks[b] {
                CFRunLoopTimerInvalidate(pending)
                pendingClicks[b] = nil
                MouseActionRunner.run(m.doubleClick, button: b)
            } else {
                pendingClicks[b] = makeTimer(after: Self.doubleClickWindow) { [weak self] in
                    self?.pendingClicks[b] = nil
                    self?.runClick(m.click, button: b)
                }
            }
        } else {
            runClick(m.click, button: b)
        }
        return nil
    }

    private func holdFired(_ b: Int) {
        guard var st = buttons[b], !st.dragging, !st.holdFired else { return }
        st.holdFired = true
        st.holdTimer = nil
        buttons[b] = st
        MouseActionRunner.run(st.mapping.hold, button: b)
    }

    private func runClick(_ action: MouseAction, button: Int) {
        switch action.kind {
        case .none, .middleClick: MouseActionRunner.replayClick(button: action.kind == .middleClick ? 2 : button)
        default: MouseActionRunner.run(action, button: button)
        }
    }

    private func makeTimer(after delay: TimeInterval, _ block: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0,
                                                      { _ in block() }) else { return nil }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        return t
    }
}
