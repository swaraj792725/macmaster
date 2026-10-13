import AppKit
import ApplicationServices
import SwiftUI

struct WindowPreviewDockTarget {
    var app: WindowPreviewAppInfo
    /// Dock icon frame in Cocoa screen coordinates (origin bottom-left).
    var iconFrame: CGRect
}

private struct WindowPreviewRawDockHit: Sendable {
    var url: URL?
    var title: String
    var axFrame: CGRect
}

// MARK: - Dock hover detection

/// Watches the global mouse and hit-tests the Dock's accessibility tree when the cursor is near the Dock.
@MainActor
final class WindowPreviewDockWatcher {
    var onTarget: ((WindowPreviewDockTarget?) -> Void)?
    private(set) var orientation = "bottom"

    private var monitor: Any?
    private var lastHit = 0.0
    private var inFlight = false
    private var dockPID: pid_t = 0
    private var orientationDate = Date.distantPast
    private var lastWasTarget = false
    private let queue = DispatchQueue(label: "mm.windows.dockhit", qos: .userInteractive)

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        inFlight = false
        lastWasTarget = false
    }

    private func refreshOrientation() {
        guard Date().timeIntervalSince(orientationDate) > 3 else { return }
        orientationDate = Date()
        orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        if dockPID == 0 || NSRunningApplication(processIdentifier: dockPID) == nil {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        }
    }

    /// Region (Cocoa coords) near the Dock edge where hit-tests are worth doing.
    private func band(for screen: NSScreen) -> CGRect {
        let f = screen.frame, v = screen.visibleFrame
        switch orientation {
        case "left":
            let t = max(max(v.minX - f.minX, 0) + 40, 100)
            return CGRect(x: f.minX, y: f.minY, width: t, height: f.height)
        case "right":
            let t = max(max(f.maxX - v.maxX, 0) + 40, 100)
            return CGRect(x: f.maxX - t, y: f.minY, width: t, height: f.height)
        default:
            let t = max(max(v.minY - f.minY, 0) + 40, 100)
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: t)
        }
    }

    private func mouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHit >= 0.05, !inFlight else { return }
        refreshOrientation()
        let loc = NSEvent.mouseLocation
        guard dockPID != 0, let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) else { return }
        guard band(for: screen).contains(loc) else {
            if lastWasTarget { lastWasTarget = false; onTarget?(nil) }
            return
        }
        lastHit = now
        inFlight = true
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axPoint = CGPoint(x: loc.x, y: primaryH - loc.y)
        let pid = dockPID
        queue.async { [weak self] in
            let hit = Self.hitTest(dockPID: pid, point: axPoint)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = false
                    let target = hit.flatMap { self.resolve($0, primaryHeight: primaryH) }
                    self.lastWasTarget = target != nil
                    self.onTarget?(target)
                }
            }
        }
    }

    private func resolve(_ hit: WindowPreviewRawDockHit, primaryHeight: CGFloat) -> WindowPreviewDockTarget? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        func norm(_ u: URL?) -> String? { u?.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let wanted = norm(hit.url)
        let match = apps.first { wanted != nil && norm($0.bundleURL) == wanted }
            ?? apps.first { $0.localizedName == hit.title }
        guard let app = match else { return nil }
        let f = hit.axFrame
        let cocoa = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        return WindowPreviewDockTarget(
            app: WindowPreviewAppInfo(pid: app.processIdentifier, name: app.localizedName ?? hit.title, bundleID: app.bundleIdentifier),
            iconFrame: cocoa)
    }

    nonisolated private static func hitTest(dockPID: pid_t, point: CGPoint) -> WindowPreviewRawDockHit? {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element) == .success,
              let el = element else { return nil }
        guard WindowPreviewAX.string(el, kAXRoleAttribute) == "AXDockItem",
              WindowPreviewAX.string(el, kAXSubroleAttribute) == "AXApplicationDockItem",
              let frame = WindowPreviewAX.frame(el) else { return nil }
        var url: URL?
        if let v = WindowPreviewAX.attr(el, kAXURLAttribute) {
            url = (v as? URL) ?? (v as? NSURL) as URL?
        }
        return WindowPreviewRawDockHit(url: url, title: WindowPreviewAX.string(el, kAXTitleAttribute) ?? "", axFrame: frame)
    }
}

