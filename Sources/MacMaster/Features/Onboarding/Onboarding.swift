import SwiftUI
import AppKit

/// First-launch flow. Presented in its own window; safe to re-run from anywhere via `show()`.
@MainActor
enum Onboarding {
    /// Bump to show the flow again to everyone (e.g. after a major release adds new permissions).
    static let currentVersion = 1
    static let completedKey = "mm.onboarding.completed"
    static let versionKey = "mm.onboarding.version"
    /// Posted (no object) when the user changes launch/Dock/menu-bar preferences in the flow,
    /// so the app can refresh its status item. Defaults keys are already written.
    static let preferencesChanged = Notification.Name("MacMaster.onboardingPreferencesChanged")

    private static var window: NSWindow?
    private static var delegate: WindowDelegate?

    static var isNeeded: Bool {
        if ProcessInfo.processInfo.environment["MM_ONBOARDING"] == "1" { return true }
        let d = UserDefaults.standard
        return !d.bool(forKey: completedKey) || d.integer(forKey: versionKey) < currentVersion
    }

    static func showIfNeeded() {
        if isNeeded { show() }
    }

    static func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 720, height: 520)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        let host = NSHostingView(rootView: OnboardingView { section in finish(openSection: section) })
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        w.contentView = glass
        w.setContentSize(size)
        w.center()

        let del = WindowDelegate()
        w.delegate = del
        delegate = del
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private static func markCompleted() {
        let d = UserDefaults.standard
        d.set(true, forKey: completedKey)
        d.set(currentVersion, forKey: versionKey)
    }

    private static func finish(openSection section: String?) {
        markCompleted()
        window?.close()
        let hideDock = UserDefaults.standard.bool(forKey: "mm.app.hideDockIcon")
        NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
        NotificationCenter.default.post(name: preferencesChanged, object: nil)
        // Bring the main window forward (best effort; it has no App/ dependency).
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "MacMaster" }) {
            main.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        if let section {
            NotificationCenter.default.post(name: Notification.Name("MacMaster.openSection"), object: section)
        }
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            // Closing with the red button counts as "skip": don't nag on every launch.
            MainActor.assumeIsolated {
                Onboarding.markCompleted()
                Onboarding.window = nil
                Onboarding.delegate = nil
            }
        }
    }
}
