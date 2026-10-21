import SwiftUI

// MARK: - Settings

extension UninstallerSettings {
    static let unusedDaysKey = "mm.uninstaller.unusedDays"
    static let unusedDayChoices = [30, 60, 90, 180]

    /// Apps not opened for this many days count as unused. Default 90.
    static var unusedDays: Int {
        let v = UserDefaults.standard.integer(forKey: unusedDaysKey)
        return unusedDayChoices.contains(v) ? v : 90
    }
}

// MARK: - Model helpers

extension UninstallerModel {
    /// Apps that can be bulk-removed: unused, not a system app, not running.
    var unusedApps: [UninstallerApp] {
        let days = UninstallerSettings.unusedDays
        return apps.filter { Self.isUnused($0, days: days) }
    }

    static func isUnused(_ app: UninstallerApp, days: Int) -> Bool {
        !app.isSystem && (app.daysSinceUsed ?? Int.max) >= days
    }

    /// Apps in the unused list that can be ticked (running ones are skipped so nothing is force-quit).
    var removableUnusedApps: [UninstallerApp] { filteredApps.filter { !isRunning($0) } }

    var unusedReclaimable: Int64 { unusedApps.reduce(0) { $0 + ($1.size ?? 0) } }

    var unusedSelectedApps: [UninstallerApp] {
        apps.filter { unusedSelection.contains($0.id) && !$0.isSystem }
    }

    func toggleUnused(_ app: UninstallerApp) {
        if unusedSelection.contains(app.id) { unusedSelection.remove(app.id) } else { unusedSelection.insert(app.id) }
    }

    func selectAllUnused() { unusedSelection = Set(removableUnusedApps.map(\.id)) }

    /// Builds one confirmation plan for every ticked app. Uses the existing removal engine, so the
    /// confirmation sheet, Trash and admin handling behave exactly as for leftovers.
    func prepareUnusedRemoval() {
        let chosen = unusedSelectedApps.filter { !isRunning($0) }
        guard !chosen.isEmpty else { return }
        let days = UninstallerSettings.unusedDays
        let items = chosen.map {
            UninstallerItems.make(url: $0.url, category: .application, confidence: .high,
                                  reason: "Not opened for \(days)+ days")
        }
        plan = UninstallerRemovalPlan(source: .hunter, title: "Remove unused apps", items: items, app: nil,
                                      appIsRunning: false, deleteImmediately: UninstallerSettings.deleteImmediately)
        summary = nil
    }
}

// MARK: - Bar above the app list

struct UninstallerUnusedBar: View {
    @Bindable var model: UninstallerModel
    @AppStorage(UninstallerSettings.unusedDaysKey) private var days = 90

    var body: some View {
        let picked = model.unusedSelectedApps
        let pickedSize = picked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Unused for", selection: $days) {
                    ForEach(UninstallerSettings.unusedDayChoices, id: \.self) { Text("\($0)+ days").tag($0) }
                }
                .controlSize(.small).fixedSize()
                Spacer()
                Text("\(Fmt.bytes(model.unusedReclaimable)) can be freed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Select all") { model.selectAllUnused() }
                    .controlSize(.small).disabled(model.removableUnusedApps.isEmpty)
                Button("Clear") { model.unusedSelection = [] }
                    .controlSize(.small).disabled(picked.isEmpty)
                Spacer()
                Button(role: .destructive) { model.prepareUnusedRemoval() } label: {
                    Text(picked.isEmpty ? "Remove selected" : "Remove \(picked.count) · \(Fmt.bytes(pickedSize))")
                }
                .controlSize(.small).disabled(picked.isEmpty || model.isRemoving)
            }
        }
        .onChange(of: days) { _, _ in
            // Keep ticks only for apps that are still in the list.
            model.unusedSelection.formIntersection(Set(model.filteredApps.map(\.id)))
        }
    }
}

// MARK: - Row with checkbox

struct UninstallerUnusedRow: View {
    @Bindable var model: UninstallerModel
    let app: UninstallerApp

    var body: some View {
        let running = model.isRunning(app)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.unusedSelection.contains(app.id) && !running },
                                     set: { _ in model.toggleUnused(app) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(running)
                .help(running ? "Quit this app first" : "Select for removal")
            UninstallerAppRow(app: app, running: running)
        }
    }
}
