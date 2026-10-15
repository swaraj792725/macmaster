import AppKit
import SwiftUI

/// Objective-C target for the status item buttons (MenuBarManager itself is a plain Swift class).
@MainActor
final class MenuBarManagerTarget: NSObject {
    weak var manager: MenuBarManager?
    @objc func toggleClicked(_ sender: Any?) { manager?.handleToggleClick() }
    @objc func menuToggle(_ sender: Any?) { manager?.toggle() }
    @objc func menuDropdown(_ sender: Any?) { manager?.showDropdown(includeAlwaysHidden: false) }
    @objc func menuOpenSettings(_ sender: Any?) { MenuBarManager.openSettingsHandler?() }
    @objc func menuOpenDropdown(_ sender: Any?) { manager?.toggleDropdown() }
    @objc func menuDisable(_ sender: Any?) { MenuBarManagerPrefs.defaults.set(false, forKey: MenuBarManagerPrefs.enabledKey) }
}

/// Menu bar manager with two modes (`MenuBarManagerMode`).
///
/// Dropdown (default): one status item of ours opens a floating list of every menu bar item. Nothing in the
/// bar is hidden, resized or moved. See MenuBarManagerDropdownMode.swift.
///
/// Classic: Bartender / Ice style, built from three of our own status items: a toggle, a "hidden" divider and
/// an optional "always hidden" divider. Collapsing sets a divider's length to 10 000 pt so every item to its
/// left is pushed off-screen. No permission is needed for that.
@MainActor
@Observable
final class MenuBarManager {
    static let shared = MenuBarManager()

    /// The lead can set this to jump to the manager page from the toggle's context menu.
    static var openSettingsHandler: (() -> Void)?

    // MARK: Published state
    var isCollapsed = false
    private(set) var items: [MenuBarManagerItem] = []
    private(set) var hiddenCount = 0
    /// Visible-section items that are clipped by the notch / pushed off the bar.
    private(set) var notchClippedCount = 0
    var isRunning = false
    /// Last action outcome ("Moved X to Hidden", failures...). Shown in the UI.
    var statusMessage: String?
    /// Why a collapse was refused (toggle would be pushed off-screen, divider on the wrong side...).
    var blockedReason: String?
    var busyItemID: Int?
    var isMoving = false
    /// No items could be listed because Accessibility isn't granted (macOS 26+ needs it for the inventory).
    var inventoryNeedsAccessibility = false
    /// Hot key registration problem (e.g. combination already taken), nil when fine.
    var hotKeyStatus: String?
    /// Bumped when new item images were captured so views refresh.
    var captureVersion = 0
    var state: MenuBarManagerState = .expanded
    /// Mode of the running instance. Switching modes in settings restarts the manager (`switchMode`).
    var runningMode: MenuBarManagerMode = MenuBarManagerPrefs.mode

    // MARK: Dropdown mode state
    /// Every menu bar item from the last scan, ordered by position. Rescanned lazily (on open, on settings page).
    var dropdownEntries: [MenuBarManagerEntry] = []
    var dropdownScanning = false
    /// Pinned items, in the order the user wants them (stable ids).
    var favorites: [String] = MenuBarManagerPrefs.favorites
    /// Items the user removed from the dropdown list (stable ids).
    var dropdownHiddenIDs: Set<String> = Set(MenuBarManagerPrefs.dropdownHidden)
    /// Last failure from pressing an item ("couldn't open X"); shown inside the dropdown.
    var dropdownMessage: String?
    /// True when this macOS lays out the bar itself and a long divider can't push icons out of view (macOS 27).
    var hidingUnsupported = MenuBarManager.loadUnsupported()

