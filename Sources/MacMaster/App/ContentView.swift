import SwiftUI

struct ContentView: View {
    @AppStorage("mm.app.lastSection") private var stored = AppSection.dashboard.rawValue
    /// Comma-separated `AppGroup` raw values the user collapsed. Remembered across launches.
    @AppStorage("mm.app.collapsedGroups") private var collapsedRaw = ""
    @State private var selection: AppSection? = .dashboard
    @State private var query = ""
    @State private var highlighted = 0
    @State private var columns: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool
    /// False while the window is closed or hidden for a while: the page is dropped so it stops rendering live data.
    @State private var windowShown = true

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var results: [SearchEntry] { searching ? AppSearch.results(for: query) : [] }

    private func expanded(_ g: AppGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedRaw.split(separator: ",").contains(Substring(g.rawValue)) },
            set: { open in
                var set = Set(collapsedRaw.split(separator: ",").map(String.init))
                if open { set.remove(g.rawValue) } else { set.insert(g.rawValue) }
                collapsedRaw = set.sorted().joined(separator: ",")
            })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                SidebarProfileCard { selection = .dashboard }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                    .selectionDisabled()

                if searching {
                    SearchResultsSection(query: query, results: results, highlightedIndex: highlighted, onOpen: open)
                } else {
                    SidebarRow(section: .dashboard).tag(AppSection.dashboard)
                    ForEach(AppGroup.allCases.filter { $0 != .overview }) { group in
                        Section(isExpanded: expanded(group)) {
                            ForEach(group.sections) { s in
                                SidebarRow(section: s).tag(s)
                            }
                            if group == .setup { SidebarSettingsRow() }
                        } header: {
                            Text(group.title).help(group.blurb)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .large)
            .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 300)
            .safeAreaInset(edge: .top, spacing: 0) {
                SidebarSearchField(text: $query, focused: $searchFocused,
                                   onMove: { delta in
                                       let n = results.count
                                       if n > 0 { highlighted = min(max(highlighted + delta, 0), n - 1) }
                                   },
                                   onSubmit: { if highlighted < results.count { open(results[highlighted]) } })
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        } detail: {
            Group {
                if windowShown {
                    (selection ?? .dashboard).view.id(selection)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 640, minHeight: 520)
            .navigationTitle((selection ?? .dashboard).title)
        }
        .background(WindowVisibilityObserver(visible: $windowShown))
        .background {
            // ⌘F focuses the global search.
            Button("") { columns = .all; searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { selection = AppSection(rawValue: stored) ?? .dashboard }
        .onChange(of: selection) { _, new in if let new { stored = new.rawValue } }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .openSection)) { note in
            if let raw = note.object as? String, let s = AppSection(rawValue: raw) {
                query = ""
                selection = s
            }
        }
    }

    /// Jump to a search result: page, tab, then scroll + highlight (see `AppSearchRouter`).
    private func open(_ entry: SearchEntry) {
        query = ""
        searchFocused = false
        if entry.opensAppSettings {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return
        }
        if entry.anchor != nil || entry.tab != nil {
            AppSearchRouter.shared.request(anchor: entry.anchor, tab: entry.tab)
        }
        selection = entry.section
    }
}

// MARK: - Sidebar pieces

private struct SidebarRow: View {
    let section: AppSection
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: section.symbol, colors: section.colors, size: 24)
            Text(section.title).font(.body)
        }
        .padding(.vertical, 2)
        .help(section.blurb)
    }
}

/// Sidebar button that opens the app's Settings window (launch at login, Dock icon, sample interval...).
private struct SidebarSettingsRow: View {
    var body: some View {
        Button {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: "gearshape.fill", colors: Theme.Palette.gray, size: 24)
                Text("App Settings").font(.body)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .help("Launch at login, Dock icon, menu bar icon and sampling")
    }
}

/// System Settings style search field pinned above the list.
private struct SidebarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search features and settings", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                .onKeyPress(.downArrow) { onMove(1); return .handled }
                .onKeyPress(.upArrow) { onMove(-1); return .handled }
                .onExitCommand { text = ""; focused.wrappedValue = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.6) : Theme.hairline, lineWidth: focused.wrappedValue ? 1.5 : 0.5))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }
}

/// "This Mac" card at the top of the sidebar (like the Apple Account card in System Settings).
private struct SidebarProfileCard: View {
    var action: () -> Void
    private let info = SystemInfo.current
    @State private var battery = BatteryMonitor.shared

    var body: some View {
        let symbol = MacIdentity.symbol(modelIdentifier: info.modelIdentifier, hasBattery: battery.reading.isPresent)
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, colors: Theme.Palette.gray, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.hostName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(info.chip.replacingOccurrences(of: "Apple ", with: ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(info.osVersion).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("This Mac")
    }
}

/// Live CPU / RAM mini readout pinned to the bottom of the sidebar.
private struct SidebarFooter: View {
    @State private var monitor = SystemMonitor.shared
    var body: some View {
        VStack(spacing: 7) {
            row("CPU", "cpu", monitor.cpu.total, Theme.Palette.cpu)
            row("RAM", "memorychip", monitor.memory.usedFraction, Theme.Palette.memory)
        }
        .padding(10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
    }

    private func row(_ label: String, _ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: SymbolKit.resolve(symbol))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            CapsuleBar(fraction: value, color: color, height: 5)
            Text(Fmt.percent(value))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 34, alignment: .trailing)
        }
    }
}
