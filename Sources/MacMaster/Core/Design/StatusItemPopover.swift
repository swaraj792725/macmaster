import AppKit

extension NSPopover {
    /// MacMaster is a regular (Dock) app, so a status-item popover would open on the app's own Space —
    /// invisible over a full-screen app or another desktop. Let it join whatever Space is active.
    /// When it closes, focus goes back to the app the user was in, so macOS doesn't jump to
    /// MacMaster's own window (often on a different Space or the desktop).
    func showFromStatusItem(_ button: NSView) {
        let opener = NSWorkspace.shared.frontmostApplication
        // A transient popover shown while another app is active closes itself again at once (the click redirect
        // over Apple's Control Center and clock opens it without MacMaster ever becoming active). While shown it is
        // application-defined instead, and closes on a click outside or Escape just like a transient one.
        let managed = behavior == .transient
        if managed { behavior = .applicationDefined }
        show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let w = contentViewController?.view.window else {
            if managed { behavior = .transient }
            return
        }
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // The window was ordered in before it could join a full-screen app's Space; order it in again so it shows there.
        w.orderFrontRegardless()
        w.makeKey()

        var monitors: [Any] = []
        if managed {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            // Clicks in other apps (and the menu bar items of other apps).
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.performClose(nil) }
            }) { monitors.append(m) }
            // Clicks in MacMaster's other windows and status items. Clicks in the popover (or its menus and sheets)
            // and on the view that opened it are left alone: that icon's own action toggles the popover.
            let opening = button.window
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask.union(.keyDown), handler: { [weak self, weak w, weak opening] e in
                guard let self, self.isShown else { return e }
                if e.type == .keyDown {
                    guard e.keyCode == 53 else { return e } // Escape
                    self.performClose(nil)
                    return nil
                }
                var win = e.window
                while let x = win {
                    if x === w || x === opening { return e }
                    win = x.parent
                }
                self.performClose(nil)
                return e
            }) { monitors.append(m) }
        }

        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: self, queue: .main) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            MainActor.assumeIsolated {
                if managed { self?.behavior = .transient }
                guard let opener, !FrontAppTracker.isSelf(opener), !opener.isTerminated else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard NSApp.isActive, !FrontAppTracker.recentlyDeliberate else { return }
                    FrontAppTracker.activate(opener)
                }
            }
        }
    }
}
