import SwiftUI
import AppKit

/// The Control Center popover: header, flexible tile grid, footer. The pencil in the header switches to edit mode.
struct ControlCenterPopoverView: View {
    static let width: CGFloat = ControlCenterMetrics.width

    private let model = ControlCenterModel.shared
    private let audio = ControlCenterAudio.shared
    private let settings = ControlCenterSettings.shared
    private let awake = ToolsKeepAwake.shared
    private let engine = KeyboardEngine.shared
    private let battery = BatteryMonitor.shared

    @State private var editing = false

    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 28

    /// Height before SwiftUI measures the real content, so the popover doesn't open at the wrong size.
    static func estimatedHeight() -> CGFloat {
        let tiles = ControlCenterSettings.shared.visibleTiles.filter { ControlCenterModel.shared.isAvailable($0) }
        let grid = ControlCenterPacker.pack(tiles).height
        return grid + headerHeight + footerHeight + 2 * 10 + 2 * ControlCenterMetrics.padding
    }

    private var tiles: [ControlCenterTile] {
        editing ? settings.visibleTiles : settings.visibleTiles.filter { model.isAvailable($0) }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            if let m = model.message { banner(m) }
            if tiles.isEmpty {
                emptyState
            } else {
                ControlCenterGrid(tiles: tiles, editing: editing) { t, size in tileContent(t, size) }
            }
            if editing { editTray }
            footer
        }
        .padding(ControlCenterMetrics.padding)
        .frame(width: Self.width)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4))
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.message)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: editing)
        .onAppear { battery.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(editing ? "Edit layout" : "Control Center")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if editing {
                Menu {
                    ForEach(ControlCenterPreset.allCases) { p in
                        Button { withAnimation { settings.apply(p) } } label: { Label(p.title, systemImage: p.symbol) }
                    }
                    Divider()
                    Button("Reset layout") { withAnimation { settings.resetLayout() } }
                } label: {
                    Label("Presets", systemImage: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { editing = false } label: { Text("Done").fontWeight(.semibold) }
                    .buttonStyle(.mmGhost)
            } else {
                Button { editing = true } label: {
                    Image(systemName: "slider.horizontal.below.square.and.square.filled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit tiles: reorder, resize, hide")
            }
        }
        .frame(height: Self.headerHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.dashed").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("No tiles to show").font(.system(size: 12, weight: .medium))
            Button("Edit") { editing = true }.buttonStyle(.mmSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    /// Hidden tiles, one tap to bring each back.
    private var editTray: some View {
        let hidden = settings.hiddenList
        return VStack(alignment: .leading, spacing: 6) {
            Text("Hidden").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            if hidden.isEmpty {
                Text("Every tile is showing. Use the minus button on a tile to hide it.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(hidden) { t in
                        Button { withAnimation { settings.setVisible(t, true) } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                Image(systemName: t.symbol).font(.system(size: 10.5))
                                Text(t.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Drag tiles to reorder. The blue badge changes a tile's size.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tile content

    @ViewBuilder
    private func tileContent(_ t: ControlCenterTile, _ size: ControlCenterTileSize) -> some View {
        switch t {
        case .brightness:
            ControlCenterSlider(
                value: Binding(get: { Double(model.brightness ?? 0) }, set: { model.setBrightness(Float($0)) }),
                symbol: ControlCenterTile.brightness.symbol, colors: t.colors, label: "Display")
        case .keyboardBrightness:
            ControlCenterSlider(
                value: Binding(get: { Double(model.keyboardBrightness ?? 0) }, set: { model.setKeyboardBrightness(Float($0)) }),
                symbol: ControlCenterTile.keyboardBrightness.symbol, colors: t.colors, label: "Keyboard")
        case .volume:
            volumeRow
        case .nowPlaying:
            ControlCenterNowPlayingTile(size: size)
        case .audioDevices:
            ControlCenterAudioDevicesTile(size: size)
        case .bluetoothDevices:
            ControlCenterBluetoothDevicesTile(size: size)
        case .keepAwake where size == .large:
            ControlCenterKeepAwakeLarge()
        default:
            let s = state(t)
            ControlCenterTileView(tile: t, size: size, isOn: s.on, subtitle: s.subtitle,
                                  title: s.title, symbol: s.symbol, colors: s.colors, action: s.action)
                .contextMenu { if t == .keepAwake { keepAwakeMenu } }
        }
    }

    @ViewBuilder
    private var keepAwakeMenu: some View {
        ForEach([ToolsAwakeDuration.m15, .h1, .h2, .indefinite]) { d in
            Button(d == .indefinite ? "Until I turn it off" : "For \(d.title)") { awake.begin(d) }
        }
        if awake.isActive || awake.isArmed {
            Divider()
            Button("Turn off") { awake.stop() }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 6) {
            ControlCenterSlider(
                value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }),
                symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                colors: ControlCenterTile.volume.colors, dimmed: audio.muted, variable: !audio.muted,
                label: audio.currentName)
            if audio.hasMute {
                Button { audio.toggleMute() } label: {
                    Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(audio.muted ? Color.white : Color.primary.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .background(audio.muted ? AnyShapeStyle(Theme.verticalGradient(Theme.Palette.red))
                                                : AnyShapeStyle(Color.primary.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(audio.muted ? "Unmute" : "Mute")
            }
        }
    }

    // MARK: Tile state

    private struct TileState {
        var on: Bool
        var subtitle: String
        var action: () -> Void
        var title: String?
        var symbol: String?
        var colors: [Color]?
    }

    private func state(_ t: ControlCenterTile) -> TileState {
        func onOff(_ v: Bool?) -> String { v == nil ? "Unavailable" : (v! ? "On" : "Off") }
        switch t {
        case .wifi: return TileState(on: model.wifi == true, subtitle: onOff(model.wifi), action: model.toggleWifi)
        case .bluetooth:
            let sub = model.bluetoothNeedsPermission ? "Allow access" : (model.bluetooth == nil ? "Open settings" : onOff(model.bluetooth))
            return TileState(on: model.bluetooth == true, subtitle: sub, action: model.toggleBluetooth)
        case .darkMode:
            return TileState(on: model.darkMode, subtitle: model.darkMode ? "Dark" : "Light", action: model.toggleDarkMode)
        case .keepAwake:
            let sub = awake.isActive ? (awake.remaining.map { Fmt.duration($0) } ?? "On") : "Off"
            return TileState(on: awake.isActive || awake.isArmed, subtitle: sub, action: { awake.toggle() })
        case .focus:
            return TileState(on: false, subtitle: settings.focusShortcut.isEmpty ? "Open settings" : "Run shortcut", action: model.focus)
        case .nightShift: return TileState(on: model.nightShift == true, subtitle: onOff(model.nightShift), action: model.toggleNightShift)
        case .lowPower: return TileState(on: model.lowPower, subtitle: model.lowPower ? "On" : "Off", action: model.toggleLowPower)
        case .lockScreen: return TileState(on: false, subtitle: "Lock now", action: model.lockScreen)
        case .screenshot: return TileState(on: false, subtitle: "Capture", action: model.screenshot)
        case .airDrop: return TileState(on: false, subtitle: "Open", action: model.airDrop)
        case .cleaning:
            return TileState(on: engine.cleaningActive, subtitle: engine.cleaningActive ? "Active" : "Start", action: model.toggleCleaning)
        case .shelf:
            return TileState(on: DropShelf.shared.isVisible, subtitle: DropShelf.shared.isVisible ? "Shown" : "Hidden", action: model.toggleShelf)
        case .micMute:
            return TileState(on: audio.micMuted, subtitle: audio.micMuted ? "Muted" : "Live", action: audio.toggleMic,
                             title: "Mic", symbol: audio.micMuted ? "mic.slash.fill" : "mic.fill")
        default:
            return TileState(on: false, subtitle: "", action: {})
        }
    }

    // MARK: Pieces

    private func banner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if battery.reading.isPresent {
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                    Text(Fmt.percent(battery.reading.percent)).monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.openMacMaster() } label: { Label("MacMaster", systemImage: "square.grid.2x2.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.mmGhost)
            Button { model.openSystemSettings() } label: { Label("Settings", systemImage: "gearshape.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.mmGhost)
        }
        .font(.caption)
        .frame(height: Self.footerHeight)
    }

    private var batterySymbol: String {
        let r = battery.reading
        if r.isCharging || r.isPluggedIn { return SymbolKit.firstAvailable(["battery.100percent.bolt", "bolt.fill"]) }
        switch r.percent {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
