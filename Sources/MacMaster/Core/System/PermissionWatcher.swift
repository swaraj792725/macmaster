import AppKit
import Observation
import os

let permissionLog = Logger(subsystem: "com.macmaster.app", category: "permissions")

/// App-wide live view of every permission, plus whether macOS lets MacMaster's icons into the menu bar.
/// Checks in the background (every 5s while MacMaster is in front or the Permissions page is open, every 20s
/// otherwise) and right away on activation, wake and display changes. Logs and posts `.permissionsChanged`
/// whenever something flips.
@MainActor @Observable
final class PermissionWatcher {
    static let shared = PermissionWatcher()

    private(set) var status: [Permission: Bool] = [:]
    /// Accessibility is on for MacMaster, but Accessibility calls still fail (an entry left from an older build).
    private(set) var accessibilityBroken = false
    /// Screen Recording works, but parts of macOS keep the old "no" until MacMaster is reopened.
    private(set) var screenRecordingNeedsRelaunch = false
    /// False while macOS hides every MacMaster icon (System Settings › Menu Bar › Allow in the Menu Bar is off).
    /// Nil when it can't tell, for example when every MacMaster icon is turned off.
    private(set) var menuBarAllowed: Bool?

    static let menuBarSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    private static let suppressAlertKey = "mm.menuBarHiddenAlert.suppressed"

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var fastClients = 0
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var pendingMenuBar: Bool??
    @ObservationIgnored private var alertedThisRun = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let startedAt = ProcessInfo.processInfo.systemUptime

    private init() {
        for p in Permission.allCases { status[p] = Permissions.isGranted(p) }
    }

    func isGranted(_ p: Permission) -> Bool { status[p] ?? false }

