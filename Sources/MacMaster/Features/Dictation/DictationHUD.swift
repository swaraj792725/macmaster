import SwiftUI
import AppKit
import Observation

/// What the floating pill shows.
@MainActor @Observable
final class DictationHUDModel {
    enum Phase { case listening, working, done, error }
    var phase: Phase = .listening
    var text = ""
    var message = ""
    /// Recent input levels, newest last.
    var levels: [Float] = Array(repeating: 0, count: 14)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

private struct DictationHUDView: View {
    let model: DictationHUDModel

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(minWidth: 150, maxWidth: 460)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 2.5) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { _, v in
                    Capsule().fill(.red.gradient)
                        .frame(width: 3, height: 5 + CGFloat(v) * 20)
                }
            }
            .frame(height: 26)
            .animation(.linear(duration: 0.06), value: model.levels)
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 18))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .listening:
            Text(model.text.isEmpty ? "Listening…" : model.text)
                .font(.system(size: 14))
                .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                .lineLimit(2).truncationMode(.head)
                .multilineTextAlignment(.leading)
        case .working:
            Text("Transcribing…").font(.system(size: 14)).foregroundStyle(.secondary)
        case .done, .error:
            Text(model.message).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
        }
    }
}

/// Click-through pill near the bottom-center of the screen with the level bars and partial text.
@MainActor
final class DictationHUD {
    private var panel: NSPanel?
    private let model = DictationHUDModel()
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    func showListening() {
        model.phase = .listening
        model.text = ""
        model.levels = Array(repeating: 0, count: model.levels.count)
        present()
    }

    func update(text: String) { model.text = text }
    func push(level: Float) { if model.phase == .listening { model.push(level) } }

    func showWorking() { model.phase = .working; present() }

    func showDone(_ message: String, hideAfter: TimeInterval = 1.4) {
        model.phase = .done; model.message = message
        present(); scheduleHide(hideAfter)
    }

    func showError(_ message: String, hideAfter: TimeInterval = 3.5) {
        model.phase = .error; model.message = message
        present(); scheduleHide(hideAfter)
    }

    func hide() {
        hideTask?.cancel()
        guard let p = panel else { return }
        generation += 1
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if self.generation == gen { p.orderOut(nil) } }
        })
    }

    private func scheduleHide(_ after: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func present() {
        hideTask?.cancel()
        generation += 1
        let p = panel ?? makePanel()
        panel = p
        position(p)
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: DictationHUDView(model: model).frame(width: 500, height: 90, alignment: .center))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 90)
        p.contentView = host
        return p
    }

    private func position(_ p: NSPanel) {
        // The screen the pointer is on, falling back to the main one.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 36))
    }
}
