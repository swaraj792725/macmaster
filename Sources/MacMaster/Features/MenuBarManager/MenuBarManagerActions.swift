import AppKit
import SwiftUI

// MARK: - Dropdown bar, item activation and moving

extension MenuBarManager {
    /// Opens the floating glass bar under the menu bar listing hidden (and optionally always-hidden) items.
    func showDropdown(includeAlwaysHidden: Bool) {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            self.startRefreshLoopIfNeeded()
            await self.refreshNow()
            guard let win = self.toggleItem?.button?.window,
                  let screen = win.screen ?? NSScreen.main else { return }
            let hidden = self.items(in: .hidden)
            let ah = (includeAlwaysHidden && self.alwaysHiddenEnabled) ? self.items(in: .alwaysHidden) : []
            self.panel.model.notice = nil
            self.panel.model.onSelect = { [weak self] it in Task { await self?.activate(it) } }
            self.panel.model.onShow = { [weak self] it in Task { await self?.move(it, to: .visible) } }
            self.panel.model.busyID = nil
            self.panel.ignoredWindow = win
            self.panel.show(hidden: hidden, alwaysHidden: ah, anchor: win.frame, on: screen)
            self.armRehide()
            // Fetch real icon images for anything not cached yet (needs Screen Recording).
            if Permissions.isGranted(.screenRecording) {
                if await MenuBarManagerCapture.shared.refresh(hidden + ah) {
                    self.captureVersion &+= 1
                    self.panel.update(hidden: self.items(in: .hidden), alwaysHidden: ah.isEmpty ? [] : self.items(in: .alwaysHidden))
                }
            }
        }
    }

    func hideDropdown() { panel.hide() }

    /// Explains why collapsing can't work here, with a button to the system's own menu bar settings.
    func showNotice() {
        guard let win = toggleItem?.button?.window, let screen = win.screen ?? NSScreen.main else { return }
        panel.model.notice = Self.unsupportedMessage
        panel.model.onNoticeAction = { [weak self] in
            self?.panel.hide()
            self?.openSystemMenuBarSettings()
        }
        panel.ignoredWindow = win
        panel.show(hidden: [], alwaysHidden: [], anchor: win.frame, on: screen)
    }

    /// Opens the real menu of a hidden item: reveals its section, presses it, then re-hides when its menu closes.
    func activate(_ item: MenuBarManagerItem) async {
        guard isRunning, !isMoving, busyItemID == nil else { return }
        busyItemID = item.id
        panel.model.busyID = item.id
        interacting = true
        rehideTask?.cancel()
        let prior = state
        defer { busyItemID = nil; panel.model.busyID = nil }

        if item.section != .visible {
            let need: MenuBarManagerState = item.section == .alwaysHidden ? .expandedAll : .expanded
            apply(prior == .expandedAll ? .expandedAll : need, persist: false)
            try? await Task.sleep(nanoseconds: 420_000_000)
        }
        panel.hide()
        await refreshNow()
        guard let fresh = items.first(where: { $0.id == item.id }) ?? items.first(where: { $0.cacheKey == item.cacheKey }) else {
            statusMessage = "Couldn't find \(item.displayName) in the menu bar."
            finishInteraction(prior)
            return
        }
        if fresh.isOffscreen {
            statusMessage = "\(fresh.displayName) is off the bar. Free up space (fewer icons) and try again."
            finishInteraction(prior)
            return
        }

        var pressed = false
        if Permissions.isGranted(.accessibility) {
            pressed = await MenuBarManagerAutomation.pressViaAccessibility(pid: fresh.pid, frame: fresh.frame)
        }
        if !pressed {
            await MenuBarManagerAutomation.click(at: CGPoint(x: fresh.frame.midX, y: fresh.frame.midY))
            if !Permissions.isGranted(.accessibility) {
                statusMessage = "Grant Accessibility so clicks on hidden icons are reliable."
            }
        }

        // Re-hide once its menu closes. If no menu ever shows up, fall back to the rehide timer.
        let pids: Set<pid_t> = [fresh.pid]
        try? await Task.sleep(nanoseconds: 900_000_000)
        var seenMenu = false, quiet = 0
        for _ in 0..<180 {
            let open = await Task.detached { MenuBarManagerScanner.hasOpenMenu(pids: pids) }.value
            if open { seenMenu = true; quiet = 0 } else { quiet += 1 }
            if (seenMenu && quiet >= 2) || (!seenMenu && quiet >= 3) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if seenMenu { finishInteraction(prior) }
        else {
            interacting = false
            if prior == .collapsed { armRehide(seconds: max(6, MenuBarManagerPrefs.autoRehideSeconds)) }
        }
    }

    private func finishInteraction(_ prior: MenuBarManagerState) {
        interacting = false
        if prior == .collapsed { collapse() } else { apply(prior, persist: false); armRehide() }
        scheduleRefresh(after: 0.4)
    }

    // MARK: Move (⌘-drag)

    /// Moves an item to another section by simulating a ⌘-drag across the dividers.
    func move(_ item: MenuBarManagerItem, to section: MenuBarManagerSection) async {
        guard isRunning, !isMoving, item.section != section else { return }
        guard Permissions.isGranted(.accessibility) else {
            statusMessage = "Moving icons needs Accessibility access."
            return
        }
        if section == .alwaysHidden && !alwaysHiddenEnabled {
            statusMessage = "Turn on the always-hidden section first."
            return
        }
        isMoving = true; interacting = true; busyItemID = item.id
        panel.hide(); rehideTask?.cancel()
        let prior = state
        defer { isMoving = false; interacting = false; busyItemID = nil }

        apply(alwaysHiddenEnabled ? .expandedAll : .expanded, persist: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshNow()

        func fail(_ msg: String) {
            statusMessage = msg
            if prior == .collapsed { collapse() } else { apply(prior, persist: false) }
        }
        guard let cur = items.first(where: { $0.id == item.id }) ?? items.first(where: { $0.cacheKey == item.cacheKey }) else {
            return fail("Couldn't find \(item.displayName) in the menu bar.")
        }
        guard !cur.isOffscreen, !cur.isClipped || cur.section != .visible else {
            return fail("\(cur.displayName) is behind the notch or off the bar. Remove some icons to make room.")
        }
        guard let hd = dividerFrameCG, let toggle = toggleFrameCG, hd.maxX <= toggle.minX + 4 else {
            return fail("The | divider is in the wrong place. ⌘-drag it to the left of the arrow first.")
        }
        let screenMin = targetScreenFrameCG.minX + 3
        var targetX: CGFloat
        switch section {
        case .visible:
            targetX = hd.maxX + 3
        case .hidden:
            targetX = hd.minX - 4
            if alwaysHiddenEnabled, let ahd = alwaysHiddenFrameCG, ahd.maxX < hd.minX {
                targetX = max(targetX, (ahd.maxX + hd.minX) / 2)
            }
        case .alwaysHidden:
            guard let ahd = alwaysHiddenFrameCG else { return fail("Always-hidden divider isn't on the bar.") }
            targetX = ahd.minX - 4
        }
        guard targetX >= screenMin else {
            return fail("Not enough room on the bar to drop there. Remove some icons and try again.")
        }
        let from = CGPoint(x: cur.frame.midX, y: cur.frame.midY)
        await MenuBarManagerAutomation.commandDrag(from: from, to: CGPoint(x: targetX, y: from.y))
        try? await Task.sleep(nanoseconds: 600_000_000)
        await refreshNow()

        let after = items.first(where: { $0.id == cur.id }) ?? items.first(where: { $0.cacheKey == cur.cacheKey })
        if let after, after.section == section {
            statusMessage = "Moved \(after.displayName) to \(section.title)."
        } else {
            statusMessage = "Couldn't move \(cur.displayName). macOS may not allow this icon to be moved, or the drop missed."
        }
        if prior == .collapsed { collapse() } else { apply(prior, persist: false); armRehide() }
        scheduleRefresh(after: 0.5)
    }

    // MARK: - Rehide

    func armRehide(seconds: Int? = nil) {
        rehideTask?.cancel()
        let secs = seconds ?? MenuBarManagerPrefs.autoRehideSeconds
        guard secs > 0 else { return }
        rehideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let pids = Set(self.items.filter { $0.section != .visible }.map(\.pid))
                let menuOpen = await Task.detached { MenuBarManagerScanner.hasOpenMenu(pids: pids) }.value
                if self.interacting || self.isMoving || menuOpen {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                if self.panel.isVisible { self.panel.hide() }
                if self.state != .collapsed { self.collapse() }
                return
            }
        }
    }

    /// Collapse after any open item menu has closed.
    func collapseWhenIdle() {
        Task { [weak self] in
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isRunning, self.state != .collapsed else { return }
                if self.interacting || self.isMoving { return }
                let pids = Set(self.items.filter { $0.section != .visible }.map(\.pid))
                let open = await Task.detached { MenuBarManagerScanner.hasOpenMenu(pids: pids) }.value
                if !open { self.collapse(); return }
            }
        }
    }

    // MARK: - System observation

    func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreForQuit() }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            // Never block the posting thread: a background defaults write would otherwise wait on main (deadlock).
            Task { @MainActor in self?.prefsChanged() }
        })
        // Frontmost-app tracking only serves Classic's auto re-hide.
        guard runningMode == .classic else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor in self?.frontmostChanged(pid: pid) }
        }
    }

    private func screenParametersChanged() {
        panel.hide()
        if runningMode == .dropdown {
            dropdown.hide()
            lastDropdownScan = nil // bar layout changed; rescan on next open
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.isRunning else { return }
            if self.state == .collapsed, let reason = self.toggleOffscreenReason() {
                self.blockedReason = reason
                self.apply(.expanded, persist: false)
            }
            await self.refreshNow()
        }
    }

    private func frontmostChanged(pid: pid_t?) {
        guard isRunning, runningMode == .classic, state != .collapsed, !interacting, !isMoving,
              MenuBarManagerPrefs.rehideOnAppChange,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        collapseWhenIdle()
    }

    // MARK: - Preferences

    private func prefsChanged() {
        if !MenuBarManagerPrefs.enabled {
            if isRunning { teardown() }
            return
        }
        if !isRunning {
            if wantsRunning { start() }
            return
        }
        if MenuBarManagerPrefs.mode != runningMode { switchMode(); return }
        applyPrefsIfChanged(force: false)
    }

    func applyPrefsIfChanged(force: Bool) {
        let d = MenuBarManagerPrefs.self
        let hk = MenuBarManagerHotKey.stored
        let sig = [
            runningMode.rawValue, "\(d.glyph.rawValue)", "\(d.showDivider)", "\(d.alwaysHiddenEnabled)", "\(d.showOnHover)",
            "\(d.showOnScroll)", "\(d.rehideOnClick)", "\(d.hotkeyEnabled)", "\(hk.keyCode)", "\(hk.modifiers)",
        ].joined(separator: "|")
        guard force || sig != lastPrefSignature else { return }
        lastPrefSignature = sig

        if runningMode == .classic {
            syncAlwaysHiddenItem()
            panel.ignoredWindow = toggleItem?.button?.window
            reapply()
            installMonitors()
        } else {
            dropdown.ignoredWindow = toggleItem?.button?.window
            updateToggleGlyph()
        }

        let center = MenuBarManagerHotKeyCenter.shared
        center.onFire = { [weak self] in self?.toggleFromUser(optionDown: false) }
        let wanted: MenuBarManagerHotKey? = d.hotkeyEnabled ? hk : nil
        if wanted != registeredHotKey || force {
            registeredHotKey = wanted
            if let wanted {
                hotKeyStatus = center.register(wanted) ? nil : "\(wanted.display) is already used by another app."
            } else {
                center.register(nil)
                hotKeyStatus = nil
            }
        }
    }

    // MARK: - Event monitors (hover / scroll / click-away)

    func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func installMonitors() {
        removeMonitors()
        if MenuBarManagerPrefs.rehideOnClick {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                Task { @MainActor in self?.clickedElsewhere() }
            }) { monitors.append(m) }
        }
        if MenuBarManagerPrefs.showOnHover {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
                Task { @MainActor in self?.mouseMoved() }
            }) { monitors.append(m) }
        }
        if MenuBarManagerPrefs.showOnScroll {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] e in
                let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY, opt = e.modifierFlags.contains(.option)
                Task { @MainActor in self?.scrolled(dx: dx, dy: dy, option: opt) }
            }) { monitors.append(m) }
        }
    }

    private func stripScreen(at p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) && p.y >= $0.frame.maxY - MenuBarManagerGeometry.stripHeight(of: $0) }
    }

    private func clickedElsewhere() {
        guard isRunning, state != .collapsed, !interacting, !isMoving else { return }
        if stripScreen(at: NSEvent.mouseLocation) != nil { return } // clicking items on the bar itself
        collapseWhenIdle()
    }

    /// Is the pointer in the empty menu bar gap (left of our items, right of the app menus) or on the toggle?
    private func inRevealZone(_ p: NSPoint, screen: NSScreen) -> Bool {
        if let tw = toggleItem?.button?.window?.frame, tw.insetBy(dx: -2, dy: -2).contains(p) { return true }
        let leftEdge = toggleItem?.button?.window?.frame.minX ?? screen.frame.maxX
        let minX: CGFloat
        if let n = MenuBarManagerGeometry.notchRect(of: screen) { minX = n.maxX } else { minX = screen.frame.minX + screen.frame.width * 0.5 }
        return p.x >= minX && p.x < leftEdge - 2
    }

    private func reveal(includeAlwaysHidden: Bool) {
        if MenuBarManagerPrefs.dropdownBar { showDropdown(includeAlwaysHidden: includeAlwaysHidden) }
        else { expand(includeAlwaysHidden: includeAlwaysHidden) }
    }

    private func mouseMoved() {
        guard isRunning, MenuBarManagerPrefs.showOnHover, !interacting, !isMoving else { return }
        let loc = NSEvent.mouseLocation
        let strip = stripScreen(at: loc)
        let revealed = state != .collapsed || panel.isVisible
        if !revealed {
            guard let screen = strip, inRevealZone(loc, screen: screen) else {
                hoverTask?.cancel(); hoverTask = nil
                return
            }
            if hoverTask == nil {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.hoverTask = nil
                    guard self.state == .collapsed, !self.panel.isVisible else { return }
                    self.hoverRevealed = true
                    self.reveal(includeAlwaysHidden: false)
                }
            }
        } else if hoverRevealed {
            let inPanel = panel.frame?.insetBy(dx: -6, dy: -6).contains(loc) ?? false
            if strip != nil || inPanel {
                hoverTask?.cancel(); hoverTask = nil
            } else if hoverTask == nil {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.hoverTask = nil
                    guard self.hoverRevealed, !self.interacting else { return }
                    if self.panel.isVisible { self.panel.hide() }
                    if self.state != .collapsed { self.collapse() }
                    self.hoverRevealed = false
                }
            }
        }
    }

    private func scrolled(dx: CGFloat, dy: CGFloat, option: Bool) {
        guard isRunning, MenuBarManagerPrefs.showOnScroll, state == .collapsed, !panel.isVisible,
              abs(dx) + abs(dy) > 1.5, stripScreen(at: NSEvent.mouseLocation) != nil else { return }
        reveal(includeAlwaysHidden: option && MenuBarManagerPrefs.optionClickAlwaysHidden)
    }
}
