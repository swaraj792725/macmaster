import Foundation
import CoreGraphics
import Observation

/// Keys for UserDefaults (also used by @AppStorage in the UI).
enum CleanerSettings {
    static let enabled = "mm.cleaner.auto.enabled"
    static let intervalDays = "mm.cleaner.auto.intervalDays"
    static let categories = "mm.cleaner.auto.categories"
    static let minAgeDays = "mm.cleaner.auto.minAgeDays"
    static let onlyOnAC = "mm.cleaner.auto.onlyOnAC"
    static let onlyWhenIdle = "mm.cleaner.auto.onlyWhenIdle"
    static let notify = "mm.cleaner.auto.notify"
    static let emptyTrash = "mm.cleaner.auto.emptyTrash"
    static let lastRun = "mm.cleaner.auto.lastRun"
    static let defaultCategories = "userCaches,logs,devDerivedData"

    static func parseCategories(_ raw: String) -> Set<CleanerCategoryID> {
        Set(raw.split(separator: ",").compactMap { CleanerCategoryID(rawValue: String($0)) }.filter(\.autoCleanEligible))
    }
    static func encode(_ set: Set<CleanerCategoryID>) -> String {
        CleanerCategoryID.allCases.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

/// Unattended cleaning. Only "safe" categories (plus Trash if explicitly opted in) are ever touched.
@Observable
@MainActor
final class CleanerScheduler {
    static let shared = CleanerScheduler()

    private(set) var isRunning = false
    private(set) var history: [CleanerHistoryEntry] = Store.load([CleanerHistoryEntry].self, from: "cleaner-history.json") ?? []
    private(set) var lastRunDate: Date? = {
        let t = UserDefaults.standard.double(forKey: CleanerSettings.lastRun)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    private(set) var lastStatus: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runIfDue() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await self.runIfDue()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Settings accessors

    var isEnabled: Bool { defaults.bool(forKey: CleanerSettings.enabled) }

    var intervalDays: Int {
        let v = defaults.integer(forKey: CleanerSettings.intervalDays)
        return [1, 3, 7].contains(v) ? v : 7
    }

    var minAgeDays: Int {
        defaults.object(forKey: CleanerSettings.minAgeDays) == nil ? 3 : max(0, defaults.integer(forKey: CleanerSettings.minAgeDays))
    }

    var selectedCategories: Set<CleanerCategoryID> {
        let raw = defaults.string(forKey: CleanerSettings.categories) ?? CleanerSettings.defaultCategories
        return CleanerSettings.parseCategories(raw)
    }

    private func flag(_ key: String, default d: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? d : defaults.bool(forKey: key)
    }

    /// When the next run becomes eligible (nil when disabled).
    var nextRunDate: Date? {
        guard isEnabled else { return nil }
        guard let last = lastRunDate else { return Date() }
        return last.addingTimeInterval(TimeInterval(intervalDays) * 86_400)
    }

    var totalFreedAllTime: Int64 { history.reduce(0) { $0 + $1.freed } }

    // MARK: Conditions

    private var onACPower: Bool {
        let r = BatteryReader.read()
        return !r.isPresent || r.isPluggedIn
    }

    /// Seconds since the last keyboard/mouse event.
    private var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func isDue() -> Bool {
        guard let next = nextRunDate else { return false }
        return Date() >= next
    }

    // MARK: Running

    func runIfDue() async {
        guard isEnabled, !isRunning, isDue() else { return }
        if flag(CleanerSettings.onlyOnAC, default: true), !onACPower { lastStatus = "Waiting for AC power"; return }
        if flag(CleanerSettings.onlyWhenIdle, default: true), idleSeconds < 120 { lastStatus = "Waiting until you are idle"; return }
        await runNow(manual: false)
    }

    /// Runs one clean with the saved settings. `manual` skips the due/power/idle checks.
    @discardableResult
    func runNow(manual: Bool = true) async -> CleanerOutcome? {
        guard !isRunning else { return nil }
        isRunning = true
        lastStatus = "Cleaning…"
        defer { isRunning = false }

        var cats = selectedCategories
        if flag(CleanerSettings.emptyTrash, default: false) { cats.insert(.trash) }
        guard !cats.isEmpty else { lastStatus = "No categories selected"; return nil }

        let ctx = CleanerScanContext(runningBundleIDs: CleanerEngine.runningBundleIDs())
        let items: [CleanerItem] = await withTaskGroup(of: [CleanerItem].self) { group in
            for c in cats { group.addTask { await CleanerScanner.scan(c, ctx: ctx) } }
            var all: [CleanerItem] = []
            for await part in group { all += part }
            return all
        }
        let runnable = items.filter { $0.isSelectable && !$0.needsAdmin }
        let minAge = TimeInterval(minAgeDays) * 86_400
        let outcome = await CleanerRemover.run(items: runnable, minAge: minAge > 0 ? minAge : nil, allowAdmin: false) { _, _ in }

        lastRunDate = Date()
        defaults.set(lastRunDate!.timeIntervalSince1970, forKey: CleanerSettings.lastRun)
        record(CleanerHistoryEntry(date: Date(), freed: outcome.freed, itemCount: outcome.removedCount,
                                   failureCount: outcome.failures.count, automatic: !manual,
                                   categories: cats.map(\.title).sorted()))
        lastStatus = "Freed \(Fmt.bytes(outcome.freed))"
        if flag(CleanerSettings.notify, default: true), !manual {
            Notifier.post(title: "MacMaster cleaned your Mac",
                          body: outcome.freed > 0 ? "Freed \(Fmt.bytes(outcome.freed)) of junk." : "Nothing needed cleaning this time.",
                          id: "mm.cleaner.auto")
        }
        return outcome
    }

    func record(_ entry: CleanerHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        Store.save(history, to: "cleaner-history.json")
    }

    func clearHistory() {
        history = []
        Store.save(history, to: "cleaner-history.json")
    }
}
