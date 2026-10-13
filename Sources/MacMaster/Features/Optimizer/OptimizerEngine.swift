import SwiftUI
import AppKit
import Observation

/// Analyzes the Mac, recommends optimizations, applies them and (optionally) watches for trouble.
@MainActor
@Observable
final class OptimizerEngine {
    static let shared = OptimizerEngine()

    // MARK: Published state

    private(set) var score = 0
    private(set) var hasScore = false
    private(set) var scoreFactors: [OptimizerScoreFactor] = []
    private(set) var recommendations: [OptimizerRecommendation] = []
    private(set) var snapshot: OptimizerSnapshot?
    private(set) var isAnalyzing = false
    private(set) var analysisStep = ""
    private(set) var isApplying = false
    private(set) var lastAnalyzed: Date?
    private(set) var lastResult: OptimizerResult?
    private(set) var lastError: String?
    /// Live per-task progress while `apply` runs (kept afterwards for the result screen).
    private(set) var tasks: [OptimizerTaskReport] = []
    private(set) var history: [OptimizerHistoryEntry] = Store.load([OptimizerHistoryEntry].self, from: "optimizer-history.json") ?? []

    private(set) var maintenanceStatus: [String: OptimizerTaskStatus] = [:]
    private(set) var maintenanceMessage: [String: String] = [:]
    @ObservationIgnored private var maintenanceTick = 0
    /// Bumped whenever a maintenance run finishes so views refresh "last run" labels.
    private(set) var maintenanceRevision = 0

    let tweaks = OptimizerTweakModel()

    // MARK: Auto-optimize settings (opt-in)

    var autoEnabled: Bool = UserDefaults.standard.bool(forKey: "mm.optimizer.auto") {
        didSet {
            UserDefaults.standard.set(autoEnabled, forKey: "mm.optimizer.auto")
            if autoEnabled { Notifier.requestAuthorization() }
            syncProcessDemand()
            if !autoEnabled { criticalSince = nil; hogSince = [:] }
        }
    }
    var autoRunSafeTasks: Bool = UserDefaults.standard.bool(forKey: "mm.optimizer.auto.run") {
        didSet { UserDefaults.standard.set(autoRunSafeTasks, forKey: "mm.optimizer.auto.run") }
    }
    /// Minutes a condition must persist before the optimizer reacts.
    var autoMinutes: Int = {
        let v = UserDefaults.standard.integer(forKey: "mm.optimizer.auto.minutes")
        return v == 0 ? 5 : min(max(v, 1), 60)
    }() {
        didSet { UserDefaults.standard.set(autoMinutes, forKey: "mm.optimizer.auto.minutes") }
    }
    /// A process above this % of one core counts as a hog.
    var autoCPUPercent: Int = {
        let v = UserDefaults.standard.integer(forKey: "mm.optimizer.auto.cpu")
        return v == 0 ? 90 : min(max(v, 30), 800)
    }() {
        didSet { UserDefaults.standard.set(autoCPUPercent, forKey: "mm.optimizer.auto.cpu") }
    }

