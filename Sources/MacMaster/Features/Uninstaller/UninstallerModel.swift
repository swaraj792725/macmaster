import AppKit
import SwiftUI

@Observable
@MainActor
final class UninstallerModel {
    static let shared = UninstallerModel()

    enum Tab: String, CaseIterable, Identifiable {
        case applications = "Applications"
        case hunter = "Leftover Hunter"
        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case name = "Name", size = "Size", lastUsed = "Last used"
        var id: String { rawValue }
    }

    enum FilterKey: String, CaseIterable, Identifiable {
        case all = "All apps", unused = "Unused apps", large = "Large (500 MB+)"
        var id: String { rawValue }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case uninstall = "Uninstall", reset = "Reset app data"
        var id: String { rawValue }
    }

    enum HunterPhase { case idle, scanning, done }

    // MARK: State – applications

    var tab: Tab = .applications
    var apps: [UninstallerApp] = []
    var loadingApps = false
    var search = ""
    var sort: SortKey = .name
    var filter: FilterKey = .all
    var selectedAppID: String?
    var runningPaths: Set<String> = []
    var unusedSelection: Set<String> = []

    var mode: Mode = .uninstall
    var scanning = false
    var scanProgress = ""
    var items: [UninstallerItem] = []
    var selection: Set<String> = []

    // MARK: State – hunter

    var hunterPhase: HunterPhase = .idle
    var hunterProgress = ""
    var groups: [UninstallerGroup] = []
    var brokenItems: [UninstallerItem] = []
    var hunterSelection: Set<String> = []
    var expandedGroups: Set<String> = []
    var hunterInstalledCount = 0
    var hunterScannedEntries = 0
    var lastHunterScan: Date?

    // MARK: State – removal

    var plan: UninstallerRemovalPlan?
    var isRemoving = false
    var removalProgress = ""
    var summary: UninstallerRemovalSummary?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var hunterTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    private init() {}

    // MARK: - Catalog

    func loadApps(force: Bool = false) {
        startObservingWorkspace()
        refreshRunning()
        if loadingApps || (!apps.isEmpty && !force) { return }
        loadingApps = true
        Task.detached(priority: .userInitiated) {
            let found = UninstallerAppCatalog.discover()
            await MainActor.run {
                let model = UninstallerModel.shared
                model.apps = found
                model.loadingApps = false
                model.startSizing(found)
            }
        }
    }

