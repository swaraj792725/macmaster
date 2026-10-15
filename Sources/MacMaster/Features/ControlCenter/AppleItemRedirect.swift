import AppKit
import ApplicationServices
import CoreGraphics
import os

let redirectLog = Logger(subsystem: "com.macmaster.app", category: "redirect")

/// Ids of Apple's own menu bar items, as MenuBarAgent exposes them through Accessibility.
enum AppleMenuItem {
    static let controlCenter = "com.apple.menuextra.controlcenter"
    static let clock = "com.apple.menuextra.clock"
}

/// Frames of Apple's menu bar items (CG global coordinates, top-left origin), read through Accessibility.
enum AppleMenuScanner {
    /// Hosts of the system menu extras. On macOS 26+ that is MenuBarAgent; older systems used the other two.
    private static let hostBundleIDs: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    private static let hostNames: Set<String> = ["MenuBarAgent", "Control Center", "SystemUIServer"]

    /// identifier -> frame for every `com.apple.menuextra.*` item found, in CG global coordinates.
    /// Accessibility first; the window list fills in whatever Accessibility did not expose. Blocking: not for the main thread.
    nonisolated static func scan(timeout: Float = 0.15) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        let pids = hostPids()
        var axFailures = 0
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            var barRef: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef)
            guard r == .success, let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else {
                axFailures += 1
                redirectLog.debug("AXExtrasMenuBar unavailable for pid \(pid, privacy: .public): AXError \(r.rawValue, privacy: .public)")
                continue
            }
            walk(unsafeBitCast(barRef, to: AXUIElement.self), depth: 0, into: &out)
        }
        let viaAX = out.count
        // The window list is only a fallback: skip it when Accessibility already found both items.
        let haveBoth = out[AppleMenuItem.controlCenter] != nil && out[AppleMenuItem.clock] != nil
        let fromWindows = haveBoth ? [:] : windowFrames()
        for (id, f) in fromWindows where out[id] == nil { out[id] = f }
        redirectLog.debug("scan: hosts=\(pids.count, privacy: .public) axFailures=\(axFailures, privacy: .public) viaAX=\(viaAX, privacy: .public) viaWindows=\(fromWindows.count, privacy: .public) controlCenter=\(describe(out[AppleMenuItem.controlCenter]), privacy: .public) clock=\(describe(out[AppleMenuItem.clock]), privacy: .public)")
        return out
    }

    nonisolated static func describe(_ r: CGRect?) -> String {
        guard let r else { return "none" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    /// Menu bar items are windows at the status level. Control Center's own icon is titled "BentoBox" (or "Control Center"),
    /// the clock "Clock". No Accessibility needed, so it still works when the AX tree has no identifiers.
    private nonisolated static func windowFrames() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return out }
        var seen: [String] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let owner = w[kCGWindowOwnerName as String] as? String, hostNames.contains(owner),
                  let name = w[kCGWindowName as String] as? String,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: dict), f.width > 0, f.height > 0, onScreen(f) else { continue }
            seen.append(name)
            if name.hasPrefix("BentoBox") || name == "Control Center" { out[AppleMenuItem.controlCenter] = f }
            else if name == "Clock" { out[AppleMenuItem.clock] = f }
        }
        if out.isEmpty { redirectLog.info("window scan: no Control Center/Clock window; status-level windows seen: \(seen.joined(separator: ", "), privacy: .public)") }
        return out
    }

    private nonisolated static func hostPids() -> [pid_t] {
        var pids = RunningAppCache.shared.apps
            .filter { hostBundleIDs.contains($0.bundleID ?? "") }
            .map(\.pid)
        if pids.isEmpty, let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            var seen = Set<pid_t>()
            for w in list {
                guard let name = w[kCGWindowOwnerName as String] as? String, hostNames.contains(name),
                      let p = w[kCGWindowOwnerPID as String] as? Int, p > 0, seen.insert(pid_t(p)).inserted else { continue }
                pids.append(pid_t(p))
            }
        }
        return pids
    }

    private nonisolated static func walk(_ el: AXUIElement, depth: Int, into out: inout [String: CGRect]) {
        guard depth < 5 else { return }
        if string(el, kAXRoleAttribute) == "AXMenuBarItem" {
            var id = string(el, kAXIdentifierAttribute)
            if id.isEmpty {
                // Older builds have no identifier; the description is the only handle.
                let label = string(el, kAXDescriptionAttribute) + string(el, kAXTitleAttribute)
                if label.contains("Control Center") { id = AppleMenuItem.controlCenter }
            }
            if id.hasPrefix("com.apple.menuextra"), let f = rect(el), f.width > 0, f.height > 0, onScreen(f) {
                out[id] = f
            }
            return
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return }
        for k in kids { walk(k, depth: depth + 1, into: &out) }
    }

    private nonisolated static func string(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    private nonisolated static func rect(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Hidden items (notch overflow, full-screen menu bar) report frames outside every display.
    private nonisolated static func onScreen(_ f: CGRect) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return true }
        return ids.prefix(Int(n)).contains { CGDisplayBounds($0).intersects(f) } && f.minY > -1
    }
}

