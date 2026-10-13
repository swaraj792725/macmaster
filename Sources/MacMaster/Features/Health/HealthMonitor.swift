import SwiftUI
import AppKit
import Observation

private let healthDefaults = UserDefaults.standard

private struct HealthPersisted: Codable {
    var snoozed: [String: Date] = [:]
    var ignoredApps: [String] = []
    var lastNotified: [String: Date] = [:]
    var openKeys: [String: Date]? = nil   // issues already logged as detected and not yet resolved
}

private struct HealthCheckupSnapshot: Codable {
    var date: Date
    var items: [HealthCheckItem]
}

private struct HealthHungState {
    var name: String
    var everResponded = false
    var firstFail: Date?
    var fails = 0
}

/// Background watchdog. Samples every ~10 s from `SystemMonitor`/`BatteryMonitor`, keeps rolling
/// windows, evaluates small rule types and tracks the resulting issues.
@Observable
@MainActor
final class HealthMonitor {
    static let shared = HealthMonitor()

    // MARK: Outputs (Dashboard-friendly)
    private(set) var score = 100
    private(set) var issues: [HealthIssue] = []
    private(set) var summary = "Health monitoring is starting…"

    private(set) var scoreHistory: [HealthScorePoint] = []
    private(set) var history: [HealthSample] = []
    private(set) var events: [HealthEvent] = []
    private(set) var startedAt: Date?
    private(set) var isRunning = false
    private(set) var checkup: [HealthCheckItem] = []
    private(set) var checkupDate: Date?
    private(set) var isCheckingUp = false
    private(set) var sleepBlockers: [HealthSleepBlocker] = []
    private(set) var hungProbeActive = false
    private(set) var lastActionMessage: String?
    var presentedTopList: HealthTopKind?

    // MARK: Settings (UserDefaults, prefix mm.health.)
    var monitoringEnabled: Bool = healthDefaults.object(forKey: "mm.health.enabled") as? Bool ?? true {
        didSet {
            healthDefaults.set(monitoringEnabled, forKey: "mm.health.enabled")
            if monitoringEnabled { start() } else { stop() }
        }
    }
    var sensitivity: HealthSensitivity = HealthSensitivity(rawValue: healthDefaults.string(forKey: "mm.health.sensitivity") ?? "") ?? .balanced {
        didSet {
            healthDefaults.set(sensitivity.rawValue, forKey: "mm.health.sensitivity")
            thresholds = HealthThresholds.make(sensitivity)
            if isRunning { tick() }
        }
    }
    var notificationsEnabled: Bool = healthDefaults.object(forKey: "mm.health.notify") as? Bool ?? true {
        didSet { healthDefaults.set(notificationsEnabled, forKey: "mm.health.notify") }
    }
    var quietHoursEnabled: Bool = healthDefaults.bool(forKey: "mm.health.quietEnabled") {
        didSet { healthDefaults.set(quietHoursEnabled, forKey: "mm.health.quietEnabled") }
    }
    var quietStartMinutes: Int = healthDefaults.object(forKey: "mm.health.quietStart") as? Int ?? 22 * 60 {
        didSet { healthDefaults.set(quietStartMinutes, forKey: "mm.health.quietStart") }
    }
    var quietEndMinutes: Int = healthDefaults.object(forKey: "mm.health.quietEnd") as? Int ?? 7 * 60 {
        didSet { healthDefaults.set(quietEndMinutes, forKey: "mm.health.quietEnd") }
    }
    private(set) var disabledRules: Set<String> = Set(healthDefaults.stringArray(forKey: "mm.health.disabledRules") ?? []) {
        didSet { healthDefaults.set(Array(disabledRules), forKey: "mm.health.disabledRules") }
    }
    private(set) var snoozedUntil: [String: Date] = [:] { didSet { persistState() } }
    private(set) var ignoredApps: [String] = [] { didSet { persistState() } }

