import AppKit
import SwiftUI
import Observation

/// Non-activating transparent panel that never takes focus.
final class TilingPanel: NSPanel {
    init(ignoresMouse: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = ignoresMouse
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

@MainActor @Observable
final class TilingOverlayModel {
    /// Highlight rect in panel-local coordinates (top-left origin).
    var rect: CGRect = .zero
    var visible = false
}

private struct TilingOverlayView: View {
    let model: TilingOverlayModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.accentColor.opacity(0.16)))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 3))
                .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5).padding(3))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 18)
                .frame(width: max(1, model.rect.width), height: max(1, model.rect.height))
                .offset(x: model.rect.minX, y: model.rect.minY)
                .opacity(model.visible ? 1 : 0)
                .scaleEffect(model.visible ? 1 : 0.97, anchor: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Translucent target-frame preview shown while dragging / hovering layouts.
@MainActor
final class TilingOverlay {
    static let shared = TilingOverlay()

    private let model = TilingOverlayModel()
    private var panel: TilingPanel?
    private var screen: TilingScreenInfo?
    private var token = 0

    private func ensurePanel() -> TilingPanel {
        if let panel { return panel }
        let p = TilingPanel(ignoresMouse: true)
        p.setContent(TilingOverlayView(model: model))
        panel = p
        return p
    }

    /// Show/move the highlight to `axRect` (AX coords) on `screen`. Springs between zones.
    func show(axRect: CGRect, on screen: TilingScreenInfo) {
        token += 1
        let p = ensurePanel()
        let local = CGRect(x: axRect.minX - screen.frame.minX, y: axRect.minY - screen.frame.minY,
                           width: axRect.width, height: axRect.height)
        if !p.isVisible || self.screen?.id != screen.id || !model.visible {
            p.setFrame(screen.nsFrame, display: false)
            p.orderFrontRegardless()
            self.screen = screen
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { model.rect = local }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { model.visible = true }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.rect = local }
        }
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        token += 1
        let t = token
        withAnimation(.easeOut(duration: 0.16)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.token == t else { return }
            self.panel?.orderOut(nil)
            self.screen = nil
        }
    }
}