// MARK: - Click redirect

/// Frames the tap thread reads, plus when they were taken. Guarded by a lock; the tap only does a rect test.
private struct RedirectFrames: Sendable {
    var controlCenter: CGRect?
    var clock: CGRect?
    var wantControlCenter = false
    var wantClock = false
    var stamp: UInt64 = 0
}

/// Runs on the tap thread. Never scans or blocks: it only tests cached frames.
/// The state it mutates (`swallowUp`) is only ever touched there.
private final class RedirectTap: @unchecked Sendable {
    let frames: OSAllocatedUnfairLock<RedirectFrames>
    let onHit: @Sendable (AppleItemRedirect.Target, CGRect) -> Void
    let onMiss: @Sendable () -> Void
    private var swallowUp = false

    init(frames: OSAllocatedUnfairLock<RedirectFrames>,
         onHit: @escaping @Sendable (AppleItemRedirect.Target, CGRect) -> Void,
         onMiss: @escaping @Sendable () -> Void) {
        self.frames = frames
        self.onHit = onHit
        self.onMiss = onMiss
    }

    /// Tap was disabled: the matching mouse-up may never arrive, so don't eat the next unrelated one.
    func reset() { swallowUp = false }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .leftMouseDown:
            swallowUp = false
            let p = event.location   // CG global, top-left origin: same space as the cached frames
            guard p.y < 60 else { return pass }   // menu bar (with notch) is under 40pt; everything else is ignored here
            // Shift/Option/Command/Control-click reaches Apple's original item.
            guard event.flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl]).isEmpty else { return pass }
            let f = frames.withLock { $0 }
            guard f.wantControlCenter || f.wantClock else { return pass }
            if f.wantControlCenter, let r = f.controlCenter, r.insetBy(dx: -2, dy: -6).contains(p) {
                swallowUp = true
                onHit(.controlCenter, r)
                return nil
            }
            if f.wantClock, let r = f.clock, r.insetBy(dx: -2, dy: -6).contains(p) {
                swallowUp = true
                onHit(.clock, r)
                return nil
            }
            // A click in the menu bar that hit nothing: frames may be stale (items moved). Refresh in the background.
            if AppleItemRedirect.nowNanos() &- f.stamp > AppleItemRedirect.staleNanos { onMiss() }
            return pass
        case .leftMouseUp:
            if swallowUp { swallowUp = false; return nil }
            return pass
        default:
            return pass
        }
    }
}

/// A click on Apple's Control Center (or clock) menu bar item opens MacMaster's dropdown (or clock popover) instead.
/// A session event tap swallows the click; an invisible anchor window under Apple's icon gives the popover something to hang from.
@Observable @MainActor
final class AppleItemRedirect {
    static let shared = AppleItemRedirect()

    enum Target: Sendable { case controlCenter, clock }
    enum Status: Equatable { case off, needsAccessibility, failed, notFound, active }

    nonisolated static let staleNanos: UInt64 = 3_000_000_000
    nonisolated static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private(set) var status: Status = .off
    /// Apple's items as last seen; for the settings page.
    private(set) var foundControlCenter = false
    private(set) var foundClock = false
    /// Last scan result, for diagnostics on the settings page.
    private(set) var lastScan: Date?

    @ObservationIgnored private let frames = OSAllocatedUnfairLock(initialState: RedirectFrames())
    @ObservationIgnored private var runner: KeyboardTapRunner?
    @ObservationIgnored private var tap: RedirectTap?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    /// Wanted but not running (no permission yet, tap creation failed): try again periodically.
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var anchor: NSWindow?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastClosed: UInt64 = 0

    private init() {}

    // MARK: Lifecycle

