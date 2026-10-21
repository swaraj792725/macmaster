import SwiftUI
import CoreAudio

// MARK: - Helpers

enum SoundFormat {
    static func rate(_ hz: Double) -> String {
        let k = hz / 1000
        return (k == k.rounded() ? String(format: "%.0f", k) : String(format: "%.1f", k)) + " kHz"
    }

    static func speakerSymbol(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0.001 { return SymbolKit.firstAvailable(["speaker.slash.fill", "speaker.fill"]) }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Device row

/// A selectable device: icon, name, transport, check mark when it is the current default.
struct SoundDeviceRow: View {
    let device: SoundDevice
    let scope: SoundScope
    let selected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: device.symbol(for: scope), colors: selected ? Theme.Palette.pink : Theme.Palette.gray,
                         size: compact ? 24 : 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName).font(compact ? .callout : .body).lineLimit(1)
                    Text(device.subtitle(for: scope)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: 0xFF2D55))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, compact ? 8 : 0)
            .padding(.vertical, compact ? 4 : 0)
            .background(compact && hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(device.displayName), \(device.subtitle(for: scope))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Volume

/// Mute button + slider + percentage for an output device.
struct SoundOutputVolumeRow: View {
    let device: SoundDevice
    var compact = false
    @State private var engine = SoundEngine.shared

    var body: some View {
        let vol = device.outVolume ?? 0
        let muted = device.outMuted == true
        HStack(spacing: 10) {
            Button { engine.toggleOutputMute(device) } label: {
                Image(systemName: SoundFormat.speakerSymbol(volume: vol, muted: muted))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(muted ? Color.red : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute" : "Mute")
            .disabled(device.outVolume == nil && device.outMuted == nil)
            .accessibilityLabel(muted ? "Unmute output" : "Mute output")

            if device.outVolume != nil, device.outVolumeSettable {
                Slider(value: Binding(get: { Double(device.outVolume ?? 0) },
                                      set: { engine.setOutputVolume(device, Float($0)) }), in: 0...1)
                    .controlSize(compact ? .small : .regular)
                    .accessibilityLabel("Output volume")
                Text("\(Int(((muted ? 0 : vol) * 100).rounded()))%")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text(device.outMuteSettable ? "No volume control. Mute only." : "This device has no volume control. Use its own buttons.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Meter bar

struct SoundMeterBar: View {
    let level: Float
    let peak: Float
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x28B84A), Color(hex: 0xFFC400), Color(hex: 0xFF3B30)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(w * CGFloat(level), 0)) }
                Rectangle().fill(Color.primary.opacity(0.55))
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: min(max(w * CGFloat(peak) - 1, 0), w - 2))
                    .opacity(peak > 0.02 ? 1 : 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - Settings toggle row

/// A switch row stored under `key`; tells the engine when it changes so listeners and the menu bar follow.
struct SoundToggleRow: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let colors: [Color]
    @AppStorage private var isOn: Bool
    var disabled = false

    init(_ title: String, subtitle: String? = nil, symbol: String, colors: [Color], key: String, defaultValue: Bool, disabled: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.colors = colors
        self._isOn = AppStorage(wrappedValue: defaultValue, key)
        self.disabled = disabled
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, colors: colors) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1)
        .onChange(of: isOn) { _, _ in SoundEngine.shared.settingsChanged() }
    }
}
