import AppKit

/// Drag-to-edge snapping with a live highlight. Uses global mouse monitors (no event consumption).
@MainActor
final class TilingSnapController {
    static let shared = TilingSnapController()

    private struct Drag {
        var token: Int
        var startMouse: CGPoint
        var window: TilingWindow?
        var startFrame: CGRect = .zero
        var moved = false
        var resizing = false
        var zone: TilingLayout?
        var screen: TilingScreenInfo?
    }

    private var monitor: Any?
    private var drag: Drag?
    private var token = 0
    private var screens: [TilingScreenInfo] = []
    private var latestCursor: CGPoint = .zero
    private var queryInFlight = false
    private var lastQuery: TimeInterval = 0
    private let axQueue = DispatchQueue(label: "MacMaster.Tiling.snap", qos: .userInteractive)

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        drag = nil
        TilingOverlay.shared.hide()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: mouseDragged()
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    // MARK: Events

    private func mouseDown() {
        drag = nil
        guard TilingSettings.enabled, TilingSettings.snapEnabled, AXIsProcessTrusted() else { return }
        token += 1
        let t = token
        let p = TilingScreens.mouseAX
        screens = TilingScreens.snapshot()
        latestCursor = p
        queryInFlight = false
        drag = Drag(token: t, startMouse: p)
        axQueue.async { [weak self] in
            guard let w = TilingAX.window(at: p), let f = TilingAX.frame(w.element) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.drag?.token == t else { return }
                    self.drag?.window = w
                    self.drag?.startFrame = f
                }
            }
        }
    }

    private func mouseDragged() {
        guard let d = drag, let w = d.window, !d.resizing else { return }
        let cursor = TilingScreens.mouseAX
        latestCursor = cursor
        if d.moved {
            updateZone(cursor)
            return
        }
        guard hypot(cursor.x - d.startMouse.x, cursor.y - d.startMouse.y) > 3, !queryInFlight else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastQuery > 0.04 else { return }
        lastQuery = now
        queryInFlight = true
        let t = d.token
        axQueue.async { [weak self] in
            let f = TilingAX.frame(w.element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleFrame(f, token: t) }
            }
        }
    }

    private func handleFrame(_ f: CGRect?, token t: Int) {
        queryInFlight = false
        guard var d = drag, d.token == t, let w = d.window, let f else { return }
        let sizeChanged = abs(f.width - d.startFrame.width) > 2 || abs(f.height - d.startFrame.height) > 2
        let dist = hypot(f.minX - d.startFrame.minX, f.minY - d.startFrame.minY)
        if sizeChanged && !d.moved {
            d.resizing = true
            drag = d
            TilingOverlay.shared.hide()
            return
        }
        guard dist > 2 else { return }
        d.moved = true
        drag = d
        if TilingSettings.restoreOnDrag { restoreSizeIfSnapped(window: w, drag: d) }
        updateZone(latestCursor)
    }

    /// Windows-style: dragging a snapped window away gives back its pre-snap size.
    private func restoreSizeIfSnapped(window w: TilingWindow, drag d: Drag) {
        let mem = TilingMemory.shared
        guard let e = mem.entry(w.key), TilingGeometry.approx(e.snapped, d.startFrame, tol: 8) else { return }
        mem.remove(w.key)
        let orig = e.original.size
        guard abs(orig.width - d.startFrame.width) > 2 || abs(orig.height - d.startFrame.height) > 2 else { return }
        let ratio = min(max((d.startMouse.x - d.startFrame.minX) / max(1, d.startFrame.width), 0), 1)
        let yOff = min(max(d.startMouse.y - d.startFrame.minY, 8), max(8, orig.height - 8))
        let origin = CGPoint(x: latestCursor.x - ratio * orig.width, y: latestCursor.y - yOff)
        axQueue.async {
            TilingAX.setSize(w.element, orig)
            TilingAX.setPosition(w.element, origin)
        }
    }

    private func updateZone(_ cursor: CGPoint) {
        guard var d = drag, d.moved else { return }
        let hit = TilingZones.zone(at: cursor, screens: screens, config: TilingSettings.zones)
        if hit?.layout == d.zone, hit?.screen.id == d.screen?.id { return }
        d.zone = hit?.layout
        d.screen = hit?.screen
        drag = d
        guard let hit,
              let target = TilingGeometry.target(for: hit.layout, current: d.startFrame, screen: hit.screen,
                                                 gap: TilingSettings.gap) else {
            TilingOverlay.shared.hide()
            return
        }
        TilingOverlay.shared.show(axRect: target, on: hit.screen)
    }

    private func mouseUp() {
        defer { drag = nil }
        guard let d = drag else { return }
        TilingOverlay.shared.hide()
        guard d.moved, !d.resizing, let w = d.window, let layout = d.zone, let screen = d.screen else { return }
        let scr = screens
        let gap = TilingSettings.gap
        // Let the window server finish the drag before we place the window.
        axQueue.asyncAfter(deadline: .now() + 0.03) {
            TilingActions.perform(layout, window: w, screens: scr, gap: gap, targetScreen: screen)
        }
    }
}
