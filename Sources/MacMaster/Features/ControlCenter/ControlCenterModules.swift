import SwiftUI
import AppKit

// MARK: - Now Playing

struct ControlCenterNowPlayingTile: View {
    let size: ControlCenterTileSize
    private let np = ControlCenterNowPlaying.shared

    var body: some View {
        Group {
            if let i = np.info {
                switch size {
                case .large, .panel: large(i)
                case .banner: banner(i, controls: true)
                default: banner(i, controls: false)
                }
            } else {
                Placeholder(symbol: "play.circle", text: "Nothing playing")
            }
        }
        .ccSurface()
    }

    private func art(_ i: ControlCenterNowPlayingInfo, _ d: CGFloat) -> some View {
        Group {
            if let a = i.artwork {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: ControlCenterTile.nowPlaying.colors, startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: d * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: d, height: d)
        .clipShape(RoundedRectangle(cornerRadius: d * 0.2, style: .continuous))
    }

    private func button(_ symbol: String, _ cmd: ControlCenterNowPlaying.Command, _ d: CGFloat = 28, big: Bool = false) -> some View {
        Button { np.send(cmd) } label: {
            Image(systemName: symbol)
                .font(.system(size: big ? 15 : 12, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: d, height: d)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func texts(_ i: ControlCenterNowPlayingInfo, _ big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(i.title).font(.system(size: big ? 13 : 12, weight: .semibold)).lineLimit(1)
            Text(i.artist.isEmpty ? i.album : i.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func banner(_ i: ControlCenterNowPlayingInfo, controls: Bool) -> some View {
        HStack(spacing: 10) {
            art(i, 52)
            texts(i, true)
            Spacer(minLength: 0)
            if controls {
                button("backward.fill", .previous)
                button(i.playing ? "pause.fill" : "play.fill", .toggle, 32, big: true)
                button("forward.fill", .next)
            } else {
                button(i.playing ? "pause.fill" : "play.fill", .toggle, 32, big: true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func large(_ i: ControlCenterNowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            art(i, size == .panel ? 70 : 64)
            texts(i, true)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                button("backward.fill", .previous)
                button(i.playing ? "pause.fill" : "play.fill", .toggle, 34, big: true)
                button("forward.fill", .next)
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Audio devices

struct ControlCenterAudioDevicesTile: View {
    let size: ControlCenterTileSize
    private let audio = ControlCenterAudio.shared

    var body: some View {
        Group {
            if size == .panel { panel } else { compact }
        }
        .ccSurface()
    }

    /// Two rows: pick the output, pick the input. Banner adds a volume slider to each.
    private var compact: some View {
        VStack(spacing: 4) {
            row(input: false)
            row(input: true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(input: Bool) -> some View {
        let list = input ? audio.inputs : audio.devices
        let current = input ? audio.inputID : audio.currentID
        let cur = list.first { $0.id == current }
        return HStack(spacing: 8) {
            Menu {
                ForEach(list) { d in
                    Button {
                        if input { audio.selectInput(d) } else { audio.select(d) }
                    } label: {
                        if d.id == current { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
                Divider()
                Button("Sound Settings…") { ControlCenterSystem.openSettings("com.apple.Sound-Settings.extension") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cur?.symbol(input: input) ?? (input ? "mic.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 12, weight: .semibold)).frame(width: 16)
                        .foregroundStyle(Color.accentColor)
                    Text(cur?.name ?? (input ? "No input" : "No output"))
                        .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            if size == .banner, let cur, audio.deviceVolumes[cur.id] != nil {
                MiniSlider(value: Binding(get: { Double(audio.deviceVolumes[cur.id] ?? 0) },
                                          set: { audio.setDeviceVolume(cur, input: input, Float($0)) }))
                    .frame(width: 92)
            }
        }
        .frame(height: 30)
    }

    /// Every device with its own volume, output first.
    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("Output", audio.devices, input: false)
                section("Input", audio.inputs, input: true)
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [ControlCenterAudioDevice], input: Bool) -> some View {
        if !list.isEmpty {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.top, 3)
            ForEach(list) { d in
                let isDefault = d.id == (input ? audio.inputID : audio.currentID)
                HStack(spacing: 8) {
                    Button { if input { audio.selectInput(d) } else { audio.select(d) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: d.symbol(input: input)).font(.system(size: 11, weight: .semibold))
                                .frame(width: 15).foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
                            Text(d.name).font(.system(size: 11.5, weight: isDefault ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 0)
                            if isDefault { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if audio.deviceVolumes[d.id] != nil {
                        MiniSlider(value: Binding(get: { Double(audio.deviceVolumes[d.id] ?? 0) },
                                                  set: { audio.setDeviceVolume(d, input: input, Float($0)) }))
                            .frame(width: 74)
                    }
                }
                .frame(height: 26)
                .padding(.horizontal, 4)
                .background(isDefault ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// Thin capsule slider for rows.
struct MiniSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.accentColor).frame(width: max(5, geo.size.width * value))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = max(0, min(1, g.location.x / max(1, geo.size.width)))
            })
        }
        .frame(height: 20)
    }
}

// MARK: - Bluetooth devices

struct ControlCenterBluetoothDevicesTile: View {
    let size: ControlCenterTileSize
    private let bt = ControlCenterBluetoothDevices.shared

    var body: some View {
        Group {
            if bt.devices.isEmpty { Placeholder(symbol: "headphones", text: "No devices connected") }
            else if size == .banner { chips } else { list }
        }
        .ccSurface()
    }

    private func levelColor(_ p: Int) -> Color { p <= 15 ? .red : (p <= 30 ? .orange : .green) }

    private func summary(_ d: ControlCenterBTDevice) -> String {
        d.batteries.map { b in b.label.isEmpty ? "\(b.percent)%" : "\(b.label.prefix(1)) \(b.percent)%" }.joined(separator: " · ")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(bt.devices.prefix(4)) { d in
                VStack(spacing: 2) {
                    Image(systemName: d.symbol).font(.system(size: 16, weight: .medium))
                    Text(d.lowest.map { "\($0)%" } ?? "—").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(d.lowest.map(levelColor) ?? .secondary)
                    Text(d.name).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let rows = size == .wide ? 2 : 5
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(bt.devices.prefix(rows)) { d in
                HStack(spacing: 7) {
                    Image(systemName: d.symbol).font(.system(size: 11, weight: .semibold)).frame(width: 15)
                        .foregroundStyle(Theme.Palette.teal.last ?? .teal)
                    Text(d.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    if d.lowest != nil {
                        Text(summary(d)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(d.lowest.map(levelColor) ?? .secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shown in place of a module that has nothing to display (only visible while editing the layout).
struct Placeholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
            Text(text).font(.system(size: 10.5)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
