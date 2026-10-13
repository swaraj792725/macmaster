import SwiftUI
import UniformTypeIdentifiers

struct UninstallerView: View {
    @State private var model = UninstallerModel.shared
    @AppStorage(UninstallerSettings.deleteKey) private var deleteImmediately = false
    @AppStorage(UninstallerSettings.includeLowKey) private var includeLow = false
    @AppStorage(UninstallerSettings.scanSystemKey) private var scanSystem = true
    @AppStorage(UninstallerSettings.watchDeletionsKey) private var watchDeletions = true
    @State private var showSettings = false
    @State private var dropTargeted = false

    init() {}

    var body: some View {
        VStack(spacing: 14) {
            PageHeader(title: "Uninstaller",
                       subtitle: "Remove apps completely – and hunt down what other uninstallers leave behind.",
                       symbol: "trash.square.fill", colors: Theme.Palette.uninstaller) {
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.bordered).help("Uninstaller settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
            }
            PermissionBanner(permission: .fullDiskAccess,
                             reason: "Without Full Disk Access, protected folders (Mail, Safari, some containers) can't be scanned and leftovers may be missed.")
            Picker("", selection: $model.tab) {
                ForEach(UninstallerModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                switch model.tab {
                case .applications: UninstallerAppsView(model: model)
                case .hunter: UninstallerHunterView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.pagePadding)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Label("Drop an app to uninstall it", systemImage: "arrow.down.app.fill").font(.title3.weight(.semibold)))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.handleDrop(urls) } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.dismissPlan() } })) {
            UninstallerRemovalSheet(model: model)
        }
        .onAppear { model.loadApps() }
        .onSearchTab { raw in
            if raw == "settings" { showSettings = true }
            else if let t = UninstallerModel.Tab(rawValue: raw) { model.tab = t }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstaller settings").font(.headline)
            Toggle("Delete immediately (skip Trash)", isOn: $deleteImmediately)
            Text("Off by default. When on, removed files can't be recovered.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show low-confidence matches", isOn: $includeLow)
            Text("Low-confidence items are never ticked automatically.").font(.caption).foregroundStyle(.secondary)
            Toggle("Scan system locations (/Library)", isOn: $scanSystem)
            Text("Includes launch daemons, helper tools and receipts. Removing them asks for your password.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Offer to clean up after deleted apps", isOn: $watchDeletions)
                .onChange(of: watchDeletions) { _, on in
                    if on { UninstallerDeletionWatcher.shared.start() } else { UninstallerDeletionWatcher.shared.stop() }
                }
            Text("When you move an app to the Trash, a small window offers to remove its leftover files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 320)
    }
}
