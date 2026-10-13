import SwiftUI

struct UninstallerHunterView: View {
    @Bindable var model: UninstallerModel
    @AppStorage(UninstallerSettings.includeLowKey) private var includeLow = false

    var body: some View {
        switch model.hunterPhase {
        case .idle: hero
        case .scanning: scanning
        case .done: results
        }
    }

    // MARK: Idle / scanning

    private var hero: some View {
        VStack(spacing: 16) {
            IconTile(symbol: "sparkle.magnifyingglass", colors: Theme.Palette.uninstaller, size: 76)
            Text("Hunt for leftovers").font(.title.weight(.bold))
            Text("Finds files left behind by apps you already deleted – caches, preferences, launch agents, updaters like Keystone and GoogleUpdater, and developer browsers from puppeteer, playwright and Chrome for Testing.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button { model.startHunter() } label: {
                Label("Scan for leftovers", systemImage: "magnifyingglass").font(.headline).padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let d = model.lastHunterScan {
                Text("Last scan \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(padding: 30)
    }

    private var scanning: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass").font(.system(size: 44))
                .foregroundStyle(Theme.gradient(Theme.Palette.uninstaller))
                .symbolEffect(.pulse, options: .repeating)
            Text("Scanning…").font(.title3.weight(.semibold))
            ProgressView().progressViewStyle(.linear).frame(maxWidth: 360)
            Text(model.hunterProgress).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Cancel") { model.cancelHunter() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(padding: 30)
    }

    // MARK: Results

    private var results: some View {
        let groups = model.visibleGroups(includeLow: includeLow)
        let app = groups.filter { !$0.isDeveloper }
        let dev = groups.filter { $0.isDeveloper }
        let broken = model.visibleBroken(includeLow: includeLow)
        let total = groups.reduce(Int64(0)) { $0 + $1.visibleItems(includeLow: includeLow).reduce(0) { $0 + $1.size } }
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Leftover groups", value: "\(groups.count)", caption: "From removed apps and dev tools",
                         symbol: "square.stack.3d.up.fill", colors: Theme.Palette.uninstaller)
                StatTile(title: "Reclaimable", value: Fmt.bytes(total), caption: "Across all groups",
                         symbol: "internaldrive.fill", colors: Theme.Palette.cleaner)
                StatTile(title: "Broken launch items", value: "\(broken.count)", caption: "Executable is missing",
                         symbol: "bolt.slash.fill", colors: Theme.Palette.tools)
                StatTile(title: "Checked", value: "\(model.hunterScannedEntries)", caption: "\(model.hunterInstalledCount) installed apps known",
                         symbol: "checklist", colors: Theme.Palette.stats)
            }
            if groups.isEmpty && broken.isEmpty {
                EmptyStateView(symbol: "sparkles", title: "Your Mac is clean", message: "No leftovers from removed apps were found.")
                    .frame(maxHeight: .infinity).card()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !app.isEmpty { sectionBlock("Removed apps", "trash.slash.fill", app) }
                        if !dev.isEmpty { sectionBlock("Developer leftovers", "hammer.fill", dev) }
                        if !broken.isEmpty { brokenBlock(broken) }
                    }
                    .padding(.bottom, 4)
                }
            }
            footer
        }
    }

    private func sectionBlock(_ title: String, _ symbol: String, _ gs: [UninstallerGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title, symbol: symbol)
            ForEach(gs) { groupCard($0) }
        }
    }

    private func groupCard(_ g: UninstallerGroup) -> some View {
        let rows = g.visibleItems(includeLow: includeLow)
        let ids = rows.map(\.id)
        let on = ids.filter { model.hunterSelection.contains($0) }.count
        let state: UninstallerTriCheck.State = on == 0 ? .off : (on == ids.count ? .on : .mixed)
        let expanded = model.expandedGroups.contains(g.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                UninstallerTriCheck(state: state) { model.setHunter(ids, on: state != .on) }
                IconTile(symbol: g.symbol, colors: g.isDeveloper ? Theme.Palette.tools : Theme.Palette.uninstaller, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.name).font(.headline)
                    Text("\(g.subtitle.isEmpty ? "" : g.subtitle + " · ")\(rows.count) item\(rows.count == 1 ? "" : "s")"
                         + (g.lastModified.map { " · modified \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                UninstallerConfidencePill(confidence: g.maxConfidence)
                Text(Fmt.bytes(rows.reduce(0) { $0 + $1.size })).font(.headline).monospacedDigit()
                Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary).animation(.smooth(duration: 0.2), value: expanded)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { model.toggleExpanded(g.id) } }
            if expanded {
                Divider()
                ForEach(rows) { item in
                    UninstallerItemRow(item: item, isOn: Binding(get: { model.hunterSelection.contains(item.id) },
                                                                 set: { model.toggleHunter(item.id, on: $0) }),
                                       showModified: true)
                    Divider()
                }
            }
        }
        .card(padding: 12)
    }

    private func brokenBlock(_ items: [UninstallerItem]) -> some View {
        let ids = items.map(\.id)
        let on = ids.filter { model.hunterSelection.contains($0) }.count
        let state: UninstallerTriCheck.State = on == 0 ? .off : (on == ids.count ? .on : .mixed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Broken login items & launch agents", symbol: "bolt.slash.fill")
                Spacer()
                UninstallerTriCheck(state: state) { model.setHunter(ids, on: state != .on) }
            }
            Text("These start at login but their program no longer exists. They will be unloaded and removed.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    UninstallerItemRow(item: item, isOn: Binding(get: { model.hunterSelection.contains(item.id) },
                                                                 set: { model.toggleHunter(item.id, on: $0) }),
                                       showModified: true)
                    Divider()
                }
            }
            .card(padding: 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let chosen = model.hunterSelectedItems(includeLow: includeLow)
        let size = chosen.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 12) {
            Button { model.startHunter() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            Spacer()
            Text("\(chosen.count) selected").font(.callout).foregroundStyle(.secondary)
            Button {
                model.prepareHunterRemoval(includeLow: includeLow)
            } label: {
                Label("Remove selected (\(Fmt.bytes(size)))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .disabled(chosen.isEmpty)
        }
        .card(padding: 12)
    }
}