    // MARK: Internals
    @ObservationIgnored private var thresholds = HealthThresholds.make(HealthSensitivity(rawValue: healthDefaults.string(forKey: "mm.health.sensitivity") ?? "") ?? .balanced)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var holdingProcesses = false
    @ObservationIgnored private var tracks: [Int32: HealthProcTrack] = [:]
    @ObservationIgnored private var sysTracks: [HealthSystemGroup: HealthSysTrack] = [:]
    @ObservationIgnored private var hungStates: [Int32: HealthHungState] = [:]
    @ObservationIgnored private var hungApps: [HealthHungApp] = []
    @ObservationIgnored private var crashes: [String: [Date]] = [:]
    @ObservationIgnored private var knownCrashFiles: Set<String>?
    @ObservationIgnored private var loginItemCount: Int?
    @ObservationIgnored private var lastNotified: [String: Date] = [:]
    @ObservationIgnored private var lastScorePoint = Date.distantPast
    @ObservationIgnored private var psInFlight = false
    @ObservationIgnored private var axInFlight = false
    @ObservationIgnored private var crashInFlight = false
    @ObservationIgnored private var crashWatcher: HealthDirectoryWatcher?
    @ObservationIgnored private var crashDebounce: Task<Void, Never>?
    @ObservationIgnored private var openKeys: [String: Date] = [:] { didSet { if openKeys != oldValue { persistState() } } }
    @ObservationIgnored private var messageClear: Task<Void, Never>?

    private init() {
        events = Store.load([HealthEvent].self, from: "health-log.json") ?? []
        scoreHistory = (Store.load([HealthScorePoint].self, from: "health-score.json") ?? [])
            .filter { $0.date > Date().addingTimeInterval(-3600) }
        if let snap = Store.load(HealthCheckupSnapshot.self, from: "health-checkup.json") {
            checkup = snap.items
            checkupDate = snap.date
        }
        if let p = Store.load(HealthPersisted.self, from: "health-state.json") {
            snoozedUntil = p.snoozed.filter { $0.value > Date() }
            ignoredApps = p.ignoredApps
            lastNotified = p.lastNotified.filter { $0.value > Date().addingTimeInterval(-48 * 3600) }
            openKeys = (p.openKeys ?? [:]).filter { $0.value > Date().addingTimeInterval(-24 * 3600) }
        }
        if let last = scoreHistory.last { score = last.score }
        if !monitoringEnabled { summary = "Monitoring is turned off." }
    }

    // MARK: - Lifecycle