    // MARK: Private

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var holdingProcesses = false
    @ObservationIgnored private var criticalSince: Date?
    @ObservationIgnored private var hogSince: [pid_t: (name: String, since: Date)] = [:]
    @ObservationIgnored private var notifiedAt: [String: Date] = [:]
    @ObservationIgnored private var pollCount = 0

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await self?.refreshScoreIfIdle()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                await self.pollTick()
            }
        }
        syncProcessDemand()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if holdingProcesses { SystemMonitor.shared.releaseProcesses(background: true); holdingProcesses = false }
    }

    private func syncProcessDemand() {
        let want = autoEnabled && pollTask != nil
        if want && !holdingProcesses { SystemMonitor.shared.requestProcesses(background: true); holdingProcesses = true }
        if !want && holdingProcesses { SystemMonitor.shared.releaseProcesses(background: true); holdingProcesses = false }
    }

    private func refreshScoreIfIdle() async {
        guard !isAnalyzing, !isApplying else { return }
        await analyze(deep: false)
    }

    // MARK: Analysis

    /// Full analysis, including ~8 s of CPU sampling to find sustained hogs.
    func analyze() async { await analyze(deep: true) }

    func analyze(deep: Bool) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        lastError = nil
        analysisStep = "Scanning system…"
        defer { isAnalyzing = false; analysisStep = "" }

        let monitor = SystemMonitor.shared
        let sysTask = Task.detached(priority: .userInitiated) {
            OptimizerAnalyzer.collectSystem { step in
                Task { @MainActor in
                    if OptimizerEngine.shared.isAnalyzing { OptimizerEngine.shared.analysisStep = step }
                }
            }
        }

        var samples: [[ProcessSample]] = []
        if deep {
            monitor.requestProcesses()
            analysisStep = "Sampling CPU activity…"
            // The monitor's first process read has no CPU baseline; let two ticks pass.
            try? await Task.sleep(for: .milliseconds(4300))
            for i in 0..<3 {
                samples.append(monitor.processes)
                analysisStep = "Sampling CPU activity… \(i + 1)/3"
                if i < 2 { try? await Task.sleep(for: .milliseconds(2100)) }
            }
            monitor.releaseProcesses()
        } else if !monitor.processes.isEmpty {
            samples = [monitor.processes]
        }

        analysisStep = "Checking running apps…"
        let apps = NSWorkspace.shared.runningApplications.map {
            OptimizerRunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier,
                                bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        var snap = await sysTask.value
        let usedSamples = samples
        snap = await Task.detached(priority: .userInitiated) {
            var s = snap
            OptimizerAnalyzer.collectProcesses(apps: apps, frontPID: front, samples: usedSamples, into: &s)
            return s
        }.value

        let (value, factors) = OptimizerScoring.evaluate(snap)
        withAnimation(.smooth(duration: 0.6)) {
            snapshot = snap
            score = value
            hasScore = true
            scoreFactors = factors
            recommendations = OptimizerRecommender.build(snap)
            lastAnalyzed = Date()
        }
    }

    // MARK: Applying

    /// Runs the selected recommendations: non-admin tasks one by one, then all admin tasks under one prompt.
    func apply(_ ids: Set<String>) async { await apply(ids, source: "manual") }

    func apply(_ ids: Set<String>, source: String) async {
        guard !isApplying else { return }
        let selected = recommendations.filter { ids.contains($0.id) && $0.isActionable }
        guard !selected.isEmpty else { return }

        isApplying = true
        lastError = nil
        let scoreBefore = score
        let before = await Task.detached { OptimizerMeasure.read() }.value
        tasks = selected.map { OptimizerTaskReport(id: $0.id, title: $0.title, symbol: $0.symbol, requiresAdmin: $0.requiresAdmin) }

        // 1. Non-admin
        for rec in selected where !rec.requiresAdmin {
            update(rec.id, .running, "")
            if let action = rec.apply {
                let outcome = await action()
                update(rec.id, outcome.ok ? .done : .failed, outcome.message)
                if outcome.ok, OptimizerMaintenance.task(rec.id) != nil { OptimizerMaintenance.markRun(rec.id) }
            } else {
                update(rec.id, .skipped, "Nothing to do")
            }
        }

        // 2. Admin batch (single password prompt)
        let admin = selected.filter { $0.requiresAdmin }
        if !admin.isEmpty {
            admin.forEach { update($0.id, .running, "Waiting for administrator approval…") }
            let items = admin.compactMap { r in r.adminCommand.map { (id: Self.safeID(r.id), command: $0) } }
            let names = admin.map(\.title).prefix(3).joined(separator: ", ")
            let outcome = await OptimizerMaintenance.adminBatch(
                items, prompt: "MacMaster wants to run: \(names)\(admin.count > 3 ? " and more" : ""). This needs an administrator password.")
            for r in admin {
                if outcome.cancelled {
                    update(r.id, .skipped, "Cancelled. No password entered.")
                } else if !outcome.error.isEmpty {
                    update(r.id, .failed, outcome.error)
                } else if outcome.results[Self.safeID(r.id)] == true {
                    update(r.id, .done, "Done")
                    if OptimizerMaintenance.task(r.id) != nil { OptimizerMaintenance.markRun(r.id) }
                } else {
                    update(r.id, .failed, "The command reported an error")
                }
            }
        }

        // 3. Measure & summarize
        try? await Task.sleep(for: .milliseconds(1200))
        let after = await Task.detached { OptimizerMeasure.read() }.value
        let purged = tasks.contains { $0.id == "mem.purge" && $0.status == .done }
        let reports = tasks
        await analyzeAfterApply()
        isApplying = false

        let result = Self.makeResult(source: source, reports: reports, before: before, after: after,
                                     scoreBefore: scoreBefore, scoreAfter: score, purged: purged)
        lastResult = result
        record(result)
    }

    private func analyzeAfterApply() async {
        while isAnalyzing { try? await Task.sleep(for: .milliseconds(200)) }
        await analyze(deep: false)
    }

    private func update(_ id: String, _ status: OptimizerTaskStatus, _ message: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth) {
            tasks[i].status = status
            tasks[i].message = message
        }
    }

    private static func safeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    private static func makeResult(source: String, reports: [OptimizerTaskReport], before: OptimizerMeasure,
                                   after: OptimizerMeasure, scoreBefore: Int, scoreAfter: Int, purged: Bool) -> OptimizerResult {
        var memFreed = max(0, Int64(before.memUsed) - Int64(after.memUsed))
        if purged { memFreed += max(0, Int64(before.memCached) - Int64(after.memCached)) }
        let diskFreed = max(0, after.diskFree - before.diskFree)
        let done = reports.filter { $0.status == .done }.count
        var parts = ["Completed \(done) of \(reports.count) task\(reports.count == 1 ? "" : "s")"]
        if memFreed > 0 { parts.append("freed \(Fmt.bytes(memFreed)) of memory") }
        if diskFreed > 1 << 20 { parts.append("recovered \(Fmt.bytes(diskFreed)) of disk space") }
        if scoreAfter != scoreBefore { parts.append("score \(scoreBefore) to \(scoreAfter)") }
        return OptimizerResult(date: Date(), source: source, reports: reports, before: before, after: after,
                               scoreBefore: scoreBefore, scoreAfter: scoreAfter, memoryFreed: memFreed,
                               diskFreed: diskFreed, summary: parts.joined(separator: ", "))
    }

    private func record(_ r: OptimizerResult) {
        let entry = OptimizerHistoryEntry(
            date: r.date, source: r.source,
            tasks: r.reports.filter { $0.status == .done }.map(\.title),
            summary: r.summary, memoryFreed: r.memoryFreed > 0 ? r.memoryFreed : nil,
            diskFreed: r.diskFreed > 1 << 20 ? r.diskFreed : nil,
            scoreBefore: r.scoreBefore, scoreAfter: r.scoreAfter)
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        Store.save(history, to: "optimizer-history.json")
    }

    /// Removes a recommendation from the current list (e.g. after the user force-quit its process).
    func dismiss(_ id: String) {
        withAnimation(.smooth) { recommendations.removeAll { $0.id == id } }
    }

    func clearHistory() {
        history = []
        Store.save(history, to: "optimizer-history.json")
    }

    // MARK: One-shot entry points (menu bar)

    /// Safe, non-admin tasks only. Returns a one-line summary.
    func quickOptimize() async -> String {
        guard !isApplying, !isAnalyzing else { return "The optimizer is busy. Try again in a moment." }
        await analyze(deep: false)
        let ids = Set(recommendations.filter { $0.isSafe && $0.isActionable }.map(\.id))
        guard !ids.isEmpty else { return "Your Mac is already in good shape (score \(score))." }
        await apply(ids, source: "quick")
        return lastResult?.summary ?? "Quick optimize finished."
    }

    /// Frees inactive memory with `purge` after an administrator prompt.
    func freeMemory() async -> String {
        guard !isApplying else { return "The optimizer is busy. Try again in a moment." }
        isApplying = true
        defer { isApplying = false }
        let before = await Task.detached { OptimizerMeasure.read() }.value
        let r = await OptimizerMaintenance.admin(
            "/usr/sbin/purge", [],
            prompt: "MacMaster wants to free inactive memory. This runs the built-in purge command and needs an administrator password.")
        if OptimizerMaintenance.isCancelled(r) { return "Cancelled. No changes made." }
        guard r.ok else { return "Couldn't free memory: \(OptimizerMaintenance.firstLine(r.stderr))" }
        try? await Task.sleep(for: .milliseconds(1200))
        let after = await Task.detached { OptimizerMeasure.read() }.value
        let freed = max(0, Int64(before.memCached) - Int64(after.memCached)) + max(0, Int64(before.memUsed) - Int64(after.memUsed))
        let summary = freed > 0 ? "Freed \(Fmt.bytes(freed)) of memory." : "Memory released. Nothing noticeable was reclaimable."
        let entry = OptimizerHistoryEntry(date: Date(), source: "memory", tasks: ["Purge inactive memory"], summary: summary,
                                          memoryFreed: freed > 0 ? freed : nil, diskFreed: nil, scoreBefore: nil, scoreAfter: nil)
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        Store.save(history, to: "optimizer-history.json")
        return summary
    }

    // MARK: Maintenance (Maintenance tab and recommendations)

    func lastRun(_ id: String) -> Date? { _ = maintenanceRevision; return OptimizerMaintenance.lastRun(id) }

    /// Runs one maintenance task by id (admin tasks prompt for a password).
    @discardableResult
    func performMaintenance(_ id: String) async -> OptimizerOutcome {
        guard let t = OptimizerMaintenance.task(id) else { return OptimizerOutcome(ok: false, message: "Unknown task") }
        maintenanceStatus[id] = .running
        maintenanceMessage[id] = t.requiresAdmin ? "Waiting for administrator approval…" : (t.longRunning ? "Working. This can take a while…" : "Working…")
        var outcome: OptimizerOutcome
        if let cmd = t.adminCommand {
            let r = await OptimizerMaintenance.admin(
                "/bin/sh", ["-c", cmd], prompt: "MacMaster wants to run: \(t.title). This needs an administrator password.")
            if OptimizerMaintenance.isCancelled(r) { outcome = OptimizerOutcome(ok: false, message: "Cancelled", cancelled: true) }
            else { outcome = OptimizerOutcome(ok: r.ok, message: r.ok ? "Done" : OptimizerMaintenance.firstLine(r.stderr)) }
        } else if let run = t.run {
            outcome = await run()
        } else {
            outcome = OptimizerOutcome(ok: false, message: "Nothing to run")
        }
        if outcome.ok { OptimizerMaintenance.markRun(id) }
        maintenanceStatus[id] = outcome.ok ? .done : (outcome.cancelled ? .skipped : .failed)
        maintenanceMessage[id] = outcome.message
        maintenanceRevision += 1
        return outcome
    }

    // MARK: Auto-optimize polling

    private func pollTick() async {
        pollCount += 1
        guard !isApplying, !isAnalyzing else { return }
        // Cheap score refresh every ~7 minutes.
        if pollCount % 10 == 0 { await analyze(deep: false) }
        guard autoEnabled else { return }
        syncProcessDemand()
        evaluateAuto(now: Date())
    }

    private func evaluateAuto(now: Date) {
        let monitor = SystemMonitor.shared
        let window = TimeInterval(autoMinutes * 60)
        var findings: [String] = []

        // Memory pressure
        if monitor.memory.pressureLevel >= 4 {
            if criticalSince == nil { criticalSince = now }
            if let since = criticalSince, now.timeIntervalSince(since) >= window, canNotify("auto.memory", now) {
                let top = monitor.topMemory.prefix(3).map { "\($0.name) (\(Fmt.bytes($0.memory)))" }.joined(separator: ", ")
                let mins = Int(now.timeIntervalSince(since) / 60)
                findings.append("Memory pressure has been critical for \(mins) min." + (top.isEmpty ? "" : " Biggest users: \(top)."))
                notifiedAt["auto.memory"] = now
            }
        } else {
            criticalSince = nil
        }

        // Runaway CPU
        let threshold = Double(autoCPUPercent) / 100
        var current = Set<pid_t>()
        for p in monitor.processes where p.cpu >= threshold && OptimizerProc.isUserProcess(p.pid) {
            current.insert(p.pid)
            if hogSince[p.pid] == nil { hogSince[p.pid] = (p.name, now) }
        }
        for pid in hogSince.keys where !current.contains(pid) { hogSince[pid] = nil }
        for (pid, entry) in hogSince where now.timeIntervalSince(entry.since) >= window && canNotify("auto.cpu.\(pid)", now) {
            let pct = monitor.processes.first { $0.pid == pid }.map { Int($0.cpu * 100) } ?? autoCPUPercent
            findings.append("\(entry.name) has used about \(pct)% of a CPU core for \(Int(now.timeIntervalSince(entry.since) / 60)) min.")
            notifiedAt["auto.cpu.\(pid)"] = now
        }

        guard !findings.isEmpty else { return }
        if autoRunSafeTasks {
            Task { [weak self] in
                guard let self else { return }
                let summary = await self.quickOptimize()
                Notifier.post(title: "MacMaster optimized your Mac", body: findings.joined(separator: " ") + " " + summary,
                              id: "optimizer.auto")
            }
        } else {
            Notifier.post(title: "Your Mac could use attention", body: findings.joined(separator: " ") + " Open Optimizer to fix it.",
                          id: "optimizer.auto")
        }
    }

    private func canNotify(_ key: String, _ now: Date) -> Bool {
        guard let last = notifiedAt[key] else { return true }
        return now.timeIntervalSince(last) > 30 * 60
    }
}
