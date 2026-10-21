import AppKit
import Foundation
import OSLog

/// App Updates: scans installed apps and finds newer versions (Sparkle, Mac App Store, Homebrew).
/// `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class AppUpdatesEngine {
    static let shared = AppUpdatesEngine()

    enum BrewJob: Equatable {
        case running
        case failed(String)
    }

    enum Keys {
        // Separate from `mm.updates.*`, which belongs to MacMaster's own updater.
        static let autoCheck = "mm.appupdates.autoCheck"
        static let notify = "mm.appupdates.notify"
        static let beta = "mm.appupdates.includeBeta"
        static let showUntracked = "mm.appupdates.showUntracked"
        static let ignored = "mm.appupdates.ignored"
        static let notified = "mm.appupdates.notifiedKeys"
    }

    // MARK: State

    private(set) var apps: [InstalledApp] = []
    /// Merged updates from every source (ignored ones included; see `visibleUpdates`).
    private(set) var updates: [AppUpdate] = []
    private(set) var failures: [CheckFailure] = []
    private(set) var outdatedFormulae: [String] = []
    private(set) var brewAvailable = HomebrewChecker.brewPath != nil
    private(set) var brewError: String?
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var offline = false
    private(set) var hasLoadedCache = false
    private(set) var brewJobs: [String: BrewJob] = [:]
    private(set) var isRefreshingBrew = false
    private(set) var brewRefreshError: String?
    private(set) var toast: String?
    private(set) var ignoreRules: [IgnoreRule] = []

    private var directUpdates: [AppUpdate] = []
    private var brewUpdates: [AppUpdate] = []
    private var loopTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.macmaster.app", category: "updates")

    private init() {
        loadIgnoreRules()
        loadCache()
    }

    // MARK: Derived

    /// Updates not hidden by an ignore rule.
    var visibleUpdates: [AppUpdate] { updates.filter { !isIgnored($0) } }
    var ignoredUpdates: [AppUpdate] { updates.filter { isIgnored($0) } }
    /// Badge count for the dashboard.
    var updateCount: Int { visibleUpdates.count }
    var untrackedApps: [InstalledApp] {
        apps.filter { $0.tracking == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var brewCaskUpdates: [AppUpdate] { visibleUpdates.filter { $0.source == .homebrew && $0.caskToken != nil } }

    func isIgnored(_ u: AppUpdate) -> Bool {
        ignoreRules.contains { $0.key == u.key && ($0.version == nil || $0.version == u.newVersion) }
    }

    // MARK: Settings

    static func flag(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    private var autoCheck: Bool { Self.flag(Keys.autoCheck, default: true) }
    private var notifyEnabled: Bool { Self.flag(Keys.notify, default: true) }
    private var includeBeta: Bool { Self.flag(Keys.beta, default: false) }

    // MARK: Lifecycle

    /// Background schedule: first check 60 s after launch when the last one is over a day old, then daily.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.tick()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// One pass of the schedule loop. Returns seconds to sleep.
    private func tick() async -> Double {
        let day: Double = 86_400
        if autoCheck {
            let age = lastChecked.map { Date().timeIntervalSince($0) } ?? .infinity
            if age >= day { await runCheck(background: true) }
        }
        let due = (lastChecked ?? .distantPast).addingTimeInterval(day).timeIntervalSinceNow
        // Re-evaluate at least hourly so toggling the setting or waking from sleep is picked up.
        return min(max(due, 3600), day)
    }

    /// Manual check ("Check Now", or the page opening with no cache).
    func check() {
        guard !isChecking else { return }
        Task { await runCheck(background: false) }
    }

    func runCheck(background: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        progress = (0, 0)
        defer { isChecking = false }
        let opts = CheckOptions(includeBeta: includeBeta, osVersion: Self.osVersionString)
        let outcome = await UpdateRunner.run(
            options: opts,
            onScan: { found in Task { @MainActor in AppUpdatesEngine.shared.apps = found } },
            progress: { d, t in Task { @MainActor in AppUpdatesEngine.shared.setProgress(d, t) } })

        offline = outcome.offline
        if outcome.offline {
            // Keep what we knew; just report that the network is down.
            log.info("Update check: offline")
            if apps.isEmpty { apps = outcome.apps }
            return
        }
        apps = outcome.apps
        directUpdates = outcome.direct
        brewUpdates = outcome.brew
        failures = outcome.failures
        outdatedFormulae = outcome.formulae
        brewAvailable = outcome.brewAvailable
        brewError = outcome.brewError
        lastChecked = Date()
        rebuild()
        saveCache()
        notifyNewUpdates(background: background)
        log.info("Update check done: \(self.updates.count) updates, \(self.failures.count) failures")
    }

    private func setProgress(_ d: Int, _ t: Int) {
        guard isChecking else { return }
        progress = (max(d, progress.done), t)
    }

    private func rebuild() {
        var byID: [String: AppUpdate] = [:]
        for u in directUpdates { byID[u.id] = u }
        for b in brewUpdates {
            if let d = byID[b.id] {
                // Homebrew can install it; keep Sparkle's release notes.
                var m = b
                m.notes = d.notes; m.notesURL = d.notesURL; m.downloadURL = d.downloadURL
                m.isCritical = d.isCritical; m.pubDate = d.pubDate
                byID[b.id] = m
            } else {
                byID[b.id] = b
            }
        }
        updates = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: Notifications

    private func notifyNewUpdates(background: Bool) {
        let visible = visibleUpdates
        let keys = Set(visible.map { "\($0.key)|\($0.newVersion)" })
        let previous = Set(UserDefaults.standard.stringArray(forKey: Keys.notified) ?? [])
        let fresh = visible.filter { !previous.contains("\($0.key)|\($0.newVersion)") }
        UserDefaults.standard.set(Array(keys), forKey: Keys.notified)
        guard background, notifyEnabled, !fresh.isEmpty else { return }
        let names = fresh.prefix(3).map(\.name).joined(separator: ", ")
        let more = fresh.count > 3 ? " and \(fresh.count - 3) more" : ""
        Notifier.post(title: fresh.count == 1 ? "1 app update available" : "\(fresh.count) app updates available",
                      body: names + more, id: "mm.appupdates.available")
    }

    // MARK: Ignore rules

    func ignoreVersion(_ u: AppUpdate) {
        addRule(IgnoreRule(key: u.key, version: u.newVersion, name: u.name))
    }

    func ignoreApp(_ u: AppUpdate) {
        ignoreRules.removeAll { $0.key == u.key }
        addRule(IgnoreRule(key: u.key, version: nil, name: u.name))
    }

    func removeRule(_ r: IgnoreRule) {
        ignoreRules.removeAll { $0 == r }
        saveIgnoreRules()
    }

    private func addRule(_ r: IgnoreRule) {
        if !ignoreRules.contains(r) { ignoreRules.append(r) }
        saveIgnoreRules()
    }

    private func loadIgnoreRules() {
        if let data = UserDefaults.standard.data(forKey: Keys.ignored),
           let rules = try? JSONDecoder().decode([IgnoreRule].self, from: data) { ignoreRules = rules }
    }

    private func saveIgnoreRules() {
        if let data = try? JSONEncoder().encode(ignoreRules) { UserDefaults.standard.set(data, forKey: Keys.ignored) }
    }

    // MARK: Actions

    func reveal(_ u: AppUpdate) {
        guard let p = u.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    /// App Store: open the product page in the App Store app.
    func openAppStore(_ u: AppUpdate) {
        guard let page = u.pageURL else {
            if let url = URL(string: "macappstore://apps.apple.com/search?term=\(u.name)") { NSWorkspace.shared.open(url) }
            return
        }
        var s = page
        if s.hasPrefix("https://") { s = "macappstore://" + s.dropFirst("https://".count) }
        if let url = URL(string: s) ?? URL(string: page) { NSWorkspace.shared.open(url) }
    }

    /// Sparkle: opening the app is enough for most apps to offer their update.
    func openApp(_ u: AppUpdate) {
        guard let p = u.path else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    func openURL(_ s: String?) {
        guard let s, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Homebrew

    func upgradeCask(_ u: AppUpdate) {
        guard let token = u.caskToken else { return }
        runUpgrade(tokens: [token], ids: [u.id])
    }

    func upgradeAllCasks() {
        let list = brewCaskUpdates.filter { brewJobs[$0.id] != .running }
        guard !list.isEmpty else { return }
        runUpgrade(tokens: list.compactMap(\.caskToken), ids: list.map(\.id))
    }

    private func runUpgrade(tokens: [String], ids: [String]) {
        guard let brew = HomebrewChecker.brewPath, !tokens.isEmpty else { return }
        for id in ids { brewJobs[id] = .running }
        Task {
            let r = await UpdateProcess.runAsync(brew, ["upgrade", "--cask", "--greedy"] + tokens,
                                                 env: HomebrewChecker.env, timeout: 900)
            if r.ok {
                for id in ids { brewJobs[id] = nil }
                toast = tokens.count == 1 ? "Updated \(tokens[0])" : "Updated \(tokens.count) apps with Homebrew"
                await recheckBrew()
                scheduleToastClear()
            } else {
                var text = r.combined
                if r.timedOut { text = "Timed out after 15 minutes.\n" + text }
                if text.isEmpty { text = "brew exited with status \(r.status)." }
                for id in ids { brewJobs[id] = .failed(text) }
            }
        }
    }

    func dismissJob(_ id: String) { brewJobs[id] = nil }

    private func scheduleToastClear() {
        Task {
            try? await Task.sleep(for: .seconds(6))
            toast = nil
        }
    }

    /// Re-read `brew outdated` without touching Sparkle / App Store results.
    func recheckBrew() async {
        guard HomebrewChecker.brewPath != nil else { return }
        let snapshot = apps
        let result = await HomebrewChecker.check(apps: snapshot)
        guard result.error == nil else { brewError = result.error; return }
        brewError = nil
        brewUpdates = result.updates
        outdatedFormulae = result.formulae
        apps = UpdateRunner.assignTracking(apps, brewTracked: result.tracked)
        rebuild()
        saveCache()
    }

    /// "Refresh Homebrew": `brew update`, then re-check. The only place MacMaster lets brew fetch new package data.
    func refreshHomebrew() {
        guard let brew = HomebrewChecker.brewPath, !isRefreshingBrew else { return }
        isRefreshingBrew = true
        brewRefreshError = nil
        Task {
            let r = await UpdateProcess.runAsync(brew, ["update"], env: HomebrewChecker.env.filter { $0.key != "HOMEBREW_NO_AUTO_UPDATE" },
                                                 timeout: 300)
            if !r.ok { brewRefreshError = r.timedOut ? "brew update timed out." : String(r.combined.suffix(500)) }
            await recheckBrew()
            isRefreshingBrew = false
        }
    }

    // MARK: Cache

    private var cacheURL: URL { AppPaths.supportFile("updates.json") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { hasLoadedCache = false; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(UpdatesCache.self, from: data) else { return }
        apps = c.apps
        directUpdates = c.direct
        brewUpdates = c.brew
        failures = c.failures
        outdatedFormulae = c.formulae
        brewError = c.brewError
        lastChecked = c.lastChecked
        hasLoadedCache = c.lastChecked != nil
        rebuild()
    }

    private func saveCache() {
        let cache = UpdatesCache(lastChecked: lastChecked, apps: apps, direct: directUpdates, brew: brewUpdates,
                                 failures: failures, formulae: outdatedFormulae, brewAvailable: brewAvailable, brewError: brewError)
        let url = cacheURL
        Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(cache) { try? data.write(to: url, options: .atomic) }
        }
    }
}

extension AppSearchIndex {
    /// App Updates settings, added to the global search.
    static let updatesEntries: [SearchEntry] = [
        SearchEntry(.updates, crumb: "Updates", "Check for app updates", "check now scan sparkle app store homebrew outdated versions", anchor: "updates.list"),
        SearchEntry(.updates, crumb: "Homebrew", "Update all Homebrew casks", "brew upgrade cask greedy refresh update", anchor: "updates.summary"),
        SearchEntry(.updates, crumb: "Settings", "Check for app updates daily", "automatic auto background schedule", anchor: "updates.auto"),
        SearchEntry(.updates, crumb: "Settings", "Notify about new app updates", "notification alert banner", anchor: "updates.notify"),
        SearchEntry(.updates, crumb: "Settings", "Include beta updates", "prerelease preview channel sparkle", anchor: "updates.beta"),
        SearchEntry(.updates, crumb: "Settings", "Show apps that can't be tracked", "untracked unsupported hidden", anchor: "updates.untracked"),
        SearchEntry(.updates, crumb: "Ignored", "Ignored updates", "skip version hide unignore", anchor: "updates.ignored"),
    ]
}
