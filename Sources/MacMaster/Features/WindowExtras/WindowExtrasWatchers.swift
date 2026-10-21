import AppKit
import ApplicationServices

/// Listens (never intercepts) for the clicks behind "click Dock icon to minimize" and "quit when the last window
/// closes". One global mouse monitor does both; the handler only notes the position and hands off to a
/// background queue, where all Accessibility work happens.
@MainActor
final class WindowExtrasWatchers {
    private var monitor: Any?
    private var dockOn = false
    private var quitOn = false
    private let dock = WindowExtrasDock()
    let quit = WindowExtrasQuit()

    private var cachedOrientation = "bottom"
    private var orientationAt = -100.0

    var isRunning: Bool { monitor != nil }

    func apply(dockMinimize: Bool, quitOnLastClose: Bool) {
        dockOn = dockMinimize
        quitOn = quitOnLastClose
        if dockOn || quitOn {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                let isDown = event.type == .leftMouseDown
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.handle(down: isDown, flags: flags) }
            }
            windowExtrasLog.info("click watcher started (dock \(self.dockOn), quit \(self.quitOn))")
        } else if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            dock.reset()
            quit.reset()
            windowExtrasLog.info("click watcher stopped")
        }
    }

    private func handle(down: Bool, flags: NSEvent.ModifierFlags) {
        let p = TilingScreens.mouseAX
        if down {
            if dockOn, flags.intersection([.command, .option, .control, .shift]).isEmpty,
               let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != SelfAX.pid,
               inDockBand() {
                dock.mouseDown(at: p, frontPID: front.processIdentifier)
            }
            if quitOn { quit.mouseDown(at: p) }
        } else {
            if dockOn { dock.mouseUp(at: p) }
            if quitOn { quit.mouseUp() }
        }
    }

    /// Is the pointer near the screen edge the Dock lives on? Keeps almost every click away from Accessibility.
    private func inDockBand() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - orientationAt > 5 {
            cachedOrientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
            orientationAt = now
        }
        let loc = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(loc) }) else { return false }
        switch cachedOrientation {
        case "left": return loc.x - s.frame.minX <= 160
        case "right": return s.frame.maxX - loc.x <= 160
        default: return loc.y - s.frame.minY <= 160
        }
    }
}

// MARK: - Dock click

/// Clicking the Dock icon of the app that is already frontmost minimizes its windows (like a Windows taskbar).
/// macOS itself brings minimized windows back on the next click.
final class WindowExtrasDock: @unchecked Sendable {
    private struct Press {
        var point: CGPoint
        var pid: pid_t
        var eligible: Bool
    }

    private let queue = DispatchQueue(label: "MacMaster.WindowExtras.dock", qos: .userInitiated)
    // Queue-confined.
    private var press: Press?
    private var dockPID: pid_t = 0

    func mouseDown(at point: CGPoint, frontPID: pid_t) {
        queue.async { [self] in press = resolve(point, frontPID: frontPID) }
    }

    func mouseUp(at point: CGPoint) {
        queue.async { [self] in
            guard let p = press else { return }
            press = nil
            // A drag (rearranging the Dock) is not a click.
            guard p.eligible, hypot(point.x - p.point.x, point.y - p.point.y) < 8 else { return }
            queue.asyncAfter(deadline: .now() + 0.12) { [self] in minimize(pid: p.pid) }
        }
    }

    func reset() { queue.async { [self] in press = nil } }

    /// Was the press on the Dock icon of `frontPID`, and did that app have visible windows at that moment?
    private func resolve(_ point: CGPoint, frontPID: pid_t) -> Press {
        let none = Press(point: point, pid: frontPID, eligible: false)
        if dockPID == 0 || NSRunningApplication(processIdentifier: dockPID) == nil {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        }
        guard dockPID != 0 else { return none }
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success, let el = hit,
              TilingAX.string(el, "AXRole") == "AXDockItem",
              TilingAX.string(el, "AXSubrole") == "AXApplicationDockItem",
              let raw = TilingAX.raw(el, "AXURL"),
              let url = (raw as? URL) ?? (raw as? NSURL) as URL?,
              let app = NSRunningApplication(processIdentifier: frontPID),
              let bundle = app.bundleURL,
              url.standardizedFileURL.path == bundle.standardizedFileURL.path else { return none }
        return Press(point: point, pid: frontPID, eligible: !visibleWindows(pid: frontPID).isEmpty)
    }

    /// Standard, not-minimized windows. Empty when any window is full screen (those cannot be minimized).
    private func visibleWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let all = TilingAX.elements(app, "AXWindows")
        if all.contains(where: { TilingAX.bool($0, "AXFullScreen") == true }) { return [] }
        return all.filter { TilingAX.string($0, "AXSubrole") == "AXStandardWindow" && TilingAX.bool($0, "AXMinimized") != true }
    }

    private func minimize(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), app.isActive, !app.isTerminated else { return }
        let wins = visibleWindows(pid: pid)
        for w in wins {
            AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, kCFBooleanTrue)
        }
        if !wins.isEmpty { windowExtrasLog.info("minimized \(wins.count) window(s) of \(app.bundleIdentifier ?? "?", privacy: .public)") }
    }
}

// MARK: - Quit when the last window closes

/// After the red close button or ⌘W, waits a moment and quits the app (politely) if it has no windows left.
final class WindowExtrasQuit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacMaster.WindowExtras.quit", qos: .utility)
    // Queue-confined.
    private var candidate: (pid: pid_t, before: Int)?
    private var checking: Set<pid_t> = []

    func mouseDown(at point: CGPoint) {
        queue.async { [self] in
            candidate = nil
            guard WindowExtrasAX.inTrafficLightCorner(point),
                  let el = SelfAX.element(at: point, timeout: 0.15),
                  TilingAX.string(el, "AXSubrole") == "AXCloseButton" else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(el, &pid) == .success, pid != SelfAX.pid else { return }
            candidate = (pid, Self.windowCount(pid: pid))
        }
    }

    /// The press ended: the window closes now (or the click was cancelled, which the later check notices).
    func mouseUp() {
        queue.async { [self] in
            guard let c = candidate else { return }
            candidate = nil
            schedule(pid: c.pid, before: c.before)
        }
    }

    /// ⌘W in the frontmost app. Runs on the tap thread, before the app sees the key, so the window count taken
    /// here is the count from before the close (one window-list snapshot, only on ⌘W).
    func closeShortcut() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != SelfAX.pid else { return }
        let before = Self.windowCount(pid: pid)
        queue.async { [self] in schedule(pid: pid, before: before) }
    }

    func reset() { queue.async { [self] in candidate = nil } }

    private func schedule(pid: pid_t, before: Int) {
        guard before >= 1, !checking.contains(pid) else { return }
        checking.insert(pid)
        queue.asyncAfter(deadline: .now() + 0.8) { [self] in
            checking.remove(pid)
            evaluate(pid: pid)
        }
    }

    private func evaluate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, let id = app.bundleIdentifier,
              !WindowExtrasSettings.excluded.contains(id) else { return }
        guard Self.windowCount(pid: pid) == 0 else { return }
        // Second opinion from Accessibility; an unanswered call means "don't quit".
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement], wins.isEmpty else { return }
        windowExtrasLog.info("quitting \(id, privacy: .public): last window closed")
        DispatchQueue.main.async { _ = app.terminate() }
    }

    /// Windows of `pid` on any Space (including minimized ones), ignoring tiny helper windows and overlays.
    static func windowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        var n = 0
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  r.width >= 100, r.height >= 50 else { continue }
            n += 1
        }
        return n
    }
}