    // MARK: Internals shared with the actions extension
    @ObservationIgnored var toggleItem: NSStatusItem?
    @ObservationIgnored var dividerItem: NSStatusItem?
    @ObservationIgnored var alwaysHiddenItem: NSStatusItem?
    @ObservationIgnored let target = MenuBarManagerTarget()
    @ObservationIgnored let panel = MenuBarManagerPanelController()
    @ObservationIgnored let dropdown = MenuBarManagerDropdownController()
    @ObservationIgnored let barDrag = MenuBarManagerBarDragWatcher()
    @ObservationIgnored var dropdownObservers: [NSObjectProtocol] = []
    @ObservationIgnored var lastDropdownScan: Date?
    @ObservationIgnored var dropdownMessageTask: Task<Void, Never>?
    @ObservationIgnored var sectionCache: [Int: MenuBarManagerSection] = [:]
    @ObservationIgnored var iconCache: [pid_t: NSImage] = [:]
    @ObservationIgnored var rehideTask: Task<Void, Never>?
    @ObservationIgnored var hoverTask: Task<Void, Never>?
    @ObservationIgnored var refreshLoop: Task<Void, Never>?
    @ObservationIgnored var monitors: [Any] = []
    @ObservationIgnored var observers: [NSObjectProtocol] = []
    @ObservationIgnored var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored var visibilityCount = 0
    @ObservationIgnored var wantsRunning = false
    /// True while we expand the bar for our own purposes (item click, drag); suppresses auto-rehide rules.
    @ObservationIgnored var interacting = false
    @ObservationIgnored var hoverRevealed = false
    @ObservationIgnored var lastPrefSignature = ""
    @ObservationIgnored var registeredHotKey: MenuBarManagerHotKey?
    @ObservationIgnored var targetScreenFrameCG: CGRect = .zero
    @ObservationIgnored var toggleFrameCG: CGRect?
    @ObservationIgnored var dividerFrameCG: CGRect?
    @ObservationIgnored var alwaysHiddenFrameCG: CGRect?

    static let toggleName = "MacMasterMenuBarToggle"
    static let dividerName = "MacMasterMenuBarDivider"
    static let alwaysHiddenName = "MacMasterMenuBarAlwaysHiddenDivider"
    static let collapsedLength: CGFloat = 10_000
    static let dividerLength: CGFloat = 10

    private init() { target.manager = self }

    var alwaysHiddenEnabled: Bool { MenuBarManagerPrefs.alwaysHiddenEnabled }
    var hasControlItems: Bool { toggleItem != nil && dividerItem != nil }

    // MARK: - Lifecycle

    func start() {
        wantsRunning = true
        guard MenuBarManagerPrefs.enabled, !isRunning else { return }
        MenuBarManagerPrefs.migrateIfNeeded()
        runningMode = MenuBarManagerPrefs.mode
        if runningMode == .dropdown { startDropdown(); return }
        isRunning = true
        statusMessage = nil

        let screen = NSScreen.screens.first
        let strip = screen.map { MenuBarManagerGeometry.stripRect(of: $0) }
        let apps = runningAppRefs()
        let own = MenuBarManagerScanner.ownStatusItems()
        let trusted = Permissions.isGranted(.accessibility)
        let restoreCollapsed = MenuBarManagerPrefs.bool(MenuBarManagerPrefs.collapsedKey, default: false)

        Task { [weak self] in
            // Work out where existing items end (off-main) so the control items land just left of them.
            let base: Double? = await Task.detached(priority: .utility) { () -> Double? in
                guard let strip else { return nil }
                var raw: [MenuBarManagerRawWindow] = []
                if trusted { raw = MenuBarManagerScanner.axStatusItems(apps: apps, own: own) }
                if raw.isEmpty { raw = MenuBarManagerScanner.statusWindows() }
                let xs = raw
                    .filter { $0.frame.minX >= strip.minX && $0.frame.maxX <= strip.maxX && abs($0.frame.minY - strip.minY) < 8 }
                    .map(\.frame.minX)
                return xs.min().map { Double(strip.maxX - $0) + 12 }
            }.value
            guard let self, self.isRunning, self.toggleItem == nil else { return }
            self.seedPreferredPositions(base: base)
            self.buildControlItems()
            self.applyPrefsIfChanged(force: true)
            self.observeSystem()
            // Show everything first, then restore the last collapsed state once the bar has laid out.
            self.apply(.expanded, persist: false)
            self.startRefreshLoopIfNeeded()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.isRunning else { return }
            await self.refreshNow()
            if restoreCollapsed && !self.hidingUnsupported { self.collapse() }
        }
    }

    /// Stops the manager and leaves all icons visible.
    func stop() {
        wantsRunning = false
        teardown()
    }

