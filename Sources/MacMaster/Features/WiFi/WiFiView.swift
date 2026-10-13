import SwiftUI

/// Sidebar page: everything the popover shows, plus settings and the icon style picker.
struct WiFiView: View {
    var body: some View {
        Page {
            PageHeader(title: "Wi-Fi",
                       subtitle: "Signal, speed, addresses and nearby networks, with a menu bar icon that can replace Apple's.",
                       symbol: "wifi", colors: Theme.Palette.blue)
            WiFiHeroCard()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.spacing) {
                    column { WiFiHotspotCard(); WiFiThroughputCard(); WiFiAppTrafficCard(limit: 8); WiFiLatencyCard(); WiFiSpeedTestCard() }
                    column { WiFiDetailsCard(); WiFiNetworksCard(limit: 20) }
                }
                .frame(minWidth: 760)
                column { WiFiHotspotCard(); WiFiThroughputCard(); WiFiAppTrafficCard(limit: 8); WiFiLatencyCard(); WiFiSpeedTestCard(); WiFiDetailsCard(); WiFiNetworksCard(limit: 20) }
            }
            WiFiAutomationsCard()
            WiFiSettingsCard()
        }
        .wifiPresence()
    }

    private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Settings

struct WiFiSettingsCard: View {
    @AppStorage(WiFiSettings.enabledKey) private var enabled = true
    @AppStorage(WiFiSettings.styleKey) private var styleRaw = WiFiIconStyle.classic.rawValue
    @AppStorage(WiFiSettings.intervalKey) private var interval = 3.0
    @AppStorage(WiFiSettings.publicIPKey) private var publicIP = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            GroupedSection("Menu bar", symbol: "menubar.rectangle",
                           footer: "While the popover is closed the icon reads the link on this interval and when Wi-Fi changes. Nothing else runs in the background.") {
                SettingsRow(title: "Show Wi-Fi in menu bar", symbol: "wifi", colors: Theme.Palette.blue) {
                    Toggle("", isOn: $enabled).toggleStyle(.mmSwitch).labelsHidden()
                }
                SettingsRow(title: "Update interval", subtitle: "How often the icon refreshes", symbol: "timer", colors: Theme.Palette.orange) {
                    Picker("", selection: $interval) {
                        ForEach(WiFiSettings.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                }
                SettingsRow(title: "Show public IP", subtitle: "Looks it up once when the popover opens (api.ipify.org)",
                            symbol: "globe", colors: Theme.Palette.teal) {
                    Toggle("", isOn: $publicIP).toggleStyle(.mmSwitch).labelsHidden()
                }
            }
            iconStyles
            GroupedSection("Replace Apple's Wi-Fi icon", symbol: "arrow.triangle.swap",
                           footer: "macOS doesn't let apps hide its icons. Open Control Center settings, find Wi-Fi and choose \"Don't Show in Menu Bar\".") {
                SettingsRow(title: "Hide Apple's Wi-Fi icon", subtitle: "Set Wi-Fi to \"Don't Show in Menu Bar\"",
                            symbol: "menubar.dock.rectangle", colors: Theme.Palette.gray) {
                    Button("Open Control Center Settings") { WiFiModel.openControlCenterSettings() }.buttonStyle(.mmSecondary)
                }
            }
        }
        .onChange(of: enabled) { _, _ in WiFiMenuBar.shared.update() }
        .onChange(of: styleRaw) { _, _ in WiFiMenuBar.shared.update() }
        .onChange(of: interval) { _, _ in WiFiModel.shared.reconfigure() }
        .onChange(of: publicIP) { _, _ in WiFiModel.shared.publicIPSettingChanged() }
    }

    private var iconStyles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon style").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(WiFiIconStyle.allCases) { style in
                    WiFiStyleTile(style: style, selected: styleRaw == style.rawValue) { styleRaw = style.rawValue }
                }
            }
        }
    }
}

private struct WiFiStyleTile: View {
    let style: WiFiIconStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    private let model = WiFiModel.shared

    private var sample: WiFiBarState {
        let l = model.link
        if l.isConnected {
            var s = WiFiBarState.make(link: l, style: style)
            if style == .ping, s.pingMs == nil { s.pingMs = 14 }
            return s
        }
        return WiFiBarState.sample(style: style)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                WiFiBarItemView(state: sample, dark: scheme == .dark, inkOverride: scheme == .dark ? .white : .black)
                    .frame(height: 28)
                VStack(spacing: 1) {
                    Text(style.title).font(.callout.weight(.medium))
                    Text(style.blurb).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Theme.hairline, lineWidth: selected ? 2 : 0.5))
        }
        .buttonStyle(.plain)
    }
}
