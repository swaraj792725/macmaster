import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class TilingSnapPanelModel {
    var hovered: TilingLayout?
    @ObservationIgnored var onHover: ((TilingLayout?) -> Void)?
    @ObservationIgnored var onSelect: ((TilingLayout) -> Void)?
}

private struct TilingSnapPanelView: View {
    let model: TilingSnapPanelModel
    static let cell = CGSize(width: 46, height: 32)
    static let columns = 5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let cols = Array(repeating: GridItem(.fixed(Self.cell.width), spacing: 8), count: Self.columns)
        VStack(spacing: 8) {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(TilingLayout.gridOrder) { layout in
                    TilingLayoutDiagram(layout: layout, highlighted: model.hovered == layout, accent: .accentColor)
                        .frame(width: Self.cell.width, height: Self.cell.height)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { model.hovered = layout; model.onHover?(layout) }
                            else if model.hovered == layout { model.hovered = nil; model.onHover?(nil) }
                        }
                        .onTapGesture { model.onSelect?(layout) }
                }
            }
            Text(model.hovered?.title ?? "Snap to layout")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 14)
        }
        .padding(12)
        .frame(width: TilingSnapLayoutsController.panelSize.width, height: TilingSnapLayoutsController.panelSize.height)
        .modifier(TilingGlass(radius: 16))
        .clipShape(shape)
    }
}

/// Windows 11 style "Snap Layouts": rest the cursor on a window's green button to get a layout picker.
@MainActor
final class TilingSnapLayoutsController {
    static let shared = TilingSnapLayoutsController()
    static let panelSize = CGSize(width: 5 * 46 + 4 * 8 + 24, height: 2 * 8 + 3 * 32 + 14 + 24)

    private struct Candidate { var window: TilingWindow; var button: CGRect }

    private var monitor: Any?
    private var candidate: Candidate?
    private var dwell: Task<Void, Never>?
    private var inFlight = false
    private var trailingScheduled = false
    private var lastProbe: TimeInterval = 0
    private var suppressed = false

    private var panel: TilingPanel?
    private let model = TilingSnapPanelModel()
    private var shown: Candidate?
    private var shownFrame: CGRect = .zero      // NS coords
    private var shownWindowFrame: CGRect = .zero // AX coords
    private var shownScreens: [TilingScreenInfo] = []
    private var tracker: Timer?
    private var outsideSince: TimeInterval?
    private let axQueue = DispatchQueue(label: "MacMaster.Tiling.snapLayouts", qos: .userInitiated)

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        model.onHover = { [weak self] l in self?.preview(l) }
        model.onSelect = { [weak self] l in self?.choose(l) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestProbe() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        dismiss()
        dwell?.cancel()
        candidate = nil
    }

    // MARK: Probing the zoom button

