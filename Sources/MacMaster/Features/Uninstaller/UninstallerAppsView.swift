import SwiftUI

struct UninstallerAppsView: View {
    @Bindable var model: UninstallerModel
    @AppStorage(UninstallerSettings.includeLowKey) private var includeLow = false

    var body: some View {
        HStack(spacing: 14) {
            list.frame(width: 320)
            detail
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Picker("Filter", selection: $model.filter) {
                    ForEach(UninstallerModel.FilterKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small)
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(UninstallerModel.SortKey.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort: \(model.sort.rawValue)", systemImage: "arrow.up.arrow.down") }
                .controlSize(.small).menuStyle(.borderlessButton).fixedSize()
            }

            let apps = model.filteredApps
            if model.loadingApps && model.apps.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text("Finding apps…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                EmptyStateView(symbol: "app.dashed", title: "No apps", message: "Nothing matches this search or filter.")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedAppID }, set: { model.selectApp($0) })) {
                    ForEach(apps) { app in
                        UninstallerAppRow(app: app, running: model.isRunning(app)).tag(app.id)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(Fmt.count(model.apps.count, "app")) · \(Fmt.bytes(model.totalAppsSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.loadApps(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reload apps")
            }
        }
        .card(padding: 12)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                appHeader(app)
                Divider().padding(.vertical, 10)
                if app.isSystem {
                    EmptyStateView(symbol: "lock.shield.fill", title: "Protected system app",
                                   message: "\(app.name) is part of macOS and can't be removed.")
                        .frame(maxHeight: .infinity)
                } else {
                    content(app)
                    footer(app)
                }
            }
            .card(padding: 16)
        } else {
            EmptyStateView(symbol: "arrow.down.app.fill", title: "Select an app",
                           message: "Pick an app on the left, or drop an .app here, to find every file it left on your Mac.")
                .frame(maxHeight: .infinity)
                .card()
        }
    }

    private func appHeader(_ app: UninstallerApp) -> some View {
        HStack(spacing: 14) {
            UninstallerAppIcon(url: app.url, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(app.name).font(.title2.weight(.bold))
                    if model.isRunning(app) { StatusPill(text: "Running", color: .green) }
                }
                Text(app.bundleID + (app.version.isEmpty ? "" : " · v\(app.version)"))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text(UninstallerPaths.tilde(app.url.path)).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.size.map { Fmt.bytes($0) } ?? "…").font(.title3.weight(.semibold)).monospacedDigit()
                Text(app.lastUsed.map { "Last used \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Never opened")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func content(_ app: UninstallerApp) -> some View {
        Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            ForEach(UninstallerModel.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().padding(.bottom, 8)

        if model.scanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Scanning for related files…").font(.headline)
                Text(model.scanProgress).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let visible = model.visibleItems(includeLow: includeLow)
            if visible.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing found",
                               message: model.mode == .reset ? "No user data found to reset." : "No related files found.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                        ForEach(UninstallerCategory.allCases) { cat in
                            let rows = visible.filter { $0.category == cat }
                            if !rows.isEmpty { section(cat, rows) }
                        }
                    }
                }
            }
        }
    }

    private func section(_ cat: UninstallerCategory, _ rows: [UninstallerItem]) -> some View {
        let ids = rows.map(\.id)
        let on = ids.filter { model.selection.contains($0) }.count
        let state: UninstallerTriCheck.State = on == 0 ? .off : (on == ids.count ? .on : .mixed)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                UninstallerTriCheck(state: state) { model.setSelection(ids, on: state != .on) }
                SectionTitle(text: cat.title, symbol: cat.symbol)
                Text("\(rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.bytes(rows.reduce(0) { $0 + $1.size })).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(rows) { item in
                UninstallerItemRow(item: item, isOn: Binding(get: { model.selection.contains(item.id) },
                                                             set: { model.toggle(item.id, on: $0) }))
                Divider()
            }
        }
    }

    private func footer(_ app: UninstallerApp) -> some View {
        let chosen = model.selectedItems(includeLow: includeLow)
        let size = chosen.reduce(Int64(0)) { $0 + $1.size }
        let reset = model.mode == .reset
        return VStack(spacing: 0) {
            Divider().padding(.bottom, 10)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(chosen.count) selected · \(Fmt.bytes(size))").font(.headline).monospacedDigit()
                    Text(reset ? "Keeps the app, removes its data." : "Items go to the Trash unless set otherwise.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.scanSelected() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
                Button {
                    model.prepareAppRemoval(includeLow: includeLow)
                } label: {
                    Label(reset ? "Reset app" : "Uninstall", systemImage: reset ? "arrow.counterclockwise" : "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(chosen.isEmpty || model.scanning)
            }
        }
    }
}
