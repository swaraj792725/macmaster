import AppKit
import ApplicationServices

/// Drag in: ⌘-drag an icon off the menu bar and release it over the flyout (or the « toggle) to hide it.
/// Passive: only global mouse monitors, and only a cheap check on ⌘-click in the strip until a drag really starts.
/// The bar itself still does its native ⌘-drag; this just watches where the pointer is released.
@MainActor
final class MenuBarManagerBarDragWatcher {
    private struct Session {
        let entry: MenuBarManagerEntry
        let start: NSPoint
        var opened = false
    }

    private weak var manager: MenuBarManager?
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var session: Session?

    func install(for manager: MenuBarManager) {
        self.manager = manager
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            guard e.modifierFlags.contains(.command) else { return }
            let loc = NSEvent.mouseLocation
            Task { @MainActor in self?.began(at: loc) }
        }
    }

    func remove() {
        finish()
        if let m = downMonitor { NSEvent.removeMonitor(m) }
        downMonitor = nil
    }

    // MARK: Session

    private func began(at loc: NSPoint) {
        guard let manager, manager.isRunning, manager.runningMode == .dropdown else { return }
        guard NSScreen.screens.contains(where: { $0.frame.contains(loc) && loc.y >= $0.frame.maxY - MenuBarManagerGeometry.stripHeight(of: $0) })
        else { return }
        guard let entry = entry(at: loc, in: manager) else { return }
        finish()
        session = Session(entry: entry, start: loc)
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor in self?.dragged(to: p) }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor in self?.released(at: p) }
        }
    }

    /// The icon under the pointer: from the last scan's frames, else by asking Accessibility which app owns the spot.
    private func entry(at loc: NSPoint, in manager: MenuBarManager) -> MenuBarManagerEntry? {
        let cg = MenuBarManagerGeometry.cgRect(fromAppKit: CGRect(origin: loc, size: .zero)).origin
        let movable = manager.dropdownEntries.filter {
            $0.visibility.isShowing && !MenuBarManager.isLocked(name: $0.displayName, identifier: $0.identifier)
        }
        if let e = movable.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(cg) }) { return e }
        if SelfAX.ownsWindow(at: cg) {
            return movable.filter { $0.pid == SelfAX.pid }.min { abs($0.frame.midX - cg.x) < abs($1.frame.midX - cg.x) }
        }
        guard Permissions.isGranted(.accessibility), let el = SelfAX.element(at: cg, timeout: 0.1) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return movable.filter { $0.pid == pid }.min { abs($0.frame.midX - cg.x) < abs($1.frame.midX - cg.x) }
    }

    private func dragged(to p: NSPoint) {
        guard var s = session, let manager else { return }
        if !s.opened {
            guard hypot(p.x - s.start.x, p.y - s.start.y) > 8 else { return }
            s.opened = true
            session = s
            manager.openDropdown(forDrag: true)
        }
        let over = overTarget(p, manager)
        if manager.dropdown.model.dropTarget != over { manager.dropdown.model.dropTarget = over }
    }

    private func overTarget(_ p: NSPoint, _ manager: MenuBarManager) -> Bool {
        if let f = manager.dropdown.frame?.insetBy(dx: 6, dy: 6), f.contains(p) { return true }
        if let t = manager.toggleItem?.button?.window?.frame, t.insetBy(dx: -4, dy: -4).contains(p) { return true }
        return false
    }

    private func released(at p: NSPoint) {
        guard let s = session, let manager else { return finish() }
        let over = s.opened && overTarget(p, manager)
        finish()
        manager.dropdown.model.dropTarget = false
        if over {
            _ = manager.dropTiles([MenuBarManagerTile.payloadPrefix + s.entry.id], into: .overflow) { manager.showDropdownMessage($0) }
        } else if s.opened, manager.dropdown.isVisible {
            manager.dropdown.hide() // we opened it for the drag; the drop went somewhere else
        }
        // The bar may have re-laid itself out (native ⌘-drag); look again once it settles.
        manager.lastDropdownScan = nil
        guard s.opened else { return }
        Task { [weak manager] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let manager, manager.dropdown.isVisible else { return }
            await manager.refreshDropdownInventory(force: true)
        }
    }

    private func finish() {
        for m in [dragMonitor, upMonitor] { if let m { NSEvent.removeMonitor(m) } }
        dragMonitor = nil; upMonitor = nil
        session = nil
    }
}
