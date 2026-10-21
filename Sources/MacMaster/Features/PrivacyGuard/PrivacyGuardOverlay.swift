import SwiftUI
import AppKit

/// Why the screen is covered. Shown on the overlay.
enum PrivacyGuardReason: String, Sendable {
    case walkAway, shoulderSurfer, lookAway

    var detail: String {
        switch self {
        case .walkAway: "Nobody is at the screen"
        case .shoulderSurfer: "More than one person is looking"
        case .lookAway: "You are looking away"
        }
    }
}

/// Panel that takes the first click without activating MacMaster or stealing focus from the app underneath.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct OverlayContent: View {
    let reason: PrivacyGuardReason
    let onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            Text("Privacy Guard")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(reason.detail)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
            Button(action: onSnooze) {
                Text("Show my screen for 1 minute")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Text("or press Esc")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-screen blur on every display. Blocks clicks while shown; fades in and out.
@MainActor
final class PrivacyGuardOverlay {
    private var windows: [OverlayPanel] = []
    private var keyMonitors: [Any] = []
    private(set) var isShown = false
    private var reason: PrivacyGuardReason = .walkAway
    private var screenObserver: NSObjectProtocol?
    var onSnooze: () -> Void = {}

    func show(_ reason: PrivacyGuardReason) {
        self.reason = reason
        if isShown {
            // Same windows, new wording.
            for w in windows { w.contentView = makeContent(for: w) }
            return
        }
        isShown = true
        build()
        for w in windows {
            w.alphaValue = 0
            w.orderFrontRegardless()
        }
        fade(to: 1, then: nil)
        installKeyMonitors()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildForNewScreens() }
        }
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        isShown = false
        removeKeyMonitors()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        let closing = windows
        windows = []
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                closing.forEach { $0.orderOut(nil) }
            }
        })
    }

    // MARK: Building

    private func build() {
        windows = NSScreen.screens.map { screen in
            let w = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = makeContent(for: w)
            return w
        }
    }

    private func makeContent(for window: NSWindow) -> NSView {
        let blur = NSVisualEffectView(frame: window.frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let dark = NSView(frame: blur.bounds)
        dark.wantsLayer = true
        dark.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dark.autoresizingMask = [.width, .height]
        blur.addSubview(dark)

        let host = FirstMouseHostingView(rootView: OverlayContent(reason: reason, onSnooze: { [weak self] in self?.onSnooze() }))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        return blur
    }

    private func rebuildForNewScreens() {
        guard isShown else { return }
        let old = windows
        build()
        for w in windows { w.orderFrontRegardless() }
        old.forEach { $0.orderOut(nil) }
    }

    private func fade(to alpha: CGFloat, then done: (() -> Void)?) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            windows.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: { done?() })
    }

    // MARK: Esc

    private func installKeyMonitors() {
        // Local: when MacMaster is active. Global: other apps in front (works once Accessibility is granted).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.onSnooze() }
            return nil
        }) { keyMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.onSnooze() }
        }) { keyMonitors.append(m) }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
    }
}
