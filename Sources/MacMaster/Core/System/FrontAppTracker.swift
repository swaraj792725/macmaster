import AppKit

/// Remembers which app the user was working in, so menu bar popovers can hand focus back to it
/// (and paste into it) instead of leaving MacMaster — and its window on some other Space — in front.
@MainActor
enum FrontAppTracker {
    private(set) static var lastExternal: NSRunningApplication?
    private static var deliberateAt = Date.distantPast
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        note(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { note(app) }
        }
    }

    private static func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternal = app
    }

    static var isSelf: (NSRunningApplication?) -> Bool = {
        $0?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Call right before MacMaster brings one of its own windows forward on purpose,
    /// so a closing popover doesn't immediately send focus elsewhere.
    static func markDeliberate() { deliberateAt = Date() }
    static var recentlyDeliberate: Bool { Date().timeIntervalSince(deliberateAt) < 1.0 }

    /// Brings `app` to the front (yielding activation as macOS 14+ requires), then runs `then`
    /// once it is actually frontmost, or after a short timeout.
    static func activate(_ app: NSRunningApplication, then: (() -> Void)? = nil) {
        guard !app.isTerminated else { then?(); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
        guard let then else { return }
        var tries = 0
        func poll() {
            tries += 1
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || tries > 30 {
                // Give the app a moment to restore its key window and text focus.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: then)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() }
            }
        }
        poll()
    }
}
