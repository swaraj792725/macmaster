import SwiftUI

struct ContentView: View {
    @AppStorage("mm.app.lastSection") private var stored = AppSection.dashboard.rawValue
    @State private var selection: AppSection? = .dashboard
    @State private var query = ""
    /// False while the window is closed or hidden for a while: the page is dropped so it stops rendering live data.
    @State private var windowShown = true

    private var groups: [(String, [AppSection])] {
        AppSection.groupOrder.compactMap { g in
            let items = AppSection.allCases.filter { $0.group == g && $0.matches(query) }
            return items.isEmpty ? nil : (g, items)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SidebarProfileCard { selection = .dashboard }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                    .selectionDisabled()

                ForEach(groups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items) { s in
                            SidebarRow(section: s).tag(s)
                        }
                    }
                }

                if groups.isEmpty {
                    Text("No results for “\(query)”")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                        .selectionDisabled()
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .large)
            .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 300)
            .safeAreaInset(edge: .top, spacing: 0) { SidebarSearchField(text: $query) }
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
        .onAppear { selection = AppSection(rawValue: stored) ?? .dashboard }
        .onChange(of: selection) { _, new in if let new { stored = new.rawValue } }
        .onReceive(NotificationCenter.default.publisher(for: .openSection)) { note in
            if let raw = note.object as? String, let s = AppSection(rawValue: raw) {
                query = ""
                selection = s
            }
        }
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

/// System Settings style search field pinned above the list.
private struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
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
            .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1.5 : 0.5))
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
