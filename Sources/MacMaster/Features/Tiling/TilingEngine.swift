import AppKit
import Observation

/// macOS's own edge tiling (Sequoia+), which double-snaps with ours unless turned off.
enum TilingNative {
    private static let domain = "com.apple.WindowManager" as CFString

    private static func value(_ key: String) -> Bool {
        if let b = CFPreferencesCopyAppValue(key as CFString, domain) as? Bool { return b }
        // Key absent: tiling is on by default from macOS 15.
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    static var edgeTilingEnabled: Bool { value("EnableTilingByEdgeDrag") }
    static var topTilingEnabled: Bool { value("EnableTopTilingByEdgeDrag") }
    static var anyEnabled: Bool { edgeTilingEnabled || topTilingEnabled }

    static func disable() async {
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"] {
            _ = await Shell.runAsync("/usr/bin/defaults", ["write", "com.apple.WindowManager", key, "-bool", "false"])
        }
        CFPreferencesAppSynchronize(domain)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Owns every tiling feature: lifecycle, permission watching and the public `apply` entry point.
@MainActor @Observable
final class TilingEngine {
    static let shared = TilingEngine()

    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var isRunning = false
    /// Last frontmost app that is not MacMaster (target for hero / quick-grid actions).
    private(set) var lastFrontmost: NSRunningApplication?
    private(set) var savedLayouts: [TilingSavedLayout] = []
    var status: String?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var reconfigureTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var modTap: TilingModifierDragTap?
    @ObservationIgnored private var hotkeysRegistered = false
    @ObservationIgnored private let axQueue = DispatchQueue(label: "MacMaster.Tiling.engine", qos: .userInitiated)

    private init() {
        TilingSettings.registerDefaults()
        savedLayouts = Store.load([TilingSavedLayout].self, from: "tiling-layouts.json") ?? []
        if let f = NSWorkspace.shared.frontmostApplication, Self.isTargetable(f) { lastFrontmost = f }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.noteActivated(app) }
        })
    }

    private func noteActivated(_ app: NSRunningApplication?) {
        guard let app, Self.isTargetable(app) else { return }
        lastFrontmost = app
    }

    /// Regular apps only: skips MacMaster, the Dock and agents such as UserNotificationCenter.
    private static func isTargetable(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != TilingAX.ownPID && app.activationPolicy == .regular
            && app.bundleIdentifier != "com.apple.dock"
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        TilingShortcutStore.shared.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.hotkeysRegistered = false
                self.reconfigure()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            // Never block the posting thread: a background defaults write would otherwise wait on main (deadlock).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleReconfigure() } }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconfigure() }
        })
        reconfigure()
    }

    func stop() {
        guard started else { return }
        started = false
        for o in observers.dropFirst() { NotificationCenter.default.removeObserver(o) }
        observers = Array(observers.prefix(1))
        reconfigureTask?.cancel()
        stopPoll()
        teardown()
    }

    private func scheduleReconfigure() {
        guard started else { return }
        reconfigureTask?.cancel()
        reconfigureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reconfigure()
        }
    }

    /// Idempotent: brings every feature in line with current settings and permission state.
    private func reconfigure() {
        guard started else { return }
        accessibilityGranted = AXIsProcessTrusted()
        guard TilingSettings.enabled else {
            stopPoll()
            teardown()
            return
        }
        isRunning = true

        // Hotkeys need no permission.
        let wantHotkeys = TilingSettings.hotkeysEnabled
        if wantHotkeys != hotkeysRegistered {
            if wantHotkeys { TilingHotkeys.shared.register() } else { TilingHotkeys.shared.unregister() }
            hotkeysRegistered = wantHotkeys
        }

        guard accessibilityGranted else {
            stopAXFeatures()
            startPoll()
            return
        }
        stopPoll()

        toggle(TilingSettings.snapEnabled, TilingSnapController.shared.isRunning,
               TilingSnapController.shared.start, TilingSnapController.shared.stop)
        toggle(TilingSettings.snapLayoutsEnabled, TilingSnapLayoutsController.shared.isRunning,
               TilingSnapLayoutsController.shared.start, TilingSnapLayoutsController.shared.stop)
        toggle(TilingSettings.focusFollows, TilingFocusFollower.shared.isRunning,
               TilingFocusFollower.shared.start, TilingFocusFollower.shared.stop)
        toggle(TilingSettings.titleDoubleClick, TilingTitleBarDoubleClick.shared.isRunning,
               TilingTitleBarDoubleClick.shared.start, TilingTitleBarDoubleClick.shared.stop)

        if TilingSettings.modDragEnabled {
            let flags = TilingSettings.modDragModifier.flags
            if let tap = modTap {
                tap.setModifier(flags)
            } else {
                let tap = TilingModifierDragTap(modifier: flags)
                if tap.start() { modTap = tap }
            }
        } else if let tap = modTap {
            tap.stop()
            modTap = nil
        }
    }

    private func toggle(_ want: Bool, _ running: Bool, _ start: () -> Void, _ stop: () -> Void) {
        if want && !running { start() } else if !want && running { stop() }
    }

    private func stopAXFeatures() {
        TilingSnapController.shared.stop()
        TilingSnapLayoutsController.shared.stop()
        TilingFocusFollower.shared.stop()
        TilingTitleBarDoubleClick.shared.stop()
        modTap?.stop()
        modTap = nil
    }

    private func teardown() {
        stopAXFeatures()
        TilingHotkeys.shared.unregister()
        hotkeysRegistered = false
        isRunning = false
    }

    private func startPoll() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() { self.reconfigure() } else { self.accessibilityGranted = false }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Applying layouts

    /// App whose focused window actions should target: the frontmost app, or the last one before MacMaster.
    func targetApplication() -> NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, Self.isTargetable(f) { return f }
        if let l = lastFrontmost, !l.isTerminated { return l }
        return nil
    }

    /// Applies a layout to the focused window of the frontmost (non-MacMaster) app.
    func apply(_ layout: TilingLayout) {
        guard AXIsProcessTrusted() else {
            accessibilityGranted = false
            Permissions.request(.accessibility)
            return
        }
        guard let app = targetApplication() else { return }
        let pid = app.processIdentifier
        let screens = TilingScreens.snapshot()
        let gap = TilingSettings.gap
        axQueue.async {
            guard let w = TilingAX.focusedWindow(pid: pid) else { return }
            TilingActions.perform(layout, window: w, screens: screens, gap: gap, cycle: true)
        }
    }

    // MARK: Tile all & presets

    func tileAll() {
        guard AXIsProcessTrusted() else { Permissions.request(.accessibility); return }
        let screens = TilingScreens.snapshot()
        guard let screen = TilingScreens.screen(containing: TilingScreens.mouseAX, in: screens) else { return }
        let apps = TilingWorkspace.regularApps(includeHidden: false)
        let gap = TilingSettings.gap
        axQueue.async { [weak self] in
            let n = TilingWorkspace.tileAll(apps: apps, screen: screen, gap: gap)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.flash(n == 0 ? "No windows to tile" : "Tiled \(n) window\(n == 1 ? "" : "s")") } }
        }
    }

    func saveCurrentLayout(name: String) {
        guard AXIsProcessTrusted() else { Permissions.request(.accessibility); return }
        let apps = TilingWorkspace.regularApps(includeHidden: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Layout \(savedLayouts.count + 1)" : trimmed
        axQueue.async { [weak self] in
            let wins = TilingWorkspace.capture(apps: apps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !wins.isEmpty else { self.flash("No windows found"); return }
                    self.savedLayouts.insert(TilingSavedLayout(name: title, date: Date(), windows: wins), at: 0)
                    Store.save(self.savedLayouts, to: "tiling-layouts.json")
                    self.flash("Saved \(Fmt.count(wins.count, "window"))")
                }
            }
        }
    }

    func restoreLayout(_ layout: TilingSavedLayout) {
        guard AXIsProcessTrusted() else { Permissions.request(.accessibility); return }
        let apps = TilingWorkspace.regularApps(includeHidden: true)
        let screens = TilingScreens.snapshot()
        axQueue.async { [weak self] in
            let n = TilingWorkspace.restore(layout, apps: apps, screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.flash(n == 0 ? "No matching windows are open" : "Restored \(n) window\(n == 1 ? "" : "s")") }
            }
        }
    }

    func deleteLayout(_ layout: TilingSavedLayout) {
        savedLayouts.removeAll { $0.id == layout.id }
        Store.save(savedLayouts, to: "tiling-layouts.json")
    }

    func renameLayout(_ layout: TilingSavedLayout, to name: String) {
        guard let i = savedLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        savedLayouts[i].name = name
        Store.save(savedLayouts, to: "tiling-layouts.json")
    }

    private func flash(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }
}
