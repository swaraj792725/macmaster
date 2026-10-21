import SwiftUI
import AppKit

/// What a toast shows.
struct CaptureToast {
    var title: String
    var detail: String = ""
    var symbol: String = "checkmark.circle.fill"
    var tint: Color = .green
    var swatch: Color? = nil
    var thumbnail: NSImage? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Seconds on screen.
    var duration: Double = 3.5
}

/// Small floating confirmation near the bottom of the screen. One at a time; released when it fades out.
@MainActor
final class CaptureHUD {
    static let shared = CaptureHUD()
    private var panel: NSPanel?
    private var generation = 0
    private init() {}

    func show(_ toast: CaptureToast) {
        generation += 1
        let gen = generation
        dismissNow()

        let view = CaptureToastView(toast: toast, dismiss: { [weak self] in self?.dismiss(gen) })
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let p = HUDPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = p.frame.size
            p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: vf.minY + 56))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            self?.dismiss(gen)
        }
    }

    private func dismiss(_ gen: Int) {
        guard gen == generation, let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                p.contentView = nil
                p.orderOut(nil)
                p.close()
            }
        })
    }

    private func dismissNow() {
        guard let p = panel else { return }
        panel = nil
        p.contentView = nil
        p.orderOut(nil)
        p.close()
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CaptureToastView: View {
    let toast: CaptureToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = toast.actionTitle, let act = toast.action {
                Button(t) { act(); dismiss() }
                    .buttonStyle(.mmPrimary(tint: .accentColor))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(8)
        .onTapGesture { dismiss() }
    }

    @ViewBuilder private var leading: some View {
        if let img = toast.thumbnail {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        } else if let sw = toast.swatch {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sw)
                .frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        } else {
            Image(systemName: SymbolKit.resolve(toast.symbol))
                .font(.system(size: 22)).foregroundStyle(toast.tint)
        }
    }
}
