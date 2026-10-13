import AppKit

extension NSPopover {
    /// MacMaster is a regular (Dock) app, so a status-item popover would open on the app's own Space —
    /// invisible over a full-screen app or another desktop. Let it join whatever Space is active.
    func showFromStatusItem(_ button: NSView) {
        show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard let w = contentViewController?.view.window else { return }
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        w.makeKey()
    }
}
