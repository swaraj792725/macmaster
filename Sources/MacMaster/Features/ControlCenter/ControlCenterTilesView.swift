import SwiftUI
import AppKit

/// The Control Center tile grid, embedded in MacMaster's dropdown. Order, size and visibility come from
/// `ControlCenterSettings`; `editing` turns on drag-to-reorder, resize and hide badges.
struct ControlCenterTilesView: View {
    @Binding var editing: Bool

    private let model = ControlCenterModel.shared
    private let audio = ControlCenterAudio.shared
    private let settings = ControlCenterSettings.shared
    private let awake = ToolsKeepAwake.shared
    private let engine = KeyboardEngine.shared
    private let menu = MenuBarModel.shared

    /// Grid height for the current layout, so the dropdown can open at roughly the right size.
    @MainActor
    static func estimatedHeight() -> CGFloat {
        let tiles = ControlCenterSettings.shared.visibleTiles.filter { ControlCenterModel.shared.isAvailable($0) }
        return ControlCenterPacker.pack(tiles).height
    }

    private var tiles: [ControlCenterTile] {
        editing ? settings.visibleTiles : settings.visibleTiles.filter { model.isAvailable($0) }
    }

    var body: some View {
        VStack(spacing: 10) {
            if let m = model.message { banner(m) }
            if tiles.isEmpty {
                emptyState
            } else {
                ControlCenterGrid(tiles: tiles, editing: editing) { t, size in tileContent(t, size) }
            }
            if editing { editTray }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.message)
        .onAppear { model.opened(); menu.refresh() }
        .onDisappear { model.closed() }
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
        case .hideDesktop: return TileState(on: menu.isOn(.hideDesktop), subtitle: menu.isOn(.hideDesktop) ? "Hidden" : "Shown", action: { menu.toggle(.hideDesktop) })
        case .hiddenFiles: return TileState(on: menu.isOn(.hiddenFiles), subtitle: menu.isOn(.hiddenFiles) ? "Visible" : "Hidden", action: { menu.toggle(.hiddenFiles) })
        case .smoothScroll: return TileState(on: menu.isOn(.smoothScroll), subtitle: menu.isOn(.smoothScroll) ? "On" : "Off", action: { menu.toggle(.smoothScroll) })
        case .windowSwitcher: return TileState(on: menu.isOn(.windowSwitcher), subtitle: menu.isOn(.windowSwitcher) ? "On" : "Off", action: { menu.toggle(.windowSwitcher) })
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
}