// MARK: - Dock preview controller

@MainActor
final class WindowPreviewDockController {
    private let watcher = WindowPreviewDockWatcher()
    private let model = WindowPreviewPanelModel()
    private var panel: WindowPreviewPanel?

    private var currentApp: WindowPreviewAppInfo?
    private var pendingPID: pid_t?
    private var iconFrame = CGRect.zero
    private var showTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { model.visible }

    func start() {
        watcher.onTarget = { [weak self] t in self?.handle(t) }
        watcher.start()
    }

    func stop() {
        watcher.stop()
        watcher.onTarget = nil
        hide(immediately: true)
    }

    // MARK: Hover handling

    private func handle(_ target: WindowPreviewDockTarget?) {
        let settings = WindowPreviewSettings.shared
        guard settings.dockPreviews else { return }
        guard let t = target else {
            // Leaving to a non-app item: pending shows are cancelled; hiding is handled by the region loop.
            showTask?.cancel()
            pendingPID = nil
            return
        }
        if t.app.pid == currentApp?.pid && model.visible {
            iconFrame = t.iconFrame
            return
        }
        if pendingPID == t.app.pid { return }
        showTask?.cancel()
        pendingPID = t.app.pid
        let delay = model.visible ? 0.06 : settings.hoverDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.present(t)
        }
    }

    private func present(_ t: WindowPreviewDockTarget) async {
        let settings = WindowPreviewSettings.shared
        let wins = await WindowPreviewEnumerator.windows(for: t.app, includeMinimized: settings.showMinimized)
        guard !Task.isCancelled, pendingPID == t.app.pid else { return }
        pendingPID = nil
        guard !wins.isEmpty else {
            if model.visible, currentApp?.pid != t.app.pid { hide(immediately: false) }
            return
        }

        hideWork?.cancel()
        let panel = ensurePanel()
        currentApp = t.app
        iconFrame = t.iconFrame
        configureModel(orientation: watcher.orientation)
        model.setWindows(wins)
        layout(panel: panel)
        panel.orderFrontRegardless()
        if !model.visible { model.visible = true }
        model.loadThumbnails()
        startLoop()
    }

    private func ensurePanel() -> WindowPreviewPanel {
        if let p = panel { return p }
        let p = WindowPreviewPanel()
        p.setContent(WindowPreviewDockPanelView(model: model))
        p.onMiddleClick = { [weak self] in
            guard let self, let id = self.model.hoveredID,
                  let w = self.model.windows.first(where: { $0.id == id }) else { return }
            self.closeWindow(w)
        }
        model.onActivate = { [weak self] w in
            WindowPreviewActions.focus(w)
            self?.hide(immediately: false)
        }
        model.onClose = { [weak self] w in self?.closeWindow(w) }
        model.onMinimize = { [weak self] w in
            WindowPreviewActions.toggleMinimize(w)
            self?.refreshSoon()
        }
        panel = p
        return p
    }

    private func configureModel(orientation: String) {
        let s = WindowPreviewSettings.shared
        model.thumbSize = s.thumbSize.size
        model.showTitles = s.showTitles
        model.vertical = orientation != "bottom"
        switch orientation {
        case "left": model.anchor = .leading
        case "right": model.anchor = .trailing
        default: model.anchor = .bottom
        }
    }

    // MARK: Layout

    private func screen(containing p: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(panel: WindowPreviewPanel) {
        let n = CGFloat(model.windows.count)
        let thumb = model.thumbSize
        let cardH = thumb.height + (model.showTitles ? 22 : 0)
        let pad: CGFloat = 28 + 28   // inner + shadow padding
        let scr = screen(containing: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        let vis = scr.visibleFrame
        var size: CGSize
        if model.vertical {
            let h = n * cardH + (n - 1) * 12 + pad
            size = CGSize(width: thumb.width + pad, height: min(h, vis.height - 40))
        } else {
            let w = n * thumb.width + (n - 1) * 12 + pad
            size = CGSize(width: min(w, vis.width - 40), height: cardH + pad)
        }
        var origin: CGPoint
        switch watcher.orientation {
        case "left":
            origin = CGPoint(x: iconFrame.maxX + 2, y: iconFrame.midY - size.height / 2)
        case "right":
            origin = CGPoint(x: iconFrame.minX - size.width - 2, y: iconFrame.midY - size.height / 2)
        default:
            origin = CGPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.maxY + 2)
        }
        let bounds = scr.frame.insetBy(dx: 4, dy: 4)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Region loop & refresh

    private func isInsideRegion(_ p: CGPoint) -> Bool {
        guard let panel else { return false }
        let pf = panel.frame.insetBy(dx: 18, dy: 18) // visible glass (shadow padding removed)
        if pf.insetBy(dx: -6, dy: -6).contains(p) { return true }
        if iconFrame.insetBy(dx: -4, dy: -4).contains(p) { return true }
        // Bridge between icon and panel.
        let bridge: CGRect
        switch watcher.orientation {
        case "left": bridge = CGRect(x: iconFrame.maxX, y: iconFrame.minY, width: max(0, pf.minX - iconFrame.maxX), height: iconFrame.height)
        case "right": bridge = CGRect(x: pf.maxX, y: iconFrame.minY, width: max(0, iconFrame.minX - pf.maxX), height: iconFrame.height)
        default: bridge = CGRect(x: iconFrame.minX, y: iconFrame.maxY, width: iconFrame.width, height: max(0, pf.minY - iconFrame.maxY))
        }
        return bridge.insetBy(dx: -4, dy: -4).contains(p)
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            var outsideSince: Date?
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.model.visible else { return }
                if self.isInsideRegion(NSEvent.mouseLocation) {
                    outsideSince = nil
                } else {
                    let since = outsideSince ?? Date()
                    outsideSince = since
                    if Date().timeIntervalSince(since) > 0.28, self.pendingPID == nil {
                        self.hide(immediately: false)
                        return
                    }
                }
                tick += 1
                if tick % 10 == 0, WindowPreviewSettings.shared.liveRefresh { self.refreshWindows() }
            }
        }
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.refreshWindows()
        }
    }

    private func refreshWindows() {
        guard let app = currentApp, model.visible else { return }
        Task { [weak self] in
            let wins = await WindowPreviewEnumerator.windows(for: app, includeMinimized: WindowPreviewSettings.shared.showMinimized)
            guard let self, self.model.visible, self.currentApp?.pid == app.pid else { return }
            if wins.isEmpty { self.hide(immediately: false); return }
            let sizeChanged = wins.count != self.model.windows.count
            self.model.setWindows(wins)
            if sizeChanged, let p = self.panel { self.layout(panel: p) }
            self.model.loadThumbnails(maxAge: 0.8)
        }
    }

    private func closeWindow(_ w: WindowPreviewWindow) {
        WindowPreviewActions.close(w)
        withAnimation(.easeOut(duration: 0.15)) { model.remove(id: w.id) }
        if model.windows.isEmpty { hide(immediately: false) } else if let p = panel { layout(panel: p) }
        refreshSoon()
    }

    // MARK: Hide

    func hide(immediately: Bool) {
        showTask?.cancel()
        showTask = nil
        pendingPID = nil
        loopTask?.cancel()
        loopTask = nil
        model.cancelLoading()
        model.visible = false
        model.hoveredID = nil
        currentApp = nil
        hideWork?.cancel()
        guard let panel else { return }
        if immediately {
            panel.orderOut(nil)
            model.windows = []
            model.images = [:]
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.visible else { return }
                self.panel?.orderOut(nil)
                self.model.windows = []
                self.model.images = [:]
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
