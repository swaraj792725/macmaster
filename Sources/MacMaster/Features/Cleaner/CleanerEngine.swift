import SwiftUI
import AppKit
import Observation

@Observable
@MainActor
final class CleanerEngine {
    static let shared = CleanerEngine()

    enum Phase { case idle, scanning, results, cleaning, done }

    private(set) var phase: Phase = .idle
    private(set) var results: [CleanerCategoryID: [CleanerItem]] = [:]
    private(set) var finished: Set<CleanerCategoryID> = []
    var selected: Set<UUID> = []
    private(set) var cleanProgress = 0.0
    private(set) var cleanStatus = ""
    private(set) var summary: CleanerSummary?
    private(set) var lastScan: Date?

    private(set) var ramBusy = false
    private(set) var ramMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {}

    // MARK: Derived

    var categoriesInOrder: [CleanerCategoryID] { CleanerCategoryID.allCases }

    func items(_ id: CleanerCategoryID) -> [CleanerItem] { results[id] ?? [] }

    func total(_ id: CleanerCategoryID) -> Int64 { items(id).reduce(0) { $0 + $1.size } }

    var totalReclaimable: Int64 {
        results.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.size } }
    }

    var selectedItems: [CleanerItem] {
        results.values.flatMap { $0 }.filter { selected.contains($0.id) && $0.isSelectable }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var scanProgress: Double { Double(finished.count) / Double(CleanerCategoryID.allCases.count) }

    /// Triple state for a category checkbox.
    func selectionState(_ id: CleanerCategoryID) -> CleanerCheckState {
        let sel = items(id).filter(\.isSelectable)
        guard !sel.isEmpty else { return .off }
        let n = sel.filter { selected.contains($0.id) }.count
        return n == 0 ? .off : (n == sel.count ? .on : .mixed)
    }

    func setCategory(_ id: CleanerCategoryID, on: Bool) {
        for item in items(id) where item.isSelectable {
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    func toggle(_ item: CleanerItem) {
        guard item.isSelectable else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func selectAllSafe() {
        selected = Set(results.values.flatMap { $0 }.filter { $0.category.safety == .safe && $0.isSelectable }.map(\.id))
    }

    func deselectAll() { selected = [] }

    // MARK: Scan

    nonisolated static func runningBundleIDs() -> Set<String> {
        // NSWorkspace is safe to read from any thread for this property in practice, but we call it on main.
        if Thread.isMainThread {
            return Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        return DispatchQueue.main.sync { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    }

    func scan() {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        results = [:]
        finished = []
        selected = []
        summary = nil
        let ctx = CleanerScanContext(runningBundleIDs: Self.runningBundleIDs())
        scanTask = Task {
            await withTaskGroup(of: (CleanerCategoryID, [CleanerItem]).self) { group in
                for id in CleanerCategoryID.allCases {
                    group.addTask { (id, await CleanerScanner.scan(id, ctx: ctx)) }
                }
                for await (id, items) in group {
                    if Task.isCancelled { break }
                    withAnimation(.smooth) {
                        results[id] = items
                        finished.insert(id)
                    }
                    if id.safety == .safe {
                        for i in items where i.isSelectable { selected.insert(i.id) }
                    }
                }
            }
            if Task.isCancelled { phase = .idle; return }
            lastScan = Date()
            withAnimation(.smooth) { phase = .results }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = results.isEmpty ? .idle : .results
    }

    func reset() {
        scanTask?.cancel()
        results = [:]; finished = []; selected = []; summary = nil
        phase = .idle
    }

    func backToResults() { withAnimation(.smooth) { phase = results.isEmpty ? .idle : .results } }

    // MARK: Clean

    func clean() {
        let items = selectedItems
        guard !items.isEmpty, phase == .results else { return }
        phase = .cleaning
        cleanProgress = 0
        cleanStatus = "Preparing…"
        Task {
            let outcome = await CleanerRemover.run(items: items, minAge: nil, allowAdmin: true) { p, s in
                Task { @MainActor in
                    CleanerEngine.shared.cleanProgress = p
                    CleanerEngine.shared.cleanStatus = s
                }
            }
            finish(items: items, outcome: outcome)
        }
    }

    private func finish(items: [CleanerItem], outcome: CleanerOutcome) {
        let failedNames = Set(outcome.failures.map(\.name))
        let removedIDs = Set(items.filter { !failedNames.contains($0.name) }.map(\.id))
        for (cat, list) in results {
            results[cat] = list.filter { !removedIDs.contains($0.id) }
        }
        selected.subtract(removedIDs)
        summary = CleanerSummary(freed: outcome.freed, removedCount: outcome.removedCount,
                                 failures: outcome.failures, perCategory: outcome.perCategory)
        CleanerScheduler.shared.record(CleanerHistoryEntry(
            date: Date(), freed: outcome.freed, itemCount: outcome.removedCount, failureCount: outcome.failures.count,
            automatic: false, categories: Array(Set(items.map { $0.category.title })).sorted()))
        withAnimation(.smooth) { phase = .done }
        CleanerStorage.shared.refresh(force: true)
    }

    // MARK: Free RAM

    func freeRAM() {
        guard !ramBusy else { return }
        ramBusy = true
        ramMessage = nil
        let before = SystemMonitor.shared.memory.free + SystemMonitor.shared.memory.cached
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Shell.runAsAdmin("/usr/sbin/purge", [], prompt: "MacMaster needs administrator access to free up memory.")
            }.value
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let after = SystemMonitor.shared.memory.free + SystemMonitor.shared.memory.cached
            ramBusy = false
            if r.ok {
                let gained = Int64(after) - Int64(before)
                ramMessage = gained > 0 ? "Memory purged. \(Fmt.bytes(gained)) more available." : "Memory purged."
            } else {
                ramMessage = r.stderr.contains("-128") ? "Cancelled." : "Could not purge memory: \(r.stderr)"
            }
        }
    }
}

enum CleanerCheckState { case off, mixed, on }
