import AppKit
import ApplicationServices

/// Wrapper so AX elements can cross queues (AX reads/writes are thread-safe).
struct TilingWindow: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    /// Stable identity for per-window memory.
    var key: Int { Int(bitPattern: CFHash(element)) }
}

/// Thin, crash-free wrappers over the Accessibility API. Every call fails soft (nil / false).
enum TilingAX {
    private static let ignoredBundles: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.loginwindow",
    ]

    static var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    // MARK: Attributes

    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { raw(el, attr) as? String }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = raw(el, attr), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(v, to: CFBoolean.self))
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = raw(el, attr) as? [AnyObject] else { return [] }
        return v.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, "AXPosition"), let s = size(el, "AXSize"), s.width > 0, s.height > 0 else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, "AXPosition" as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, "AXSize" as CFString, v) == .success
    }

    /// Size → position → size, so cross-display moves and clamped sizes still land correctly.
    @discardableResult
    static func setFrame(_ w: TilingWindow, _ r: CGRect) -> Bool {
        guard w.pid != ownPID else { return false }
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Enhanced UI makes some apps animate/lag on AX moves.
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        let a = setSize(w.element, r.size)
        let b = setPosition(w.element, r.origin)
        let c = setSize(w.element, r.size)
        return a || b || c
    }

    // MARK: Windows

    private static func isIgnored(pid: pid_t) -> Bool {
        if pid == ownPID { return true }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, ignoredBundles.contains(id) { return true }
        return false
    }

    static func isStandard(_ win: AXUIElement) -> Bool {
        string(win, "AXSubrole") == "AXStandardWindow" && bool(win, "AXFullScreen") != true
    }

    /// AXWindow containing `el` (or `el` itself).
    static func enclosingWindow(of el: AXUIElement) -> AXUIElement? {
        if string(el, "AXRole") == "AXWindow" { return el }
        if let w = element(el, "AXWindow") { return w }
        var cur = el
        for _ in 0..<12 {
            guard let parent = element(cur, "AXParent") else { return nil }
            if string(parent, "AXRole") == "AXWindow" { return parent }
            cur = parent
        }
        return nil
    }

    /// Nil over MacMaster's own windows: hit-testing ourselves runs SwiftUI accessibility (see `SelfAX`).
    static func elementAt(_ p: CGPoint) -> AXUIElement? {
        SelfAX.element(at: p, timeout: 0.25)
    }

    /// Standard window under a point (AX coords), skipping MacMaster, Dock, desktop and full-screen windows.
    static func window(at p: CGPoint, requireStandard: Bool = true) -> TilingWindow? {
        guard let hit = elementAt(p) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, !isIgnored(pid: pid) else { return nil }
        guard let win = enclosingWindow(of: hit) else { return nil }
        if requireStandard, !isStandard(win) { return nil }
        return TilingWindow(element: win, pid: pid)
    }

    /// If the point is over a green zoom button, its window and the button's frame.
    static func zoomButton(at p: CGPoint) -> (window: TilingWindow, button: CGRect)? {
        guard let hit = elementAt(p) else { return nil }
        guard let sub = string(hit, "AXSubrole"), sub == "AXZoomButton" || sub == "AXFullScreenButton" else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, !isIgnored(pid: pid),
              let btn = frame(hit), let win = enclosingWindow(of: hit), isStandard(win) else { return nil }
        return (TilingWindow(element: win, pid: pid), btn)
    }

    static func focusedWindow(pid: pid_t) -> TilingWindow? {
        guard pid != ownPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        let win = element(app, "AXFocusedWindow") ?? element(app, "AXMainWindow") ?? elements(app, "AXWindows").first
        guard let win else { return nil }
        return TilingWindow(element: win, pid: pid)
    }

    /// Visible, standard, non-minimized windows of an app.
    static func windows(pid: pid_t) -> [TilingWindow] {
        guard pid != ownPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        return elements(app, "AXWindows").compactMap { w in
            guard isStandard(w), bool(w, "AXMinimized") != true else { return nil }
            return TilingWindow(element: w, pid: pid)
        }
    }

    static func raise(_ w: TilingWindow) {
        guard w.pid != ownPID else { return }
        // AXFrontmost works for other apps without the macOS 14 cooperative-activation limits.
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, "AXRaise" as CFString)
    }

    static func title(_ w: TilingWindow) -> String { string(w.element, "AXTitle") ?? "" }
}

