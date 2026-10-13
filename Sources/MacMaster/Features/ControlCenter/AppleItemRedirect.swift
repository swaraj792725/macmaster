import AppKit
import ApplicationServices
import CoreGraphics
import os

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

    /// identifier -> frame for every `com.apple.menuextra.*` item found. Blocking: not for the main thread.
    nonisolated static func scan(timeout: Float = 0.15) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for pid in hostPids() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef) == .success,
                  let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { continue }
            walk(unsafeBitCast(barRef, to: AXUIElement.self), depth: 0, into: &out)
        }
        return out
    }

    private nonisolated static func hostPids() -> [pid_t] {
        var pids = NSWorkspace.shared.runningApplications
            .filter { hostBundleIDs.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
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

/// Runs on the tap thread. The state it mutates (`swallowUp`) is only ever touched there.
private final class RedirectTap: @unchecked Sendable {
    let frames: OSAllocatedUnfairLock<RedirectFrames>
    let onHit: @Sendable (AppleItemRedirect.Target, CGRect) -> Void
    private var swallowUp = false

    init(frames: OSAllocatedUnfairLock<RedirectFrames>, onHit: @escaping @Sendable (AppleItemRedirect.Target, CGRect) -> Void) {
        self.frames = frames
        self.onHit = onHit
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .leftMouseDown:
            swallowUp = false
            let p = event.location
            guard p.y < 60 else { return pass }   // menu bar (with notch) is under 40pt; everything else is ignored here
            // Shift/Option/Command/Control-click reaches Apple's original item.
            guard event.flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl]).isEmpty else { return pass }
            var f = frames.withLock { $0 }
            guard f.wantControlCenter || f.wantClock else { return pass }
            if AppleItemRedirect.nowNanos() &- f.stamp > AppleItemRedirect.staleNanos {
                let found = AppleMenuScanner.scan(timeout: 0.15)
                f.controlCenter = found[AppleMenuItem.controlCenter]
                f.clock = found[AppleMenuItem.clock]
                f.stamp = AppleItemRedirect.nowNanos()
                let (cc, clock, stamp) = (f.controlCenter, f.clock, f.stamp)
                frames.withLock { $0.controlCenter = cc; $0.clock = clock; $0.stamp = stamp }
            }
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
            return pass
        case .leftMouseUp:
            if swallowUp { swallowUp = false; return nil }
            return pass
        default:
            return pass
        }
    }
}

/// Opt-in: a click on Apple's Control Center (or clock) menu bar item opens MacMaster's popover instead.
/// A session event tap swallows the click; a one-pixel anchor window gives the popover something to hang from.
@Observable @MainActor
final class AppleItemRedirect {
    static let shared = AppleItemRedirect()

    enum Target: Sendable { case controlCenter, clock }
    enum Status: Equatable { case off, needsAccessibility, active, failed }

    nonisolated static let staleNanos: UInt64 = 2_000_000_000
    nonisolated static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private(set) var status: Status = .off
    /// Apple's items as last seen; for the settings page ("found at ...").
    private(set) var foundControlCenter = false
    private(set) var foundClock = false

    @ObservationIgnored private let frames = OSAllocatedUnfairLock(initialState: RedirectFrames())
    @ObservationIgnored private var runner: KeyboardTapRunner?
    @ObservationIgnored private var tap: RedirectTap?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var anchor: NSWindow?
    @ObservationIgnored private var refreshing = false

    private init() {}

    // MARK: Lifecycle

    /// Starts or stops the tap to match the settings and the Accessibility grant. Idempotent.
    func update() {
        let s = ControlCenterSettings.shared
        let want = s.redirectControlCenter || s.redirectClock
        let (wantCC, wantClock) = (s.redirectControlCenter, s.redirectClock)
        frames.withLock { $0.wantControlCenter = wantCC; $0.wantClock = wantClock }
        guard want else { stop(); status = .off; return }
        guard Permissions.isGranted(.accessibility) else { stop(); status = .needsAccessibility; return }
        if runner == nil { start() } else { refresh() }
    }