    func teardown() {
        guard isRunning else { return }
        panel.hide()
        dropdown.hide()
        barDrag.remove()
        dropdownMessageTask?.cancel(); dropdownMessageTask = nil
        for o in dropdownObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        dropdownObservers.removeAll()
        rehideTask?.cancel(); hoverTask?.cancel(); refreshLoop?.cancel()
        rehideTask = nil; hoverTask = nil; refreshLoop = nil
        // Expand before removal so icons can never stay pushed off-screen.
        dividerItem?.length = Self.dividerLength
        alwaysHiddenItem?.length = Self.dividerLength
        removeMonitors()
        MenuBarManagerHotKeyCenter.shared.register(nil)
        registeredHotKey = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let w = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(w) }
        workspaceObserver = nil
        for it in [toggleItem, dividerItem, alwaysHiddenItem].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(it)
        }
        toggleItem = nil; dividerItem = nil; alwaysHiddenItem = nil
        // A teardown mid-click or mid-drag must not leave these stuck on (auto-rehide would never run again).
        interacting = false
        isMoving = false
        iconCache.removeAll()
        isRunning = false
        isCollapsed = false
        state = .expanded
        items = []; hiddenCount = 0; notchClippedCount = 0
        dropdownEntries = []; lastDropdownScan = nil
        lastPrefSignature = ""
    }

    /// Called on app quit: leave the bar fully expanded.
    func restoreForQuit() {
        guard isRunning else { return }
        dropdown.hide()
        dividerItem?.length = Self.dividerLength
        alwaysHiddenItem?.length = Self.dividerLength
    }

    // MARK: - Collapse / expand

    func toggle() {
        if runningMode == .dropdown { toggleDropdown(); return }
        if state == .collapsed { expand() } else { collapse() }
    }

    func expand(includeAlwaysHidden: Bool = false) {
        guard isRunning, runningMode == .classic else { return }
        blockedReason = nil
        panel.hide()
        let target: MenuBarManagerState = (includeAlwaysHidden && alwaysHiddenEnabled) ? .expandedAll : .expanded
        // Never downgrade an "all" expansion to a plain one by accident.
        apply(state == .expandedAll && target == .expanded ? .expandedAll : target)
        armRehide()
        scheduleRefresh(after: 0.35)
    }

    func collapse() {
        guard isRunning, hasControlItems else { return }
        rehideTask?.cancel()
        hoverRevealed = false
        if hidingUnsupported {
            blockedReason = Self.unsupportedMessage
            apply(.expanded)
            return
        }
        if let reason = collapseUnsafeReason() {
            blockedReason = reason
            apply(.expanded, persist: false)
            return
        }
        blockedReason = nil
        apply(.collapsed)
        // After layout settles, verify the toggle is still on the bar. If not, back out.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.isRunning, self.state == .collapsed else { return }
            if self.pushLayoutIgnored() {
                self.markHidingUnsupported()
                self.blockedReason = Self.unsupportedMessage
                self.apply(.expanded)
                return
            }
            if let reason = self.toggleOffscreenReason() {
                self.blockedReason = reason
                self.apply(.expanded, persist: false)
            }
            await self.refreshNow()
        }
    }

    static let unsupportedMessage = "This version of macOS arranges the menu bar itself, so MacMaster can't push icons out of view. Choose which icons appear in System Settings › Menu Bar."

    /// Classic bars grow a long divider leftwards, off the screen edge. MenuBarAgent (macOS 27) keeps its left
    /// edge and lets it run right, under the toggle, so nothing gets hidden.
    func pushLayoutIgnored() -> Bool {
        guard let div = frame(of: dividerItem), let t = frame(of: toggleItem) else { return false }
        return div.maxX > t.minX + 4
    }

    private static let unsupportedKey = "mm.menubarmgr.hidingUnsupportedOS"
    private static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private static func loadUnsupported() -> Bool {
        MenuBarManagerPrefs.defaults.string(forKey: unsupportedKey) == osBuild
    }

    func markHidingUnsupported() {
        hidingUnsupported = true
        MenuBarManagerPrefs.defaults.set(Self.osBuild, forKey: Self.unsupportedKey)
    }

    /// Lets the user re-test after an OS update or a fix.
    func clearHidingUnsupported() {
        hidingUnsupported = false
        MenuBarManagerPrefs.defaults.removeObject(forKey: Self.unsupportedKey)
    }

    func openSystemMenuBarSettings() {
        let ids = ["com.apple.MenuBar-Settings.extension", "com.apple.ControlCenter-Settings.extension"]
        for id in ids {
            if let u = URL(string: "x-apple.systempreferences:\(id)"), NSWorkspace.shared.open(u) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Re-applies current state (after prefs or screen changes).
    func reapply() { apply(state, persist: false) }

    func apply(_ s: MenuBarManagerState, persist: Bool = true) {
        if runningMode == .dropdown {
            // Dropdown mode never collapses anything.
            state = .expanded; isCollapsed = false
            updateToggleGlyph()
            return
        }
        state = s
        isCollapsed = (s == .collapsed)
        if persist { MenuBarManagerPrefs.defaults.set(s == .collapsed, forKey: MenuBarManagerPrefs.collapsedKey) }
        let showDivider = MenuBarManagerPrefs.showDivider && !hidingUnsupported
        if let d = dividerItem {
            if s == .collapsed {
                d.length = Self.collapsedLength
                d.button?.image = nil
            } else {
                d.length = Self.dividerLength
                d.button?.image = showDivider ? Self.dividerImage(dashed: false) : nil
            }
        }
        if let a = alwaysHiddenItem {
            if hidingUnsupported {
                // A 10k item gets parked off the bar on MenuBarAgent; keep it tiny and empty instead.
                a.length = 0
                a.button?.image = nil
            } else if s == .expandedAll {
                a.length = Self.dividerLength
                a.button?.image = Self.dividerImage(dashed: true)
            } else {
                a.length = Self.collapsedLength
                a.button?.image = nil
            }
        }
        updateToggleGlyph()
    }

    /// Reasons a collapse would strand the user (toggle pushed off-screen / divider on the wrong side).
    func collapseUnsafeReason() -> String? {
        guard let toggle = frame(of: toggleItem), let div = frame(of: dividerItem) else {
            return "Menu bar controls aren't on screen yet."
        }
        if div.minX >= toggle.minX - 1 {
            return "The | divider is to the right of the arrow. ⌘-drag it to the left of the arrow, then try again."
        }
        if let r = toggleOffscreenReason() { return r }
        return nil
    }

    func toggleOffscreenReason() -> String? {
        guard let toggle = frame(of: toggleItem) else { return "Toggle isn't on screen." }
        guard let screen = MenuBarManagerGeometry.screen(containing: CGPoint(x: toggle.midX, y: toggle.midY)) else { return nil }
        let strip = MenuBarManagerGeometry.stripRect(of: screen)
        if toggle.maxX <= strip.minX + 1 || toggle.minX >= strip.maxX - 1 || !strip.intersects(toggle) {
            return "The toggle is off the menu bar. Free up space by removing some icons."
        }
        if let notch = MenuBarManagerGeometry.notchRect(of: screen), notch.intersects(toggle) {
            return "The toggle is behind the notch. Free up space by removing some icons."
        }
        return nil
    }

    /// Frame of one of our own status items in CG coordinates.
    func frame(of item: NSStatusItem?) -> CGRect? {
        guard let w = item?.button?.window else { return nil }
        let f = w.frame
        guard f.width > 0, f.height > 0 else { return nil }
        return MenuBarManagerGeometry.cgRect(fromAppKit: f)
    }

    // MARK: - Control items

    private func seedPreferredPositions(base baseOverride: Double? = nil) {
        let d = UserDefaults.standard
        func key(_ n: String) -> String { "NSStatusItem Preferred Position \(n)" }
        var names = [Self.toggleName, Self.dividerName]
        if alwaysHiddenEnabled { names.append(Self.alwaysHiddenName) }
        guard names.contains(where: { d.object(forKey: key($0)) == nil }) else { return }

        // Place all three just left of the existing items (offset from the right edge to the leftmost one).
        let base: Double = baseOverride ?? 300
        var running = base - 30
        for n in names {
            if let v = d.object(forKey: key(n)) as? Double { running = max(running, v) }
        }
        for n in names where d.object(forKey: key(n)) == nil {
            running += 30
            d.set(running, forKey: key(n))
        }
    }

    private func makeItem(name: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        item.behavior = []
        item.button?.setAccessibilityIdentifier(name)
        return item
    }

    func buildControlItems() {
        if toggleItem == nil {
            let t = makeItem(name: Self.toggleName, length: NSStatusItem.variableLength)
            if let b = t.button {
                b.target = target
                b.action = #selector(MenuBarManagerTarget.toggleClicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.toolTip = runningMode == .dropdown
                    ? "Click to list every menu bar item."
                    : "Click to show or hide menu bar icons. Option-click reveals always-hidden icons."
            }
            toggleItem = t
        }
        guard runningMode == .classic else {
            panel.ignoredWindow = toggleItem?.button?.window
            dropdown.ignoredWindow = toggleItem?.button?.window
            updateToggleGlyph()
            return
        }
        if dividerItem == nil {
            let d = makeItem(name: Self.dividerName, length: Self.dividerLength)
            d.button?.toolTip = "Hidden section divider. Command-drag icons to its left to hide them."
            dividerItem = d
        }
        syncAlwaysHiddenItem()
        panel.ignoredWindow = toggleItem?.button?.window
    }

    /// Create / remove the always-hidden divider according to the pref.
    func syncAlwaysHiddenItem() {
        guard runningMode == .classic else { return }
        if alwaysHiddenEnabled, alwaysHiddenItem == nil, isRunning {
            seedPreferredPositions()
            let a = makeItem(name: Self.alwaysHiddenName, length: Self.collapsedLength)
            a.button?.toolTip = "Always-hidden divider. Icons to its left only appear in the dropdown bar or with Option-click."
            alwaysHiddenItem = a
        } else if !alwaysHiddenEnabled, let a = alwaysHiddenItem {
            a.length = Self.dividerLength
            NSStatusBar.system.removeStatusItem(a)
            alwaysHiddenItem = nil
            if state == .expandedAll { state = .expanded }
        }
    }

    func updateToggleGlyph() {
        guard let b = toggleItem?.button else { return }
        let glyph = MenuBarManagerPrefs.glyph
        let collapsed = state == .collapsed
        let dropdownMode = runningMode == .dropdown
        let image: NSImage?
        switch glyph {
        case .chevron:
            image = Self.symbol(dropdownMode ? "chevron.down" : (collapsed ? "chevron.left" : "chevron.right"),
                                point: 12, weight: .semibold)
        case .ellipsis:
            image = Self.symbol("ellipsis", point: 13, weight: .bold)
        case .dot:
            image = Self.symbol(collapsed ? "circle.fill" : "circle", point: 9, weight: .regular)
        case .line:
            image = Self.symbol("minus", point: 13, weight: .bold)
        case .logo:
            image = MenuBarIconRenderer.logoImage(size: 16)
        }
        image?.isTemplate = true
        let label = dropdownMode ? "Show menu bar items" : (collapsed ? "Show hidden menu bar icons" : "Hide menu bar icons")
        image?.accessibilityDescription = label
        b.image = image
        b.imagePosition = .imageOnly
        b.alphaValue = (glyph == .line || glyph == .logo) && !collapsed && !dropdownMode ? 0.55 : 1
        b.setAccessibilityLabel(label)
    }

    private static func symbol(_ name: String, point: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
        return NSImage(systemSymbolName: SymbolKit.resolve(name, fallback: "circle"), accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    static func dividerImage(dashed: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            if dashed {
                for y in stride(from: CGFloat(2), through: 11, by: 4.5) {
                    NSBezierPath(roundedRect: NSRect(x: 3.25, y: y, width: 1.5, height: 2.5), xRadius: 0.75, yRadius: 0.75).fill()
                }
            } else {
                NSBezierPath(roundedRect: NSRect(x: 3.25, y: 2, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Click handling

    func handleToggleClick() {
        let event = NSApp.currentEvent
        let option = event?.modifierFlags.contains(.option) ?? false
        let isRight = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isRight { showContextMenu(); return }
        toggleFromUser(optionDown: option)
    }

    /// Click / hot key behaviour: dropdown bar if collapsed and enabled, otherwise expand or collapse.
    func toggleFromUser(optionDown: Bool) {
        guard isRunning else { return }
        if runningMode == .dropdown {
            toggleDropdown(includeAlwaysHidden: optionDown && MenuBarManagerPrefs.optionClickAlwaysHidden && alwaysHiddenEnabled)
            return
        }
        if panel.isVisible { panel.hide(); return }
        if hidingUnsupported { showNotice(); return }
        let wantAll = optionDown && MenuBarManagerPrefs.optionClickAlwaysHidden
        if state == .collapsed {
            if MenuBarManagerPrefs.dropdownBar { showDropdown(includeAlwaysHidden: wantAll) }
            else { expand(includeAlwaysHidden: wantAll) }
        } else if wantAll && alwaysHiddenEnabled && state != .expandedAll {
            expand(includeAlwaysHidden: true)
        } else {
            collapse()
        }
    }

    private func showContextMenu() {
        guard let button = toggleItem?.button else { return }
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = target
            menu.addItem(mi)
        }
        if runningMode == .dropdown {
            add(dropdown.isVisible ? "Close Menu Bar Items" : "Show Menu Bar Items", #selector(MenuBarManagerTarget.menuOpenDropdown(_:)))
        } else {
            add(state == .collapsed ? "Show Hidden Icons" : "Hide Icons", #selector(MenuBarManagerTarget.menuToggle(_:)))
            if MenuBarManagerPrefs.dropdownBar { add("Show Dropdown Bar", #selector(MenuBarManagerTarget.menuDropdown(_:))) }
        }
        if MenuBarManager.openSettingsHandler != nil {
            menu.addItem(.separator())
            add("Menu Bar Manager Settings…", #selector(MenuBarManagerTarget.menuOpenSettings(_:)))
        }
        menu.addItem(.separator())
        add("Turn Off Menu Bar Manager", #selector(MenuBarManagerTarget.menuDisable(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - Visibility-driven refresh

    /// Call from `onAppear`: item scanning runs every 2 s while someone is looking.
    func beginObserving() {
        visibilityCount += 1
        startRefreshLoopIfNeeded()
        Task { await refreshNow() } // dropdown mode: one lazy scan, no loop
    }

    func endObserving() {
        visibilityCount = max(0, visibilityCount - 1)
    }

    func startRefreshLoopIfNeeded() {
        guard refreshLoop == nil, isRunning, runningMode == .classic else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.visibilityCount == 0 && !self.panel.isVisible && !self.interacting {
                    // Nobody is looking: stop the loop until the next beginObserving().
                    self.refreshLoop = nil
                    return
                }
                await self.refreshNow()
            }
        }
    }

    func scheduleRefresh(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.refreshNow()
        }
    }

    // MARK: - Inventory

    func refreshNow() async {
        guard isRunning else { return }
        if runningMode == .dropdown { await refreshDropdownInventory(); return }
        let apps = runningAppRefs()
        let own = MenuBarManagerScanner.ownStatusItems()
        let trusted = Permissions.isGranted(.accessibility)
        let raw = await Task.detached(priority: .utility) { () -> [MenuBarManagerRawWindow] in
            var r: [MenuBarManagerRawWindow] = []
            if trusted { r = MenuBarManagerScanner.axStatusItems(apps: apps, own: own) }
            if r.isEmpty { r = MenuBarManagerScanner.statusWindows() } // older macOS: per-item windows
            return r
        }.value
        guard isRunning else { return }
        inventoryNeedsAccessibility = raw.isEmpty && !trusted
        rebuildItems(from: raw)
        if Permissions.isGranted(.screenRecording) {
            let snapshot = items
            let cap = MenuBarManagerCapture.shared
            cap.prune(keeping: Set(snapshot.map(\.cacheKey)))
            if await cap.refresh(snapshot) { captureVersion &+= 1 }
        }
    }

    func runningAppRefs() -> [MenuBarManagerAppRef] {
        RunningAppCache.shared.apps.map {
            MenuBarManagerAppRef(pid: $0.pid, name: $0.name, bundleID: $0.bundleID ?? "")
        }
    }

    /// App icon for a pid. Reads the cached running-app snapshot (no per-property XPC); nil for agents with no bundle.
    func icon(for pid: pid_t) -> NSImage? {
        if let i = iconCache[pid] { return i }
        guard let path = RunningAppCache.shared[pid]?.bundlePath else { return nil }
        // Pids of quit apps pile up (and get reused); drop entries no longer running.
        if iconCache.count > 64 { iconCache = iconCache.filter { RunningAppCache.shared[$0.key] != nil } }
        let i = NSWorkspace.shared.icon(forFile: path)
        iconCache[pid] = i
        return i
    }

    private func rebuildItems(from raw: [MenuBarManagerRawWindow]) {
        // Our control items, by window number.
        let ownIDs: Set<Int> = Set([toggleItem, dividerItem, alwaysHiddenItem].compactMap { $0?.button?.window?.windowNumber })
        let toggleF = frame(of: toggleItem)
        let divF = raw.first(where: { $0.id == dividerItem?.button?.window?.windowNumber })?.frame ?? frame(of: dividerItem)
        let ahF = raw.first(where: { $0.id == alwaysHiddenItem?.button?.window?.windowNumber })?.frame ?? frame(of: alwaysHiddenItem)

        // Target screen: the one holding the toggle, else the primary display.
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = toggleF.flatMap { MenuBarManagerGeometry.screen(containing: CGPoint(x: $0.midX, y: $0.midY)) } ?? screens[0]
        let screenCG = MenuBarManagerGeometry.cgFrame(of: screen)
        let strip = MenuBarManagerGeometry.stripRect(of: screen)
        targetScreenFrameCG = screenCG
        toggleFrameCG = toggleF; dividerFrameCG = divF; alwaysHiddenFrameCG = ahF
        let notch = MenuBarManagerGeometry.notchRect(of: screen)
        let otherStrips = screens.filter { $0 !== screen }.map { MenuBarManagerGeometry.stripRect(of: $0) }

        var out: [MenuBarManagerItem] = []
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let controlFrames = [toggleF, divF, ahF].compactMap { $0 }
        for w in raw where !ownIDs.contains(w.id) {
            let f = w.frame
            if w.pid == ownPid {
                if w.identifier.hasPrefix("MacMasterMenuBar") { continue }
                if controlFrames.contains(where: { abs($0.minX - f.minX) < 4 && abs($0.width - f.width) < 4 }) { continue }
            }
            guard f.width <= 400 else { continue }
            // Must sit in the menu bar's vertical band.
            guard f.minY >= strip.minY - 3, f.maxY <= strip.maxY + 3 else { continue }
            // Belongs to another display's bar?
            if otherStrips.contains(where: { $0.intersects(f) && !strip.intersects(f) }) { continue }
            let offscreen = !screenCG.intersects(f) || f.maxX <= strip.minX || f.minX >= strip.maxX
            let section = classify(w, divider: divF, alwaysHidden: ahF, toggle: toggleF)
            let behindNotch = notch.map { $0.intersects(f) } ?? false
            let clipped = section == .visible && (offscreen || behindNotch)
            out.append(MenuBarManagerItem(
                id: w.id, pid: w.pid, ownerName: w.ownerName, title: w.title, frame: f,
                section: section, isOffscreen: offscreen, isClipped: clipped, icon: icon(for: w.pid), key: w.key))
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        if state != .collapsed { for it in out { sectionCache[it.id] = it.section } }
        let live = Set(out.map(\.id))
        sectionCache = sectionCache.filter { live.contains($0.key) }

        items = out
        hiddenCount = out.filter { $0.section != .visible }.count
        notchClippedCount = out.filter(\.isClipped).count
    }

    /// Section by x relative to the dividers' windows; falls back to the last known section while collapsed.
    private func classify(_ w: MenuBarManagerRawWindow, divider hd: CGRect?, alwaysHidden ahd: CGRect?,
                          toggle: CGRect?) -> MenuBarManagerSection {
        if state == .collapsed, let c = sectionCache[w.id] { return c }
        guard let hd, hd.width > 0 else { return sectionCache[w.id] ?? .visible }
        if let toggle, hd.maxX > toggle.minX + 4 { return sectionCache[w.id] ?? .visible } // divider on wrong side
        let mid = w.frame.midX
        if mid >= hd.maxX - 1 { return .visible }
        if alwaysHiddenEnabled {
            if let ahd, ahd.width > 0, ahd.maxX <= hd.minX + 2 {
                return mid <= ahd.maxX + 1 ? .alwaysHidden : .hidden
            }
            return sectionCache[w.id] ?? .hidden
        }
        return .hidden
    }

    // MARK: - Convenience for views

    func items(in section: MenuBarManagerSection) -> [MenuBarManagerItem] { items.filter { $0.section == section } }
    var visibleCount: Int { items.filter { $0.section == .visible }.count }
}