    func start() {
        guard loop == nil else { return }
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (PermissionWatcher) -> Void) {
            observers.append((c, c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }))
        }
        on(nc, NSApplication.didBecomeActiveNotification) { $0.refreshSoon() }
        on(nc, NSApplication.didChangeScreenParametersNotification) { $0.refreshSoon(after: 2) }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.refreshSoon(after: 3) }
        on(ws, NSWorkspace.didWakeNotification) { $0.refreshSoon(after: 3) }
        on(nc, .locationAuthorizationChanged) { $0.refreshSoon() }
        on(nc, .calendarAuthorizationChanged) { $0.refreshSoon() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let fast = NSApp.isActive || self.fastClients > 0
                try? await Task.sleep(for: .seconds(fast ? 5 : 20))
            }
        }
    }

    /// While a permissions screen is open: check every 5s even with MacMaster in the background
    /// (the user is flipping switches in System Settings).
    func beginFastPolling() { fastClients += 1; refreshSoon() }
    func endFastPolling() { fastClients = max(0, fastClients - 1) }

    func refreshSoon(after seconds: Double = 0.3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.refresh()
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await Permissions.refreshNotificationStatus()
        let (granted, axWorks, relaunch) = await Task.detached(priority: .utility) {
            let g = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, Permissions.isGranted($0)) })
            let works = g[.accessibility] == true ? Permissions.accessibilityWorks() : nil
            return (g, works, Permissions.screenRecordingNeedsRelaunch)
        }.value

        let broken = granted[.accessibility] == true && axWorks == false
        var result = granted
        if broken { result[.accessibility] = false }
        for p in Permission.allCases where status[p] != result[p] {
            permissionLog.info("\(p.rawValue, privacy: .public): \(result[p] == true ? "granted" : "missing", privacy: .public)\(broken && p == .accessibility ? " (on in System Settings, not working)" : "", privacy: .public)")
        }
        var changed = false
        if result != status { status = result; changed = true }
        if broken != accessibilityBroken { accessibilityBroken = broken; changed = true }
        if relaunch != screenRecordingNeedsRelaunch { screenRecordingNeedsRelaunch = relaunch; changed = true }
        if updateMenuBar() { changed = true }
        if changed { NotificationCenter.default.post(name: .permissionsChanged, object: nil) }
    }

    // MARK: Menu bar

    /// Takes a reading and commits it once two in a row agree. True when `menuBarAllowed` changed.
    private func updateMenuBar() -> Bool {
        // Right after launch the icons are still being placed; asleep displays report nothing useful.
        guard !screensAsleep, ProcessInfo.processInfo.systemUptime - startedAt > 6 else { return false }
        let reading = Self.readMenuBarAllowed()
        guard pendingMenuBar == .some(reading) else {
            pendingMenuBar = .some(reading)
            if reading != menuBarAllowed { refreshSoon(after: 3) }   // confirm soon, not at the next slow poll
            return false
        }
        guard reading != menuBarAllowed else { return false }
        let was = menuBarAllowed
        menuBarAllowed = reading
        permissionLog.info("menu bar: \(reading.map { $0 ? "allowed" : "hidden by macOS" } ?? "unknown", privacy: .public) \(Self.statusWindowsDescription(), privacy: .public)")
        if reading == false, was != false { warnMenuBarHidden() }
        if reading == true { alertedThisRun = false }
        return true
    }

    /// macOS keeps a parked copy of every status item window below the screen. While the app is switched off
    /// under Allow in the Menu Bar, only those copies exist: none of MacMaster's icon windows sits at the top
    /// of a screen. (A full-screen app's hidden menu bar moves them up, not down, so they still count.)
    private static func readMenuBarAllowed() -> Bool? {
        if ProcessInfo.processInfo.environment["MM_TEST_MENUBAR_HIDDEN"] != nil { return false } // dev: try the warning
        let windows = statusWindows()
        guard !windows.isEmpty else { return nil }
        let screens = NSScreen.screens.map(\.frame)
        return windows.contains { f in
            screens.contains { s in
                f.maxX > s.minX - 20_000 && f.minX < s.maxX   // the tray pushes hidden icons far to the left
                    && f.midY >= s.maxY - 40 && f.midY <= s.maxY + 40
            }
        }
    }

    /// Frames of MacMaster's status item windows whose item is meant to show.
    private static func statusWindows() -> [CGRect] {
        let sel = NSSelectorFromString("statusItem")
        return NSApp.windows.compactMap { w in
            guard w.responds(to: sel), let item = w.value(forKey: "statusItem") as? NSStatusItem,
                  item.isVisible, w.frame.width > 0 else { return nil }
            return w.frame
        }
    }

    private static func statusWindowsDescription() -> String {
        let screens = NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        let wins = statusWindows().map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }
        return "screens=[\(screens.joined(separator: "; "))] items=[\(wins.joined(separator: "; "))]"
    }

    func openMenuBarSettings() { NSWorkspace.shared.open(Self.menuBarSettingsURL) }

    /// The icons are the main way into MacMaster, so say so once per run, unless the user asked not to.
    private func warnMenuBarHidden() {
        guard !alertedThisRun, !Services.isSnapshotRun,
              !UserDefaults.standard.bool(forKey: Self.suppressAlertKey) else { return }
        alertedThisRun = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "MacMaster's menu bar icons are hidden"
                alert.informativeText = "macOS has MacMaster switched off in System Settings › Menu Bar › Allow in the Menu Bar, so none of its icons show. Turn MacMaster on there to get them back."
                alert.addButton(withTitle: "Open Menu Bar Settings")
                alert.addButton(withTitle: "Not Now")
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don't warn me again"
                FrontAppTracker.markDeliberate()
                NSApp.activate(ignoringOtherApps: true)
                let answer = alert.runModal()
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(true, forKey: Self.suppressAlertKey)
                }
                if answer == .alertFirstButtonReturn { self.openMenuBarSettings() }
            }
        }
    }
}

extension Notification.Name {
    /// Posted on the main queue when a permission or the menu bar state changes.
    static let permissionsChanged = Notification.Name("MacMaster.permissionsChanged")
}
