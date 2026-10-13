import AppKit

// MARK: - Dropdown mode engine
//
// Never hides, resizes or moves anything in the menu bar. Only reads Accessibility (and, for icon
// images, ScreenCaptureKit) and presses items on request. No timers or polling: the inventory is rescanned
// lazily when the dropdown opens (or the settings page shows), and cached icon captures live about 30 s.

extension MenuBarManager {
    // MARK: Lifecycle

    /// Dropdown mode start: one status item, hot key, and a few passive observers. No refresh loop, no monitors.
    func startDropdown() {
        isRunning = true
        statusMessage = nil
        state = .expanded
        isCollapsed = false
        buildControlItems()
        applyPrefsIfChanged(force: true)
        observeSystem()
        observeWorkspaceForDropdown()
        barDrag.install(for: self)
        updateToggleGlyph()
        // Warm the inventory once, off the critical path, so the first open already has data.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.refreshDropdownInventory()
        }
    }

    /// App launch / quit changes the item set: drop stale captures and rescan on next open.
    private func observeWorkspaceForDropdown() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundle = app?.bundleIdentifier
                let ended = name == NSWorkspace.didTerminateApplicationNotification
                Task { @MainActor in self?.appSetChanged(bundleID: bundle, terminated: ended) }
            }
            dropdownObservers.append(token)
        }
    }

    private func appSetChanged(bundleID: String?, terminated: Bool) {
        guard isRunning, runningMode == .dropdown else { return }
        RunningAppCache.shared.invalidate()
        lastDropdownScan = nil
        if let bundleID, terminated {
            MenuBarManagerCapture.shared.remove(prefix: bundleID + "|")
            iconCache = iconCache.filter { RunningAppCache.shared[$0.key] != nil }
        }
        // Only touch the system again if the list is on screen; otherwise it rescans on next open.
        if dropdown.isVisible {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                await self?.refreshDropdownInventory()
            }
        }
    }

    /// Settings picked another mode: restore everything, then start the other one.
    func switchMode() {
        guard isRunning, runningMode != MenuBarManagerPrefs.mode else { return }
        teardown() // classic: dividers back to normal length, items removed; dropdown: panel closed
        MenuBarManagerPrefs.defaults.set(false, forKey: MenuBarManagerPrefs.collapsedKey)
        if wantsRunning { start() }
    }

    // MARK: Open / close

    func toggleDropdown(includeAlwaysHidden: Bool = false) {
        guard isRunning, runningMode == .dropdown else { return }
        if dropdown.isVisible { dropdown.hide() } else { openDropdown(includeAlwaysHidden: includeAlwaysHidden) }
    }

    /// `forDrag`: opened for a ⌘-drag from the bar. No focus grab, no rescan (the list must hold still under the pointer).
    func openDropdown(includeAlwaysHidden: Bool = false, forDrag: Bool = false) {
        guard isRunning, runningMode == .dropdown else { return }
        let win = toggleItem?.button?.window
        let anchorOK: Bool = {
            guard let win, win.isVisible, let s = win.screen else { return false }
            return win.frame.maxY >= s.frame.maxY - 2 && win.frame.minY >= s.frame.maxY - 80
        }()
        let screen: NSScreen = (anchorOK ? win?.screen : nil)
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let anchor: CGRect
        if anchorOK, let win { anchor = win.frame }
        else { anchor = CGRect(x: screen.frame.maxX - 40, y: screen.frame.maxY - 24, width: 24, height: 24) }
        dropdown.ignoredWindow = win
        dropdown.onSettings = { MenuBarManager.openSettingsHandler?() }
        dropdown.show(anchor: anchor, on: screen, includeAlwaysHidden: includeAlwaysHidden, focus: !forDrag)
        dropdownMessage = nil
        guard !forDrag else { return }
        Task { [weak self] in
            await self?.refreshDropdownInventory()
        }
    }

    // MARK: Inventory

    /// Scans every app's menu bar items, classifies visibility, then captures icon images for on-screen ones.
    func refreshDropdownInventory(force: Bool = false) async {
        guard isRunning, runningMode == .dropdown, !dropdownScanning else { return }
        if !force, let t = lastDropdownScan, Date().timeIntervalSince(t) < 1.5, !dropdownEntries.isEmpty {
            await captureDropdownIcons()
            return
        }
        dropdownScanning = true
        defer { dropdownScanning = false }

        let apps = runningAppRefs()
        let own = MenuBarManagerScanner.ownStatusItems()
        let trusted = Permissions.isGranted(.accessibility)
        let raw = await Task.detached(priority: .userInitiated) { () -> [MenuBarManagerRawWindow] in
            var r: [MenuBarManagerRawWindow] = []
            if trusted { r = MenuBarManagerScanner.axStatusItems(apps: apps, own: own) }
            if r.isEmpty { r = MenuBarManagerScanner.statusWindows() } // older macOS: per-item windows
            return r
        }.value
        guard isRunning, runningMode == .dropdown else { return }
        inventoryNeedsAccessibility = raw.isEmpty && !trusted
        dropdownEntries = buildDropdownEntries(from: raw)
        lastDropdownScan = Date()
        await captureDropdownIcons()
    }

    func captureDropdownIcons() async {
        guard isRunning, Permissions.isGranted(.screenRecording) else { return }
        let hidden = dropdownHiddenIDs
        let wanted = dropdownEntries.filter { !hidden.contains($0.id) }
        let cap = MenuBarManagerCapture.shared
        cap.prune(keeping: Set(dropdownEntries.map(\.cacheKey)))
        if await cap.refresh(wanted) { captureVersion &+= 1 }
    }

    /// Raw AX / window records -> entries. Visibility is inferred (see MenuBarManagerVisibilityEngine).
    private func buildDropdownEntries(from raw: [MenuBarManagerRawWindow]) -> [MenuBarManagerEntry] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let toggleF = frame(of: toggleItem)
        let screen = toggleF.flatMap { MenuBarManagerGeometry.screen(containing: CGPoint(x: $0.midX, y: $0.midY)) } ?? screens[0]
        let strip = MenuBarManagerGeometry.stripRect(of: screen)
        let notch = MenuBarManagerGeometry.notchRect(of: screen)
        let otherStrips = screens.filter { $0 !== screen }.map { MenuBarManagerGeometry.stripRect(of: $0) }
        targetScreenFrameCG = MenuBarManagerGeometry.cgFrame(of: screen)
        toggleFrameCG = toggleF

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var kept: [MenuBarManagerRawWindow] = []
        for w in raw {
            let f = w.frame
            if w.pid == ownPid {
                if w.identifier.hasPrefix("MacMasterMenuBar") { continue }
                if let toggleF, abs(toggleF.minX - f.minX) < 4, abs(toggleF.width - f.width) < 4 { continue }
            }
            guard f.width > 0, f.width <= 400 else { continue }
            guard f.minY >= strip.minY - 3, f.maxY <= strip.maxY + 3 else { continue } // our bar's vertical band
            if otherStrips.contains(where: { $0.intersects(f) && !strip.intersects(f) }) { continue }
            kept.append(w)
        }

        // The toggle is certainly on screen: it joins the tiling as an anchor (and is dropped afterwards).
        var inputs = kept.map { MenuBarManagerVisibilityEngine.Input(frame: $0.frame, anchor: $0.isSystem) }
        if let toggleF { inputs.append(.init(frame: toggleF, anchor: true)) }
        let vis = MenuBarManagerVisibilityEngine.classify(inputs, strip: strip, notch: notch)

        var seen: [String: Int] = [:]
        var out: [MenuBarManagerEntry] = []
        for (i, w) in kept.enumerated() {
            let owner = w.bundleID.isEmpty ? (RunningAppCache.shared[w.pid]?.bundleID ?? "") : w.bundleID
            var id = w.stableKey
            if id.isEmpty { id = "\(owner.isEmpty ? w.ownerName : owner)|\(w.title)|0" }
            let n = seen[id, default: 0]
            seen[id] = n + 1
            if n > 0 { id += "#\(n)" }
            out.append(MenuBarManagerEntry(
                id: id, pid: w.pid, bundleID: owner, ownerName: w.ownerName, title: w.title,
                identifier: w.identifier, isSystem: w.isSystem, frame: w.frame,
                visibility: vis[i], icon: icon(for: w.pid)))
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        return out
    }

    // MARK: Counts

    var dropdownVisibleCount: Int { dropdownEntries.filter { $0.visibility.isShowing }.count }
    var dropdownNotShowingCount: Int { dropdownEntries.filter { !$0.visibility.isShowing }.count }

    // MARK: Favorites / hidden

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func isHiddenFromDropdown(_ id: String) -> Bool { dropdownHiddenIDs.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) }
        else { favorites.append(id); dropdownHiddenIDs.remove(id) } // pinning un-hides
        persistDropdownPrefs()
    }

    func moveFavorite(_ id: String, by delta: Int) {
        guard let i = favorites.firstIndex(of: id) else { return }
        let j = min(max(0, i + delta), favorites.count - 1)
        guard j != i else { return }
        favorites.swapAt(i, j)
        persistDropdownPrefs()
    }

    func setHiddenFromDropdown(_ id: String, _ hidden: Bool) {
        if hidden { dropdownHiddenIDs.insert(id); favorites.removeAll { $0 == id } } // hiding un-pins
        else { dropdownHiddenIDs.remove(id) }
        persistDropdownPrefs()
        if !hidden { Task { [weak self] in await self?.captureDropdownIcons() } }
    }

    func persistDropdownPrefs() {
        MenuBarManagerPrefs.favorites = favorites
        MenuBarManagerPrefs.dropdownHidden = Array(dropdownHiddenIDs)
    }

    // MARK: Press

    /// Opens an item's menu. AXPress by identity first (works for items macOS moved or hid), then a synthetic
    /// click when the item is on screen. Option-click and right-click are forwarded where possible.
    func activateDropdownEntry(_ e: MenuBarManagerEntry, kind: MenuBarManagerAutomation.PressKind = .primary) {
        guard isRunning else { return }
        let trusted = Permissions.isGranted(.accessibility)
        let onScreen = e.visibility == .visible && e.frame.width > 1
        let center = CGPoint(x: e.frame.midX, y: e.frame.midY)
        Task { [weak self] in
            var ok = false
            // Modifier clicks can't go through AXPress; send a real click when we can.
            if kind == .option, onScreen {
                self?.dropdown.hide()
                try? await Task.sleep(nanoseconds: 120_000_000)
                await MenuBarManagerAutomation.click(at: center, flags: .maskAlternate)
                return
            }
            // Our own items: click them through AppKit. Never AX into our own process (see `SelfAX`).
            if e.appRef.pid == SelfAX.pid {
                self?.dropdown.hide()
                try? await Task.sleep(nanoseconds: 120_000_000)
                if MenuBarManagerScanner.pressOwn(stableKey: e.id, secondary: kind == .secondary) { return }
                if onScreen { await MenuBarManagerAutomation.click(at: center, right: kind == .secondary) }
                return
            }
            if trusted {
                let app = e.appRef, key = e.id, frame = e.frame
                ok = await Task.detached(priority: .userInitiated) {
                    MenuBarManagerAutomation.press(app: app, key: key, frame: frame, kind: kind)
                }.value
            }
            if ok { self?.dropdown.hide(); return }
            if onScreen {
                self?.dropdown.hide()
                try? await Task.sleep(nanoseconds: 120_000_000)
                await MenuBarManagerAutomation.click(at: center, right: kind == .secondary)
                return
            }
            self?.showDropdownMessage(trusted
                ? "Couldn't open \(e.displayName). macOS has it hidden. Make room in the menu bar and try again."
                : "Grant Accessibility so \(e.displayName) can be opened from here.")
        }
    }

    func showDropdownMessage(_ text: String) {
        dropdownMessage = text
        dropdownMessageTask?.cancel()
        dropdownMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dropdownMessage = nil
        }
    }
}