    private func requestProbe() {
        guard panel?.isVisible != true else { return }
        guard TilingSettings.enabled, TilingSettings.snapLayoutsEnabled, NSEvent.pressedMouseButtons == 0 else {
            clearCandidate()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if inFlight || now - lastProbe < 0.06 {
            scheduleTrailing()
            return
        }
        probe()
    }

    /// Guarantees the final resting position is hit-tested even when events were throttled.
    private func scheduleTrailing() {
        guard !trailingScheduled else { return }
        trailingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trailingScheduled = false
                if self.panel?.isVisible != true { self.requestProbe() }
            }
        }
    }

    private func probe() {
        guard AXIsProcessTrusted() else { return }
        let p = TilingScreens.mouseAX
        // Still inside the known button: nothing to do, the dwell timer is running.
        if let c = candidate, c.button.insetBy(dx: -1, dy: -1).contains(p) { return }
        lastProbe = ProcessInfo.processInfo.systemUptime
        inFlight = true
        axQueue.async { [weak self] in
            let hit = TilingAX.zoomButton(at: p)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleHit(hit) }
            }
        }
    }

    private func handleHit(_ hit: (window: TilingWindow, button: CGRect)?) {
        inFlight = false
        guard let hit else {
            suppressed = false
            clearCandidate()
            return
        }
        guard !suppressed else { return }
        if let c = candidate, TilingGeometry.approx(c.button, hit.button, tol: 2) { return }
        clearCandidate()
        candidate = Candidate(window: hit.window, button: hit.button)
        dwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.dwellElapsed()
        }
    }

    private func clearCandidate() {
        dwell?.cancel()
        dwell = nil
        candidate = nil
    }

    private func dwellElapsed() {
        guard let c = candidate, TilingSettings.snapLayoutsEnabled, NSEvent.pressedMouseButtons == 0 else { return }
        guard c.button.insetBy(dx: -2, dy: -2).contains(TilingScreens.mouseAX) else { return }
        showPanel(for: c)
    }

    // MARK: Panel

    private func ensurePanel() -> TilingPanel {
        if let panel { return panel }
        let p = TilingPanel(ignoresMouse: false)
        p.setContent(TilingSnapPanelView(model: model))
        panel = p
        return p
    }

    private func showPanel(for c: Candidate) {
        let screens = TilingScreens.snapshot()
        guard let screen = TilingScreens.screen(containing: CGPoint(x: c.button.midX, y: c.button.midY), in: screens),
              let winFrame = TilingAX.frame(c.window.element) else { return }
        let size = Self.panelSize
        let btn = TilingScreens.nsRect(fromAX: c.button)
        let vis = screen.visible
        let nsVis = TilingScreens.nsRect(fromAX: vis)
        // To the right of the green button (macOS's own menu drops below it).
        var origin = CGPoint(x: btn.maxX + 12, y: btn.maxY + 6 - size.height)
        if origin.x + size.width > nsVis.maxX - 6 { origin.x = btn.minX - 12 - size.width }
        origin.x = min(max(origin.x, nsVis.minX + 6), nsVis.maxX - size.width - 6)
        origin.y = min(max(origin.y, nsVis.minY + 6), nsVis.maxY - size.height - 6)
        let frame = NSRect(origin: origin, size: CGSize(width: size.width, height: size.height))

        let p = ensurePanel()
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        shown = c
        shownFrame = frame
        shownWindowFrame = winFrame
        shownScreens = screens
        outsideSince = nil
        model.hovered = nil
        dwell = nil

        tracker?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tracker = t
    }

    /// Dismiss when the cursor leaves the button + panel region.
    private func tick() {
        guard let c = shown else { dismiss(); return }
        let m = NSEvent.mouseLocation
        let btn = TilingScreens.nsRect(fromAX: c.button).insetBy(dx: -8, dy: -8)
        let region = shownFrame.insetBy(dx: -10, dy: -10).union(btn)
        // A hole-free union is fine: the gap between button and panel is small and bridged by the union rect.
        if region.contains(m) { outsideSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let t = outsideSince {
            if now - t > 0.12 { dismiss() }
        } else {
            outsideSince = now
        }
    }

    private func dismiss() {
        tracker?.invalidate()
        tracker = nil
        shown = nil
        clearCandidate()
        model.hovered = nil
        TilingOverlay.shared.hide()
        if let p = panel, p.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.shown == nil else { return }
                    self.panel?.orderOut(nil)
                }
            })
        }
    }

    // MARK: Preview / apply

    private func preview(_ layout: TilingLayout?) {
        guard let layout, let c = shown, let screen = TilingScreens.screen(for: shownWindowFrame, in: shownScreens),
              let target = TilingGeometry.target(for: layout, current: shownWindowFrame, screen: screen,
                                                 gap: TilingSettings.gap) else {
            TilingOverlay.shared.hide()
            return
        }
        _ = c
        TilingOverlay.shared.show(axRect: target, on: screen)
    }

    private func choose(_ layout: TilingLayout) {
        guard let c = shown else { return }
        let screens = shownScreens
        let gap = TilingSettings.gap
        suppressed = true
        dismiss()
        axQueue.async {
            TilingActions.perform(layout, window: c.window, screens: screens, gap: gap)
        }
    }
}
