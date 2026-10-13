import SwiftUI

/// Toggle backed by a UserDefaults bool (default on).
private struct MenuBarPrefToggle: View {
    let title: String
    let symbol: String
    @AppStorage private var isOn: Bool

    init(title: String, symbol: String, key: String, defaultValue: Bool = true) {
        self.title = title
        self.symbol = symbol
        _isOn = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        Toggle(isOn: $isOn) { Label(title, systemImage: symbol) }
    }
}

/// Embed in the app Settings or a sidebar page.
struct MenuBarSettingsView: View {
    @AppStorage(MenuBarPrefs.iconStyleKey) private var styleRaw = MenuBarIconStyle.logo.rawValue
    @AppStorage(MenuBarPrefs.textMetricKey) private var metricRaw = MenuBarTextMetric.cpu.rawValue
    @AppStorage(MenuBarPrefs.columnsKey) private var columns = 2
    @State private var preview = NSImage()

    private var style: MenuBarIconStyle { MenuBarIconStyle(rawValue: styleRaw) ?? .logo }

    var body: some View {
        Form {
            Section("Menu bar icon") {
                HStack(spacing: 14) {
                    Image(nsImage: preview)
                        .renderingMode(style == .health ? .original : .template)
                        .frame(height: 18)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(style.detail).font(.callout).foregroundStyle(.secondary)
                }
                Picker("Style", selection: $styleRaw) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if style == .text {
                    Picker("Shows", selection: $metricRaw) {
                        ForEach(MenuBarTextMetric.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                if style.isLive {
                    Text("Live styles refresh every few seconds.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Popover sections") {
                ForEach(MenuBarSection.allCases) { s in
                    MenuBarPrefToggle(title: s.title, symbol: s.symbol, key: s.key)
                }
            }

            Section("Toggle tiles") {
                Picker("Layout", selection: $columns) {
                    Text("2 columns").tag(2)
                    Text("3 columns").tag(3)
                }
                .pickerStyle(.segmented)
                ForEach(MenuBarTile.allCases) { t in
                    MenuBarPrefToggle(title: t.title, symbol: t.symbol, key: t.key)
                }
                Text("Wi-Fi, Bluetooth and Mute tiles hide automatically when your Mac has no such control.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Quick actions") {
                ForEach(MenuBarQuickAction.allCases) { a in
                    MenuBarPrefToggle(title: a.title, symbol: a.symbol, key: a.key)
                }
                Text("Optimize and Free RAM appear only when the optimizer is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Dark Mode uses System Events, so macOS asks once to allow MacMaster to control it (Privacy & Security › Automation). Low Power Mode and Flush DNS ask for your administrator password each time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { renderPreview() }
        .onChange(of: styleRaw) { renderPreview() }
        .onChange(of: metricRaw) { renderPreview() }
    }

    @MainActor private func renderPreview() {
        preview = MenuBarIconRenderer.image(style: style)
    }
}