    /// Starts or stops the tap to match the settings and the Accessibility grant. Idempotent.
    func update() {
        let s = ControlCenterSettings.shared
        let (wantCC, wantClock) = (s.redirectControlCenter, s.redirectClock)
        frames.withLock { $0.wantControlCenter = wantCC; $0.wantClock = wantClock }
        defer { syncOwnIcons() }
        guard wantCC || wantClock else {
            stop(); stopRetry(); set(.off); return
        }
        guard Permissions.isGranted(.accessibility) else {
            stop(); set(.needsAccessibility); scheduleRetry(); return
        }
        if let r = runner, !r.isEnabled {
            redirectLog.error("event tap is dead; restarting")
            stop()
        }
        if runner == nil { start() } else { refresh() }
        if runner == nil { scheduleRetry() } else { stopRetry() }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func set(_ new: Status) {
        guard status != new else { return }
        redirectLog.info("status \(String(describing: self.status), privacy: .public) -> \(String(describing: new), privacy: .public)")
        status = new
        syncOwnIcons()
    }

    /// While Apple's Control Center opens our dropdown, MacMaster's own icon would be a second way to the same place.
    var replacesControlCenterIcon: Bool { ControlCenterSettings.shared.redirectControlCenter && status == .active }
    /// Same for Apple's clock and MacMaster's clock item.
    var replacesClockIcon: Bool { ControlCenterSettings.shared.redirectClock && status == .active }

    /// Hide (or bring back) MacMaster's own icons to match. Only a working redirect hides them, so there's always a way in.
    func syncOwnIcons() {
        MainStatusItem.shared.update()
        ClockMenuBar.shared.update()
    }

    private func start() {
        let t = RedirectTap(frames: frames, onHit: { [weak self] target, rect in
            redirectLog.info("hit \(String(describing: target), privacy: .public) at \(AppleMenuScanner.describe(rect), privacy: .public)")
            Task { @MainActor in self?.handle(target, rect) }
        }, onMiss: { [weak self] in
            redirectLog.debug("menu bar click missed cached frames; refreshing")
            Task { @MainActor in self?.refresh() }
        })
        let r = KeyboardTapRunner(name: "macmaster.appleitemredirect", types: [.leftMouseDown, .leftMouseUp], onDisabled: {
            redirectLog.error("event tap was disabled by the system; re-enabling")
            t.reset()
        }) { type, event in
            t.handle(type, event)
        }
        guard r.start() else {
            redirectLog.error("event tap failed to start (Accessibility granted but CGEvent.tapCreate returned nil)")
            set(.failed); return
        }
        redirectLog.info("event tap started")
        tap = t
        runner = r
        set(.active)
        observe()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Dead tap or revoked permission: update() tears down and restarts (or waits for the grant).
                if self.runner?.isEnabled != true || !Permissions.isGranted(.accessibility) { self.update() } else { self.refresh() }
            }
        }
        refresh()
    }

    private func stop() {
        if runner != nil { redirectLog.info("event tap stopped") }
        runner?.stop()
        runner = nil
        tap = nil
        timer?.invalidate()
        timer = nil
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        foundControlCenter = false
        foundClock = false
        hideAnchor()
    }

    // MARK: Frame cache

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        func add(_ c: NotificationCenter, _ name: Notification.Name) {
            let o = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((c, o))
        }
        add(nc, NSApplication.didChangeScreenParametersNotification)
        add(ws, NSWorkspace.activeSpaceDidChangeNotification)
        add(ws, NSWorkspace.didLaunchApplicationNotification)   // MenuBarAgent restarts
        add(ws, NSWorkspace.didTerminateApplicationNotification)
        let o = nc.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchorDone() }
        }
        observers.append((nc, o))
    }

    /// Rescans off the main thread and publishes the frames to the tap.
    func refresh() {
        guard !refreshing, runner != nil else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let found = AppleMenuScanner.scan(timeout: 0.4)
            await MainActor.run {
                let me = AppleItemRedirect.shared
                me.refreshing = false
                guard me.runner != nil else { return }
                // A full-screen app hides the menu bar: Apple's items then report off-screen frames and the scan
                // finds nothing. Keep the last on-screen frames; the revealed bar puts the items right back there.
                let f = me.frames.withLock {
                    if let r = found[AppleMenuItem.controlCenter] { $0.controlCenter = r }
                    if let r = found[AppleMenuItem.clock] { $0.clock = r }
                    $0.stamp = AppleItemRedirect.nowNanos()
                    return $0
                }
                me.foundControlCenter = f.controlCenter != nil
                me.foundClock = f.clock != nil
                me.lastScan = Date()
                let s = ControlCenterSettings.shared
                let missing = (s.redirectControlCenter && !me.foundControlCenter) || (s.redirectClock && !me.foundClock)
                me.set(missing ? .notFound : .active)
            }
        }
    }

    // MARK: Opening our popovers

    private func handle(_ target: Target, _ rect: CGRect) {
        // The first click's mouseDown already made a transient popover close itself; don't reopen on that same click.
        let justClosed = Self.nowNanos() &- lastClosed < 250_000_000
        switch target {
        case .controlCenter:
            if ClockMenuBar.shared.isPopoverShown { ClockMenuBar.shared.close() }
            if MainStatusItem.shared.isShown { MainStatusItem.shared.close(); return }
            if justClosed { return }
            open(controlCenterAt: rect)
        case .clock:
            MainStatusItem.shared.close()
            if ClockMenuBar.shared.isPopoverShown { ClockMenuBar.shared.close(); return }
            if justClosed { return }
            ClockMenuBar.shared.showPopover(from: anchorView(for: rect))
            redirectLog.info("opened clock popover under \(AppleMenuScanner.describe(rect), privacy: .public)")
        }
    }

    private func open(controlCenterAt rect: CGRect) {
        MainStatusItem.shared.present(from: anchorView(for: rect))
        redirectLog.info("opened dropdown under \(AppleMenuScanner.describe(rect), privacy: .public), shown=\(MainStatusItem.shared.isShown, privacy: .public)")
    }

    /// Settings page "Test": open the dropdown under Apple's icon exactly like a redirected click would.
    /// If the icon wasn't found, it hangs from the top centre of the main screen so you can still see it work.
    func test() {
        ClockMenuBar.shared.close()
        if MainStatusItem.shared.isShown { MainStatusItem.shared.close(); return }
        // AX scan off the main thread: a slow menu bar agent must not freeze the settings page.
        Task.detached(priority: .userInitiated) {
            let found = AppleMenuScanner.scan(timeout: 0.4)[AppleMenuItem.controlCenter]
            await MainActor.run {
                let me = AppleItemRedirect.shared
                if let r = found {
                    redirectLog.info("test: found Apple's Control Center at \(AppleMenuScanner.describe(r), privacy: .public)")
                    me.open(controlCenterAt: r)
                } else {
                    let main = CGDisplayBounds(CGMainDisplayID())
                    let r = CGRect(x: main.midX - 14, y: 0, width: 28, height: 24)
                    redirectLog.error("test: Apple's Control Center icon not found; using top centre \(AppleMenuScanner.describe(r), privacy: .public)")
                    me.open(controlCenterAt: r)
                }
            }
        }
    }

    /// A transparent, click-through window sitting exactly over Apple's item, reaching down to the menu bar's bottom edge.
    /// Works whether or not MacMaster has its own status item.
    private func anchorView(for rect: CGRect) -> NSView {
        let primary = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        var bottom = max(rect.maxY, 24)
        if let s = NSScreen.screens.first(where: { s in
            let cg = CGRect(x: s.frame.minX, y: primary - s.frame.maxY, width: s.frame.width, height: s.frame.height)
            return cg.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) {
            // visibleFrame excludes the menu bar (and notch strip); its gap is the bar's real height on this screen.
            bottom = max(bottom, (primary - s.frame.maxY) + (s.frame.maxY - s.visibleFrame.maxY))
        }
        let frame = NSRect(x: rect.minX, y: primary - bottom, width: max(rect.width, 1), height: bottom)
        let w: NSWindow = anchor ?? { () -> NSWindow in
            // A non-activating panel: while MacMaster is a regular (Dock) app, a plain window can't join another
            // app's full-screen Space, so the popover hung from it opened on the desktop Space, out of sight.
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            // Above status-item level: macOS hides an app's status-level windows (and popovers hung from them) when
            // the app is switched off in System Settings › Menu Bar › Allow in the Menu Bar.
            w.level = .popUpMenu
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            anchor = w
            return w
        }()
        w.setFrame(frame, display: false)
        w.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        w.orderFrontRegardless()
        redirectLog.debug("anchor window frame (AppKit) \(NSStringFromRect(frame), privacy: .public)")
        return w.contentView!
    }

    private func hideAnchor() { anchor?.orderOut(nil) }

    /// A popover closed; drop the anchor once neither of ours is showing.
    func anchorDone() {
        lastClosed = Self.nowNanos()
        guard let a = anchor, a.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !MainStatusItem.shared.isShown, !ClockMenuBar.shared.isPopoverShown else { return }
            self.hideAnchor()
        }
    }
}