    private func startObservingWorkspace() {
        guard !observing else { return }
        observing = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in UninstallerModel.shared.refreshRunning() }
            }
        }
    }

    func refreshRunning() {
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func isRunning(_ app: UninstallerApp) -> Bool { runningPaths.contains(app.url.standardizedFileURL.path) }

    /// Sizes are computed lazily in the background and published in small batches.
    private func startSizing(_ list: [UninstallerApp]) {
        sizeTask?.cancel()
        let targets = list.map { ($0.id, $0.url) }
        sizeTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, Int64).self) { group in
                var it = targets.makeIterator()
                var batch: [String: Int64] = [:]
                func addNext(_ g: inout TaskGroup<(String, Int64)>) -> Bool {
                    guard let (id, url) = it.next() else { return false }
                    g.addTask { (id, Task.isCancelled ? 0 : AppPaths.allocatedSize(of: url)) }
                    return true
                }
                for _ in 0..<3 { _ = addNext(&group) }
                while let (id, size) = await group.next() {
                    batch[id] = size
                    if batch.count >= 8 {
                        let b = batch; batch = [:]
                        await MainActor.run { UninstallerModel.shared.applySizes(b) }
                    }
                    if Task.isCancelled { group.cancelAll() } else { _ = addNext(&group) }
                }
                if !batch.isEmpty {
                    let b = batch
                    await MainActor.run { UninstallerModel.shared.applySizes(b) }
                }
            }
        }
    }

    private func applySizes(_ sizes: [String: Int64]) {
        for i in apps.indices {
            if let s = sizes[apps[i].id] { apps[i].size = s }
        }
    }

    var selectedApp: UninstallerApp? { apps.first { $0.id == selectedAppID } }

    var filteredApps: [UninstallerApp] {
        var list = apps
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        }
        switch filter {
        case .all: break
        case .unused:
            let days = UninstallerSettings.unusedDays
            list = list.filter { Self.isUnused($0, days: days) }
        case .large: list = list.filter { ($0.size ?? 0) >= 500_000_000 }
        }
        switch sort {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: list.sort { ($0.size ?? -1) > ($1.size ?? -1) }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    var totalAppsSize: Int64 { apps.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: - Deep scan

    func selectApp(_ id: String?) {
        guard id != selectedAppID else { return }
        selectedAppID = id
        mode = .uninstall
        scanSelected()
    }

    func scanSelected() {
        scanTask?.cancel()
        items = []
        selection = []
        guard let app = selectedApp, !app.isSystem else { scanning = false; return }
        scanning = true
        scanProgress = "Starting…"
        let installed = apps
        let includeSystem = UninstallerSettings.scanSystem
        scanTask = Task.detached(priority: .userInitiated) {
            let found = await UninstallerDeepScanner.scan(app: app, installed: installed, includeSystem: includeSystem) { text in
                Task { @MainActor in UninstallerModel.shared.scanProgress = text }
            }
            if Task.isCancelled { return }
            await MainActor.run { UninstallerModel.shared.finishScan(appID: app.id, found: found) }
        }
    }

    private func finishScan(appID: String, found: [UninstallerItem]) {
        guard selectedAppID == appID else { return }
        items = found
        scanning = false
        applyPreselection()
    }

    func setMode(_ m: Mode) {
        mode = m
        applyPreselection()
    }

    private func applyPreselection() {
        selection = Set(visibleItems(includeLow: false).filter { $0.confidence.isPreselected }.map(\.id))
    }

    func visibleItems(includeLow: Bool) -> [UninstallerItem] {
        items.filter { item in
            if item.confidence == .low && !includeLow { return false }
            if mode == .reset { return item.isUserDomain && item.category.isResettable && !item.isReceipt }
            return true
        }
    }

    func selectedItems(includeLow: Bool) -> [UninstallerItem] {
        visibleItems(includeLow: includeLow).filter { selection.contains($0.id) }
    }

    func toggle(_ id: String, on: Bool) {
        if on { selection.insert(id) } else { selection.remove(id) }
    }

    func setSelection(_ ids: [String], on: Bool) {
        if on { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    // MARK: - Drag & drop

    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        var handled = false
        for url in urls where url.pathExtension.lowercased() == "app" {
            handled = true
            tab = .applications
            if let existing = apps.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                selectApp(existing.id)
            } else if var app = UninstallerAppCatalog.makeApp(at: url, source: "Dropped") {
                apps.append(app)
                let target = app.url
                app.size = nil
                Task.detached(priority: .utility) {
                    let s = AppPaths.allocatedSize(of: target)
                    await MainActor.run { UninstallerModel.shared.applySizes([target.path: s]) }
                }
                selectApp(app.id)
            }
        }
        return handled
    }

    // MARK: - Hunter

    func startHunter() {
        guard hunterPhase != .scanning else { return }
        hunterPhase = .scanning
        hunterProgress = "Preparing…"
        groups = []
        brokenItems = []
        hunterSelection = []
        let existing = apps
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let includeSystem = UninstallerSettings.scanSystem
        hunterTask = Task.detached(priority: .userInitiated) {
            var list = existing
            if list.isEmpty { list = UninstallerAppCatalog.discover() }
            let result = await UninstallerHunter.scan(apps: list, runningIDs: running, includeSystem: includeSystem) { text in
                Task { @MainActor in UninstallerModel.shared.hunterProgress = text }
            }
            if Task.isCancelled {
                await MainActor.run { UninstallerModel.shared.hunterPhase = .idle }
                return
            }
            await MainActor.run { UninstallerModel.shared.finishHunter(result) }
        }
    }

    func cancelHunter() {
        hunterTask?.cancel()
        hunterPhase = .idle
    }

    private func finishHunter(_ r: UninstallerHunterResult) {
        groups = r.groups
        brokenItems = r.brokenItems
        hunterInstalledCount = r.installedAppCount
        hunterScannedEntries = r.scannedEntries
        lastHunterScan = Date()
        var sel = Set<String>()
        for g in r.groups { for i in g.items where i.confidence.isPreselected { sel.insert(i.id) } }
        for b in r.brokenItems where b.confidence.isPreselected { sel.insert(b.id) }
        hunterSelection = sel
        hunterPhase = .done
    }

    func visibleGroups(includeLow: Bool) -> [UninstallerGroup] {
        groups.filter { !$0.visibleItems(includeLow: includeLow).isEmpty }
    }

    func visibleBroken(includeLow: Bool) -> [UninstallerItem] {
        includeLow ? brokenItems : brokenItems.filter { $0.confidence != .low }
    }

    /// All distinct visible items of the hunter (groups + broken list share ids).
    func hunterVisibleItems(includeLow: Bool) -> [UninstallerItem] {
        var seen = Set<String>()
        var out: [UninstallerItem] = []
        for g in visibleGroups(includeLow: includeLow) {
            for i in g.visibleItems(includeLow: includeLow) where seen.insert(i.id).inserted { out.append(i) }
        }
        for b in visibleBroken(includeLow: includeLow) where seen.insert(b.id).inserted { out.append(b) }
        return out
    }

    func hunterSelectedItems(includeLow: Bool) -> [UninstallerItem] {
        hunterVisibleItems(includeLow: includeLow).filter { hunterSelection.contains($0.id) }
    }

    func toggleHunter(_ id: String, on: Bool) {
        if on { hunterSelection.insert(id) } else { hunterSelection.remove(id) }
    }

    func setHunter(_ ids: [String], on: Bool) {
        if on { hunterSelection.formUnion(ids) } else { hunterSelection.subtract(ids) }
    }

    func toggleExpanded(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }

    // MARK: - Removal

    func prepareAppRemoval(includeLow: Bool) {
        guard let app = selectedApp else { return }
        let chosen = selectedItems(includeLow: includeLow)
        guard !chosen.isEmpty else { return }
        let reset = mode == .reset
        plan = UninstallerRemovalPlan(source: reset ? .reset : .app,
                                      title: reset ? "Reset \(app.name)" : "Uninstall \(app.name)",
                                      items: chosen, app: app, appIsRunning: isRunning(app),
                                      deleteImmediately: UninstallerSettings.deleteImmediately)
        summary = nil
    }

    func prepareHunterRemoval(includeLow: Bool) {
        let chosen = hunterSelectedItems(includeLow: includeLow)
        guard !chosen.isEmpty else { return }
        plan = UninstallerRemovalPlan(source: .hunter, title: "Remove leftovers", items: chosen, app: nil,
                                      appIsRunning: false, deleteImmediately: UninstallerSettings.deleteImmediately)
        summary = nil
    }

    func dismissPlan() {
        guard !isRemoving else { return }
        plan = nil
        summary = nil
    }

    func executeRemoval() {
        guard let plan, !isRemoving else { return }
        isRemoving = true
        summary = nil
        removalProgress = "Preparing…"
        Task {
            var quitFailed = false
            if plan.source != .hunter, let app = plan.app, UninstallerQuitter.isRunning(app) {
                removalProgress = "Quitting \(app.name)…"
                quitFailed = !(await UninstallerQuitter.quit(app))
            }
            let items = plan.items
            let del = plan.deleteImmediately
            let result = await Task.detached(priority: .userInitiated) {
                await UninstallerRemover.run(items: items, deleteImmediately: del) { text in
                    Task { @MainActor in UninstallerModel.shared.removalProgress = text }
                }
            }.value
            finishRemoval(result, plan: plan, quitFailed: quitFailed)
        }
    }

    private func finishRemoval(_ result: UninstallerRemovalSummary, plan: UninstallerRemovalPlan, quitFailed: Bool) {
        var r = result
        if quitFailed, let app = plan.app {
            r.notes.append("\(app.name) did not quit; some files may reappear until it is closed.")
        }
        let gone = r.removedIDs
        items.removeAll { gone.contains($0.id) }
        selection.subtract(gone)
        hunterSelection.subtract(gone)
        brokenItems.removeAll { gone.contains($0.id) }
        groups = groups.compactMap { g in
            var ng = g
            ng.items.removeAll { gone.contains($0.id) }
            return ng.items.isEmpty ? nil : ng
        }
        if plan.source == .app, let app = plan.app, gone.contains(app.url.path) {
            apps.removeAll { $0.id == app.id }
            if selectedAppID == app.id { selectedAppID = nil; items = []; selection = [] }
        }
        // Bulk removal of unused apps: drop the removed app bundles from the list.
        if plan.source == .hunter, plan.items.contains(where: { $0.category == .application }) {
            apps.removeAll { gone.contains($0.id) }
            unusedSelection.subtract(gone)
            if let id = selectedAppID, gone.contains(id) { selectedAppID = nil; items = []; selection = [] }
        }
        summary = r
        isRemoving = false
        refreshRunning()
    }
}
