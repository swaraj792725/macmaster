import AppKit

extension NSPopover {
    /// MacMaster is a regular (Dock) app, so a status-item popover would open on the app's own Space —
    /// invisible over a full-screen app or another desktop. Let it join whatever Space is active.
    /// When it closes, focus goes back to the app the user was in, so macOS doesn't jump to
    /// MacMaster's own window (often on a different Space or the desktop).
    func showFromStatusItem(_ button: NSView) {
        let opener = NSWorkspace.shared.frontmostApplication
        show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let w = contentViewController?.view.window else { return }
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        w.makeKey()

        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: self, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated {
                guard let opener, !FrontAppTracker.isSelf(opener), !opener.isTerminated else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard NSApp.isActive, !FrontAppTracker.recentlyDeliberate else { return }
                    FrontAppTracker.activate(opener)
                }
            }
        }
    }
}
