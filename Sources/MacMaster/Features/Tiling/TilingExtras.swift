import AppKit

// MARK: - Focus follows mouse

/// Raises and focuses the window under the cursor after the pointer rests for a moment.
@MainActor
final class TilingFocusFollower {
    static let shared = TilingFocusFollower()

    private var monitor: Any?
    private var timer: Timer?
    private var lastMove: TimeInterval = 0
    private var lastPos: CGPoint = .zero
    private var handledPos: CGPoint = CGPoint(x: -1, y: -1)
    private var inFlight = false
    private let axQueue = DispatchQueue(label: "MacMaster.Tiling.focus", qos: .utility)

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastMove = ProcessInfo.processInfo.systemUptime
                self?.lastPos = NSEvent.mouseLocation
            }
        }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard TilingSettings.enabled, TilingSettings.focusFollows, !inFlight, lastMove > 0,
              NSEvent.pressedMouseButtons == 0, AXIsProcessTrusted() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= TilingSettings.focusDelay else { return }
        let ns = NSEvent.mouseLocation
        guard hypot(ns.x - handledPos.x, ns.y - handledPos.y) > 2 else { return }
        handledPos = ns
        // Ignore the menu bar strip.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(ns) }),
           ns.y > screen.visibleFrame.maxY { return }
        let p = TilingScreens.axPoint(fromNS: ns)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        inFlight = true
        axQueue.async { [weak self] in
            defer { DispatchQueue.main.async { MainActor.assumeIsolated { self?.inFlight = false } } }
            guard let w = TilingAX.window(at: p) else { return }
            // Already the focused window of the frontmost app? nothing to do.
            if w.pid == front {
                let app = AXUIElementCreateApplication(w.pid)
                if let focused = TilingAX.element(app, "AXFocusedWindow"), CFEqual(focused, w.element) { return }
            }
            TilingAX.raise(w)
        }
    }
}

// MARK: - Title bar double-click

/// Double-click a window's title bar to maximize, double-click again to restore.
@MainActor
final class TilingTitleBarDoubleClick {
    static let shared = TilingTitleBarDoubleClick()

    private var monitor: Any?
    private let axQueue = DispatchQueue(label: "MacMaster.Tiling.titlebar", qos: .userInitiated)
    nonisolated private static let titleRoles: Set<String> = ["AXWindow", "AXToolbar", "AXGroup", "AXStaticText", "AXUnknown", "AXImage"]

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            let clicks = event.clickCount
            MainActor.assumeIsolated { self?.handle(clicks: clicks) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(clicks: Int) {
        guard clicks == 2, TilingSettings.enabled, TilingSettings.titleDoubleClick, AXIsProcessTrusted() else { return }
        let p = TilingScreens.mouseAX
        let screens = TilingScreens.snapshot()
        let gap = TilingSettings.gap
        axQueue.async {
            guard let hit = TilingAX.elementAt(p), let w = TilingAX.window(at: p),
                  let frame = TilingAX.frame(w.element), p.y - frame.minY <= 34 else { return }
            if let sub = TilingAX.string(hit, "AXSubrole"), sub.hasSuffix("Button") { return }
            guard Self.titleRoles.contains(TilingAX.string(hit, "AXRole") ?? "AXUnknown") else { return }
            guard let screen = TilingScreens.screen(for: frame, in: screens),
                  let max = TilingGeometry.target(for: .maximize, current: frame, screen: screen, gap: gap) else { return }
            if TilingGeometry.approx(frame, max, tol: 10) {
                TilingActions.perform(.restore, window: w, screens: screens, gap: gap)
            } else {
                TilingActions.perform(.maximize, window: w, screens: screens, gap: gap)
            }
        }
    }
}

// MARK: - Presets & tile all

struct TilingAppRef: Sendable {
    var pid: pid_t
    var bundleID: String
    var name: String
}

enum TilingWorkspace {
    /// Regular, visible apps other than MacMaster. Call on the main thread.
    @MainActor static func regularApps(includeHidden: Bool) -> [TilingAppRef] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != TilingAX.ownPID,
                  includeHidden || !app.isHidden else { return nil }
            return TilingAppRef(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                name: app.localizedName ?? "App")
        }
    }

    /// Records every window's app, title and frame.
    static func capture(apps: [TilingAppRef]) -> [TilingSavedWindow] {
        var out: [TilingSavedWindow] = []
        for app in apps {
            for w in TilingAX.windows(pid: app.pid) {
                guard let f = TilingAX.frame(w.element) else { continue }
                out.append(TilingSavedWindow(bundleID: app.bundleID, appName: app.name, title: TilingAX.title(w),
                                             x: f.minX, y: f.minY, width: f.width, height: f.height))
            }
        }
        return out
    }

    /// Moves windows back (matches by app + title, then by order). Returns how many were placed.
    @discardableResult
    static func restore(_ layout: TilingSavedLayout, apps: [TilingAppRef], screens: [TilingScreenInfo]) -> Int {
        var placed = 0
        let byBundle = Dictionary(grouping: apps.filter { !$0.bundleID.isEmpty }, by: \.bundleID)
        for (bundle, saved) in Dictionary(grouping: layout.windows, by: \.bundleID) {
            guard let app = byBundle[bundle]?.first else { continue }
            var wins = TilingAX.windows(pid: app.pid)
            // Exact title matches first.
            var leftovers: [TilingSavedWindow] = []
            for s in saved {
                if let i = wins.firstIndex(where: { TilingAX.title($0) == s.title }) {
                    if TilingAX.setFrame(wins[i], visibleFrame(s.frame, screens)) { placed += 1 }
                    wins.remove(at: i)
                } else {
                    leftovers.append(s)
                }
            }
            for (s, w) in zip(leftovers, wins) where TilingAX.setFrame(w, visibleFrame(s.frame, screens)) { placed += 1 }
        }
        return placed
    }

    /// Keeps restored windows reachable if the display setup changed.
    private static func visibleFrame(_ f: CGRect, _ screens: [TilingScreenInfo]) -> CGRect {
        guard !screens.isEmpty, !screens.contains(where: { $0.visible.intersects(f) }) else { return f }
        let v = screens[0].visible
        return CGRect(x: v.minX + 40, y: v.minY + 40, width: min(f.width, v.width - 80), height: min(f.height, v.height - 80))
    }

    /// Arranges the visible windows on `screen` in a grid. Returns the count.
    @discardableResult
    static func tileAll(apps: [TilingAppRef], screen: TilingScreenInfo, gap: CGFloat) -> Int {
        var wins: [(TilingWindow, CGRect)] = []
        for app in apps {
            for w in TilingAX.windows(pid: app.pid) {
                guard let f = TilingAX.frame(w.element) else { continue }
                let c = CGPoint(x: f.midX, y: f.midY)
                if screen.frame.contains(c) { wins.append((w, f)) }
            }
        }
        wins.sort { ($0.1.minY / 100).rounded() == ($1.1.minY / 100).rounded() ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let wins2 = Array(wins.prefix(16))
        let frames = TilingGeometry.gridFrames(count: wins2.count, in: screen.visible, gap: gap)
        for (item, frame) in zip(wins2, frames) {
            let before = item.1
            if TilingAX.setFrame(item.0, frame) {
                let after = TilingAX.frame(item.0.element) ?? frame
                TilingMemory.shared.noteApplied(item.0.key, before: before, after: after, layout: .maximize, step: 0)
            }
        }
        return wins2.count
    }
}