    func start() {
        guard monitoringEnabled, timer == nil else { return }
        isRunning = true
        startedAt = Date()
        summary = "Collecting data…"
        SystemMonitor.shared.requestProcesses(background: true)
        holdingProcesses = true
        if notificationsEnabled { Notifier.requestAuthorization() }
        BatteryMonitor.shared.start()

        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let url = Optional(HealthCrashReports.directory) {
            crashWatcher = HealthDirectoryWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.scheduleCrashScan() }
            }
        }
        scanCrashes()
        refreshLoginItems()
        refreshAssertions()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        crashWatcher?.cancel()
        crashWatcher = nil
        if holdingProcesses { SystemMonitor.shared.releaseProcesses(background: true); holdingProcesses = false }
        isRunning = false
        startedAt = nil
        tracks = [:]; sysTracks = [:]; hungStates = [:]; hungApps = []
        history = []
        if !monitoringEnabled {
            issues = []
            summary = "Monitoring is turned off."
        }
    }

    // MARK: - Tick

    private func tick() {
        let now = Date()
        tickCount += 1
        let sm = SystemMonitor.shared
        let bat = BatteryMonitor.shared.reading

        history.append(HealthSample(
            date: now, cpu: sm.cpu.total, memUsed: sm.memory.usedFraction, pressure: sm.memory.pressureLevel,
            swapUsed: sm.memory.swapUsed, diskAvailable: sm.disk.available, cpuTemp: sm.thermal.cpu,
            thermalState: sm.thermal.state.rawValue, batteryPercent: bat.isPresent ? bat.percent : nil,
            onBattery: bat.isPresent && !bat.isPluggedIn))
        let cutoff = now.addingTimeInterval(-3600)
        if let first = history.first, first.date < cutoff { history.removeAll { $0.date < cutoff } }

        ingest(sm.processes, now: now, recordMem: tickCount % 3 == 0)

        // Spawning ps and pinging every app over AX wake other processes too; keep them sparse.
        if tickCount % 6 == 0 { refreshSystemProcs() }
        if tickCount % 2 == 0 { refreshHung() }
        if tickCount % 30 == 0 { scanCrashes() }
        if tickCount % 180 == 0 { refreshLoginItems() }
        if tickCount % 6 == 0 { refreshAssertions() }
        if tickCount == 3 || tickCount % 2160 == 0, !isCheckingUp,
           checkupDate.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true {
            Task { await performCheckup(includeUpdates: false) }
        }

        evaluate(now: now)
    }

    private func makeContext(now: Date) -> HealthContext {
        let sm = SystemMonitor.shared
        return HealthContext(
            now: now, t: thresholds, history: history, tracks: Array(tracks.values), sysTracks: sysTracks,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            totalMemory: sm.memory.total, memory: sm.memory, disk: sm.disk,
            thermalState: sm.thermal.state, cpuTemp: sm.thermal.cpu,
            battery: BatteryMonitor.shared.reading, uptime: SystemInfo.uptime,
            crashes: crashes, loginItemCount: loginItemCount, hung: hungApps,
            topCPU: sm.topCPU, topMemory: sm.topMemory, checkupFindings: checkupFindings())
    }

    private func evaluate(now: Date) {
        let ctx = makeContext(now: now)
        var findings: [HealthFinding] = []
        for rule in HealthRules.all where !disabledRules.contains(rule.id) {
            findings += rule.evaluate(ctx)
        }
        reconcile(findings, now: now)
        score = HealthScoring.score(issues: issues, ctx: ctx)
        summary = HealthScoring.summary(issues: issues)
        if now.timeIntervalSince(lastScorePoint) >= 60 {
            lastScorePoint = now
            scoreHistory.append(HealthScorePoint(date: now, score: score))
            let cut = now.addingTimeInterval(-3600)
            scoreHistory.removeAll { $0.date < cut }
            if scoreHistory.count % 5 == 0 { Store.save(scoreHistory, to: "health-score.json") }
        }
    }

    // MARK: - Process ingestion

    private func ingest(_ procs: [ProcessSample], now: Date, recordMem: Bool) {
        var seen = Set<Int32>()
        seen.reserveCapacity(procs.count)
        for p in procs {
            seen.insert(p.pid)
            if var tr = tracks[p.pid] {
                if tr.name != p.name {   // pid reuse
                    tr = HealthProcTrack(pid: p.pid, name: p.name, bundleID: p.bundleID)
                }
                tr.cpu.append(HealthTimedValue(t: now, v: p.cpu))
                if tr.cpu.count > 60 { tr.cpu.removeFirst(tr.cpu.count - 60) }
                if recordMem {
                    tr.mem.append(HealthTimedValue(t: now, v: Double(p.memory)))
                    if tr.mem.count > 60 { tr.mem.removeFirst(tr.mem.count - 60) }
                }
                tr.memory = p.memory
                tr.lastSeen = now
                tracks[p.pid] = tr
            } else if p.cpu >= 0.1 || p.memory >= 300_000_000 {
                var tr = HealthProcTrack(pid: p.pid, name: p.name, bundleID: p.bundleID)
                tr.cpu = [HealthTimedValue(t: now, v: p.cpu)]
                tr.mem = [HealthTimedValue(t: now, v: Double(p.memory))]
                tr.memory = p.memory
                tr.lastSeen = now
                tracks[p.pid] = tr
            }
        }
        // Drop exited and long-idle small processes.
        for (pid, tr) in tracks {
            if !seen.contains(pid) { tracks.removeValue(forKey: pid); continue }
            if tr.memory < 300_000_000, tr.cpu.count >= 6, tr.cpu.suffix(6).allSatisfy({ $0.v < 0.02 }) {
                tracks.removeValue(forKey: pid)
            }
        }
    }

    // MARK: - Async probes (all off main)

    private func refreshSystemProcs() {
        guard !psInFlight else { return }
        psInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let sums = HealthPS.sample()
            Task { @MainActor in HealthMonitor.shared.applyPS(sums) }
        }
    }

    private func applyPS(_ sums: [HealthSystemGroup: Double]) {
        psInFlight = false
        let now = Date()
        for g in HealthSystemGroup.allCases {
            var tr = sysTracks[g] ?? HealthSysTrack()
            tr.cpu.append(HealthTimedValue(t: now, v: sums[g] ?? 0))
            if tr.cpu.count > 40 { tr.cpu.removeFirst(tr.cpu.count - 40) }
            sysTracks[g] = tr
        }
    }

    private func refreshHung() {
        let granted = Permissions.isGranted(.accessibility)
        if hungProbeActive != granted { hungProbeActive = granted }
        guard granted, !axInFlight else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var names: [Int32: String] = [:]
        for a in RunningAppCache.shared.regularApps where a.pid != own { names[a.pid] = a.name }
        let pids = Array(names.keys)
        axInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let results = HealthAXProbe.probeAll(pids)
            Task { @MainActor in HealthMonitor.shared.applyHung(results, names: names) }
        }
    }

    private func applyHung(_ results: [Int32: HealthAXProbe.Result], names: [Int32: String]) {
        axInFlight = false
        let now = Date()
        for (pid, r) in results {
            var st = hungStates[pid] ?? HealthHungState(name: names[pid] ?? "App")
            st.name = names[pid] ?? st.name
            switch r {
            case .responsive: st.everResponded = true; st.firstFail = nil; st.fails = 0
            case .hung:
                if st.everResponded { st.firstFail = st.firstFail ?? now; st.fails += 1 }
            case .unknown: break
            }
            hungStates[pid] = st
        }
        for pid in hungStates.keys where results[pid] == nil { hungStates.removeValue(forKey: pid) }
        hungApps = hungStates.compactMap { pid, st in
            guard st.everResponded, st.fails >= 3, let since = st.firstFail, now.timeIntervalSince(since) >= 30 else { return nil }
            return HealthHungApp(pid: pid, name: st.name, since: since)
        }
    }

    private func scheduleCrashScan() {
        crashDebounce?.cancel()
        crashDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.scanCrashes()
        }
    }

    private func scanCrashes() {
        guard !crashInFlight else { return }
        crashInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let scan = HealthCrashReports.scan()
            Task { @MainActor in HealthMonitor.shared.applyCrashScan(scan) }
        }
    }

    private func applyCrashScan(_ scan: HealthCrashScan) {
        crashInFlight = false
        if let known = knownCrashFiles {
            let fresh = scan.files.subtracting(known).sorted()
            for f in fresh.prefix(5) {
                if let app = HealthCrashReports.appName(fromFile: f) {
                    log(.info, .info, "\(app) crashed", "A new crash report was written: \(f)")
                }
            }
        }
        knownCrashFiles = scan.files
        crashes = scan.crashes
    }

    private func refreshLoginItems() {
        DispatchQueue.global(qos: .utility).async {
            let n = HealthStartupItems.count()
            Task { @MainActor in HealthMonitor.shared.loginItemCount = n }
        }
    }

    func refreshAssertions() {
        DispatchQueue.global(qos: .utility).async {
            let list = HealthAssertions.read()
            Task { @MainActor in HealthMonitor.shared.sleepBlockers = list }
        }
    }

    // MARK: - Reconcile / notify

    private func reconcile(_ findings: [HealthFinding], now: Date) {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        let active = findings.filter { f in
            if let until = snoozedUntil[f.key], until > now { return false }
            if let app = f.appName, ignoredApps.contains(app) { return false }
            return true
        }
        var seen = Set<String>()
        for f in active {
            seen.insert(f.key)
            if let idx = issues.firstIndex(where: { $0.key == f.key }) {
                issues[idx].severity = f.severity
                issues[idx].title = f.title
                issues[idx].detail = f.detail
                issues[idx].actions = f.actions
                issues[idx].missCount = 0
            } else {
                let issue = HealthIssue(key: f.key, ruleID: f.ruleID, severity: f.severity, title: f.title,
                                        detail: f.detail, actions: f.actions, appName: f.appName, detectedAt: now)
                issues.append(issue)
                // Still open from a previous launch: don't log or notify the same condition again.
                if openKeys[f.key] == nil {
                    openKeys[f.key] = now
                    log(.detected, issue.severity, issue.title, issue.detail)
                    notifyIfNeeded(issue, now: now)
                }
            }
        }
        // Auto-resolve after 3 consecutive evaluations without the condition (avoids flapping).
        var resolved: [HealthIssue] = []
        for i in issues.indices where !seen.contains(issues[i].key) {
            issues[i].missCount += 1
            if issues[i].missCount >= 3 { resolved.append(issues[i]) }
        }
        if !resolved.isEmpty {
            let keys = Set(resolved.map(\.key))
            issues.removeAll { keys.contains($0.key) }
            for k in keys { openKeys[k] = nil }
            for r in resolved { log(.resolved, .info, "Resolved: \(r.title)", "The condition cleared on its own.") }
        }
        issues.sort { ($0.severity, $0.detectedAt) > ($1.severity, $1.detectedAt) }
    }

    private func isQuietHours(_ date: Date) -> Bool {
        guard quietHoursEnabled, quietStartMinutes != quietEndMinutes else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quietStartMinutes < quietEndMinutes
            ? (m >= quietStartMinutes && m < quietEndMinutes)
            : (m >= quietStartMinutes || m < quietEndMinutes)
    }

    private func notifyIfNeeded(_ issue: HealthIssue, now: Date) {
        guard notificationsEnabled, issue.severity >= .warning, !isQuietHours(now) else { return }
        let cooldown = HealthRules.rule(id: issue.ruleID)?.cooldown ?? 1800
        if let last = lastNotified[issue.key], now.timeIntervalSince(last) < cooldown { return }
        lastNotified[issue.key] = now
        persistState()
        Notifier.post(title: issue.title, body: issue.detail, id: "health.\(issue.key)")
    }

    // MARK: - Persistence & log

    private func persistState() {
        Store.save(HealthPersisted(snoozed: snoozedUntil, ignoredApps: ignoredApps, lastNotified: lastNotified,
                                   openKeys: openKeys),
                   to: "health-state.json")
    }

    private func log(_ kind: HealthEventKind, _ severity: HealthSeverity, _ title: String, _ detail: String = "") {
        events.insert(HealthEvent(date: Date(), kind: kind, severity: severity, title: title, detail: detail), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        Store.save(events, to: "health-log.json")
    }

    func clearLog() {
        events = []
        Store.save(events, to: "health-log.json")
    }

    private func flash(_ message: String) {
        lastActionMessage = message
        messageClear?.cancel()
        messageClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastActionMessage = nil
        }
    }

    // MARK: - Rule toggles & ignore lists

    func isRuleEnabled(_ id: String) -> Bool { !disabledRules.contains(id) }

    func setRule(_ id: String, enabled: Bool) {
        if enabled { disabledRules.remove(id) } else { disabledRules.insert(id) }
        if isRunning { tick() }
    }

    func snooze(_ issue: HealthIssue, hours: Double = 24) {
        snoozedUntil[issue.key] = Date().addingTimeInterval(hours * 3600)
        issues.removeAll { $0.key == issue.key }
        log(.action, .info, "Snoozed: \(issue.title)", "Hidden for \(Int(hours)) hours.")
        evaluate(now: Date())
    }

    func ignoreApp(_ name: String) {
        if !ignoredApps.contains(name) { ignoredApps.append(name) }
        issues.removeAll { $0.appName == name }
        log(.action, .info, "Ignoring \(name)", "Health alerts for this app are turned off.")
        evaluate(now: Date())
    }

    func unignoreApp(_ name: String) { ignoredApps.removeAll { $0 == name } }
    func clearSnoozes() { snoozedUntil = [:] }

    // MARK: - Fix actions

    func perform(_ action: HealthFixAction, for issue: HealthIssue? = nil) {
        switch action {
        case .quit(let pid, let name): quitProcess(pid: pid, name: name, force: false)
        case .forceQuit(let pid, let name):
            guard HealthConfirm.ask("Force quit \(name)?", "Unsaved changes in \(name) will be lost.", confirm: "Force Quit", destructive: true) else { return }
            quitProcess(pid: pid, name: name, force: true)
        case .restartApp(let pid, let name): restartApp(pid: pid, name: name, force: issue?.ruleID == "hung")
        case .ignoreApp(let name): ignoreApp(name)
        case .showTopCPU: presentedTopList = .cpu
        case .showTopMemory: presentedTopList = .memory
        case .openSection(let section, _):
            NotificationCenter.default.post(name: Notification.Name("MacMaster.openSection"), object: section)
        case .freeRAM: freeRAM()
        case .rebuildSpotlight: rebuildSpotlight()
        case .restartMac: restartMac()
        }
    }

    private func quitProcess(pid: Int32, name: String, force: Bool) {
        guard HealthSafety.canQuit(pid: pid) else { flash("\(name) is a system process and can't be quit from here."); return }
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
        log(.action, .info, "\(force ? "Force quit" : "Quit") \(name)", "Requested by you from a health alert.")
        flash("\(force ? "Force quit" : "Asked") \(name) \(force ? "" : "to quit")".trimmingCharacters(in: .whitespaces))
    }

    private func restartApp(pid: Int32, name: String, force: Bool) {
        guard HealthSafety.canQuit(pid: pid), let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else {
            quitProcess(pid: pid, name: name, force: false); return
        }
        if force {
            guard HealthConfirm.ask("Restart \(name)?", "\(name) isn't responding. It will be force quit and reopened; unsaved changes are lost.", confirm: "Restart", destructive: true) else { return }
            app.forceTerminate()
        } else {
            app.terminate()
        }
        log(.action, .info, "Restarting \(name)", "")
        flash("Restarting \(name)…")
        Task { @MainActor in
            for _ in 0..<40 {
                if app.isTerminated { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if app.isTerminated {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                flash("\(name) didn't quit. Try Force Quit.")
            }
        }
    }

    private func freeRAM() {
        flash("Freeing inactive memory…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.runAsAdmin("/usr/sbin/purge", [], prompt: "MacMaster wants to free inactive memory.")
            Task { @MainActor in
                let m = HealthMonitor.shared
                if r.ok { m.log(.action, .info, "Freed RAM", "Ran purge to release inactive memory."); m.flash("Inactive memory released.") }
                else { m.flash("Couldn't free RAM: \(r.stderr.isEmpty ? "cancelled" : r.stderr)") }
            }
        }
    }

    private func rebuildSpotlight() {
        guard HealthConfirm.ask("Rebuild the Spotlight index?",
                                "Spotlight will re-index your startup disk. Search results are incomplete and CPU use is high until it finishes, which can take hours. Requires administrator rights.",
                                confirm: "Rebuild", destructive: false) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.runAsAdmin("/usr/bin/mdutil", ["-E", "/"], prompt: "MacMaster wants to rebuild the Spotlight index.")
            Task { @MainActor in
                let m = HealthMonitor.shared
                if r.ok { m.log(.action, .info, "Spotlight rebuild started", "Ran mdutil -E /"); m.flash("Spotlight is re-indexing.") }
                else { m.flash("Couldn't rebuild: \(r.stderr.isEmpty ? "cancelled" : r.stderr)") }
            }
        }
    }

    private func restartMac() {
        guard HealthConfirm.ask("Restart your Mac?", "Apps will be asked to quit. Save your work first.", confirm: "Restart", destructive: false) else { return }
        log(.action, .info, "Restart requested", "")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to restart"], timeout: 30)
        }
    }

    // MARK: - Full checkup

    func runCheckup() {
        guard !isCheckingUp else { return }
        if isRunning { tick() } else { evaluate(now: Date()) }
        refreshAssertions()
        Task { await performCheckup(includeUpdates: true) }
    }

    private func setItem(_ item: HealthCheckItem) {
        if let i = checkup.firstIndex(where: { $0.id == item.id }) { checkup[i] = item } else { checkup.append(item) }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
        }
    }

    private func performCheckup(includeUpdates: Bool) async {
        guard !isCheckingUp else { return }
        isCheckingUp = true
        var ids = ["smart", "filevault", "sip", "firewall", "gatekeeper", "backup", "startup"]
        if includeUpdates { ids.append("updates") }
        for t in HealthCheckup.templates {
            if checkup.contains(where: { $0.id == t.id }) == false { setItem(t) }
        }
        for id in ids {
            if var it = checkup.first(where: { $0.id == id }) { it.status = .running; setItem(it) }
        }

        async let smart = offMain { HealthCheckup.smart() }
        async let fv = offMain { HealthCheckup.fileVault() }
        async let sip = offMain { HealthCheckup.sip() }
        async let fw = offMain { HealthCheckup.firewall() }
        async let gk = offMain { HealthCheckup.gatekeeper() }
        async let bk = offMain { HealthCheckup.backup() }
        let limit = thresholds.loginItems
        async let st = offMain { HealthCheckup.startup(count: HealthStartupItems.count(), limit: limit) }

        setItem(await smart); setItem(await fv); setItem(await sip)
        setItem(await fw); setItem(await gk)
        setItem(await bk.0)
        setItem(await st)
        if includeUpdates { setItem(await offMain { HealthCheckup.updates().0 }) }

        checkupDate = Date()
        Store.save(HealthCheckupSnapshot(date: checkupDate ?? Date(), items: checkup.filter { $0.status != .running }),
                   to: "health-checkup.json")
        let warnings = checkup.filter { $0.status == .warning }.count
        log(.info, warnings > 0 ? .warning : .info, "Checkup finished",
            warnings > 0 ? "\(warnings) item\(warnings == 1 ? " needs" : "s need") attention." : "Everything checks out.")
        isCheckingUp = false
        evaluate(now: Date())
    }

    private func checkupFindings() -> [HealthFinding] {
        var out: [HealthFinding] = []
        for it in checkup {
            switch (it.id, it.status) {
            case ("smart", .warning):
                out.append(HealthFinding(key: "disk.smart", ruleID: "checkup", severity: .critical,
                                         title: "Disk is reporting failure", detail: it.detail))
            case ("backup", .warning):
                out.append(HealthFinding(key: "backup.old", ruleID: "checkup", severity: .info,
                                         title: "Back up your Mac", detail: it.detail))
            case ("updates", .info):
                out.append(HealthFinding(key: "updates.available", ruleID: "checkup", severity: .info,
                                         title: "macOS updates are available", detail: it.detail))
            default: break
            }
        }
        return out
    }
}

// MARK: - Confirmation dialog

@MainActor
enum HealthConfirm {
    static func ask(_ title: String, _ message: String, confirm: String, destructive: Bool) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .warning : .informational
        a.addButton(withTitle: confirm)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