    private func start() {
        let t = RedirectTap(frames: frames) { [weak self] target, rect in
            Task { @MainActor in self?.handle(target, rect) }
        }
        let r = KeyboardTapRunner(name: "macmaster.appleitemredirect", types: [.leftMouseDown, .leftMouseUp]) { type, event in
            t.handle(type, event)
        }
        guard r.start() else { status = .failed; return }
        tap = t
        runner = r
        status = .active
        observe()
        refresh()
    }

    private func stop() {
        runner?.stop()
        runner = nil
        tap = nil
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
        func add(_ c: NotificationCenter, _ name: Notification.Name, refresh now: Bool) {
            let o = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if now { self.refresh() } else { self.frames.withLock { $0.stamp = 0 } }
                }
            }
            observers.append((c, o))
        }
        add(nc, NSApplication.didChangeScreenParametersNotification, refresh: true)
        add(ws, NSWorkspace.activeSpaceDidChangeNotification, refresh: false)
        add(ws, NSWorkspace.didLaunchApplicationNotification, refresh: false)   // MenuBarAgent restarts
        add(ws, NSWorkspace.didTerminateApplicationNotification, refresh: false)
        let o = nc.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchorDone() }
        }
        observers.append((nc, o))
    }

    /// Rescans off the main thread. Cheap, and only runs on enable or when the screen layout changes.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let found = AppleMenuScanner.scan(timeout: 0.4)
            await MainActor.run {
                let me = AppleItemRedirect.shared
                me.frames.withLock {
                    $0.controlCenter = found[AppleMenuItem.controlCenter]
                    $0.clock = found[AppleMenuItem.clock]
                    $0.stamp = AppleItemRedirect.nowNanos()
                }
                me.foundControlCenter = found[AppleMenuItem.controlCenter] != nil
                me.foundClock = found[AppleMenuItem.clock] != nil
                me.refreshing = false
            }
        }
    }

    // MARK: Opening our popovers

    private func handle(_ target: Target, _ rect: CGRect) {
        switch target {
        case .controlCenter:
            if ClockMenuBar.shared.isPopoverShown { ClockMenuBar.shared.close() }
            if ControlCenterMenuBar.shared.closeIfShown() { return }
            ControlCenterMenuBar.shared.present(from: anchorView(for: rect))
        case .clock:
            ControlCenterMenuBar.shared.closeIfShown()
            if ClockMenuBar.shared.isPopoverShown { ClockMenuBar.shared.close(); return }
            ClockMenuBar.shared.showPopover(from: anchorView(for: rect))
        }
    }

    /// A transparent, click-through window sitting exactly over Apple's item, reaching down to the menu bar's bottom edge.
    private func anchorView(for rect: CGRect) -> NSView {
        let primary = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        var bottom = rect.maxY
        if let s = NSScreen.screens.first(where: { s in
            let cg = CGRect(x: s.frame.minX, y: primary - s.frame.maxY, width: s.frame.width, height: s.frame.height)
            return cg.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) {
            bottom = max(bottom, (primary - s.frame.maxY) + (s.frame.maxY - s.visibleFrame.maxY))
        }
        let frame = NSRect(x: rect.minX, y: primary - bottom, width: rect.width, height: bottom)
        let w = anchor ?? {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            anchor = w
            return w
        }()
        w.setFrame(frame, display: false)
        w.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        w.orderFrontRegardless()
        return w.contentView!
    }

    private func hideAnchor() { anchor?.orderOut(nil) }

    /// The popover that used the anchor closed.
    func anchorDone() {
        guard let a = anchor, a.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !ControlCenterMenuBar.shared.isPopoverShown, !ClockMenuBar.shared.isPopoverShown else { return }
            self.hideAnchor()
        }
    }
}