// MARK: - Per-window memory

/// Remembers each window's frame from before we moved it (for Restore and drag-away) and the
/// last half-cycle step. Thread-safe.
final class TilingMemory: @unchecked Sendable {
    static let shared = TilingMemory()

    struct Entry {
        var original: CGRect
        var snapped: CGRect
        var layout: TilingLayout
        var step: Int
        var time: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func entry(_ key: Int) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }

    func remove(_ key: Int) { lock.lock(); entries[key] = nil; lock.unlock() }

    /// Next cycle step if `layout` is being repeated on a window still at its last result.
    func cycleStep(_ key: Int, layout: TilingLayout, current: CGRect) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], e.layout == layout, TilingGeometry.approx(e.snapped, current),
              ProcessInfo.processInfo.systemUptime - e.time < 20 else { return 0 }
        return (e.step + 1) % 3
    }

    func noteApplied(_ key: Int, before: CGRect, after: CGRect, layout: TilingLayout, step: Int) {
        lock.lock(); defer { lock.unlock() }
        var original = before
        if let e = entries[key], TilingGeometry.approx(e.snapped, before) { original = e.original }
        entries[key] = Entry(original: original, snapped: after, layout: layout, step: step,
                             time: ProcessInfo.processInfo.systemUptime)
        if entries.count > 80 {
            let drop = entries.sorted { $0.value.time < $1.value.time }.prefix(20).map(\.key)
            for k in drop { entries[k] = nil }
        }
    }
}

// MARK: - Actions

/// Applies layouts to windows. Safe on any queue (inputs are value snapshots).
enum TilingActions {
    /// Returns true when the window moved.
    @discardableResult
    static func perform(_ layout: TilingLayout, window w: TilingWindow, screens: [TilingScreenInfo], gap: CGFloat,
                        targetScreen: TilingScreenInfo? = nil, cycle: Bool = false) -> Bool {
        guard let cur = TilingAX.frame(w.element), !screens.isEmpty,
              let screen = targetScreen ?? TilingScreens.screen(for: cur, in: screens) else { return false }
        let mem = TilingMemory.shared

        switch layout {
        case .restore:
            guard let e = mem.entry(w.key) else { return false }
            mem.remove(w.key)
            return TilingAX.setFrame(w, e.original)

        case .previousDisplay, .nextDisplay:
            let sorted = screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            guard sorted.count > 1, let i = sorted.firstIndex(where: { $0.id == screen.id }) else { return false }
            let step = layout == .nextDisplay ? 1 : sorted.count - 1
            let dest = sorted[(i + step) % sorted.count]
            let src = screen.visible, dst = dest.visible
            let fw = cur.width / src.width, fh = cur.height / src.height
            let fx = (cur.minX - src.minX) / src.width, fy = (cur.minY - src.minY) / src.height
            let w2 = min(dst.width, max(200, fw * dst.width)), h2 = min(dst.height, max(120, fh * dst.height))
            var x = dst.minX + fx * dst.width, y = dst.minY + fy * dst.height
            x = min(max(x, dst.minX), dst.maxX - w2)
            y = min(max(y, dst.minY), dst.maxY - h2)
            let r = TilingGeometry.rounded(CGRect(x: x, y: y, width: w2, height: h2))
            let ok = TilingAX.setFrame(w, r)
            if ok, let after = TilingAX.frame(w.element) {
                mem.noteApplied(w.key, before: cur, after: after, layout: layout, step: 0)
            }
            return ok

        default:
            let step = (cycle && layout.isHalf) ? mem.cycleStep(w.key, layout: layout, current: cur) : 0
            guard let target = TilingGeometry.target(for: layout, current: cur, screen: screen, gap: gap, step: step) else {
                return false
            }
            let ok = TilingAX.setFrame(w, target)
            if ok {
                let after = TilingAX.frame(w.element) ?? target
                mem.noteApplied(w.key, before: cur, after: after, layout: layout, step: step)
            }
            return ok
        }
    }
}
