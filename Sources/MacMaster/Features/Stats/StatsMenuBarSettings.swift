import SwiftUI

/// "Menu Bar" card in StatsView: toggles modules and picks styles.
struct StatsMenuBarSettingsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "menubar.rectangle", colors: Theme.Palette.stats, size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Menu Bar").font(.headline)
                    Text("Live stats next to the clock. Click any item for details.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 4) {
                ForEach(StatsModule.allCases) { StatsModuleToggleRow(module: $0) }
            }
            Divider()
            StatsBatteryMenuBarOptions()
        }
        .card()
    }
}

private struct StatsModuleToggleRow: View {
    let module: StatsModule
    @AppStorage private var on: Bool
    @AppStorage private var style: String

    init(module: StatsModule) {
        self.module = module
        _on = AppStorage(wrappedValue: module.defaultEnabled, module.key)
        _style = AppStorage(wrappedValue: StatsSettings.style(module).rawValue, module.styleKey)
    }

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: module.symbol, colors: module.colors, size: 24)
            Text(module.title)
            Spacer()
            if module.hasBarStyle, on {
                Picker("Style", selection: $style) {
                    ForEach(StatsBarStyle.styles(for: module)) { Text($0.title(for: module)).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 120)
            }
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }
}

private struct StatsBatteryMenuBarOptions: View {
    @AppStorage(StatsSettings.batteryGlyphKey) private var glyph = BatteryGlyphStyle.classic.rawValue
    @AppStorage(StatsSettings.batteryTimeKey) private var showTime = false
    @AppStorage(StatsModule.battery.key) private var batteryOn = false

    var body: some View {
        let r = BatteryMonitor.shared.reading
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery icon").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(BatteryGlyphStyle.allCases) { s in
                    Button { glyph = s.rawValue } label: {
                        VStack(spacing: 6) {
                            BatteryGlyph(percent: r.isPresent ? r.percent : 0.72, isCharging: r.isCharging, isPluggedIn: r.isPluggedIn,
                                         style: s, height: 14, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                                .frame(height: 20)
                            Text(s.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(glyph == s.rawValue ? Theme.Palette.stats[0].opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(glyph == s.rawValue ? Theme.Palette.stats[0] : Color.secondary.opacity(0.2), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) // whole card is the hit target
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("Show time remaining (Text styles)", isOn: $showTime)
                .toggleStyle(.switch)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Replace the system battery icon: enable the Battery item above, then hide the macOS one in System Settings → Control Center → Battery → “Show in Menu Bar”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !batteryOn {
                Button("Enable MacMaster battery icon") { batteryOn = true }.controlSize(.small)
            }
        }
    }
}
