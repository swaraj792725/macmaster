import SwiftUI
import AppKit

/// Everything a menu bar item displays, as plain values (no observation) so it can be rendered to an image.
struct StatsBarModel {
    var module: StatsModule
    var style: StatsBarStyle = .both
    var label = ""
    var value = ""
    var history: [Double] = []
    var color: Color = .blue
    var line1 = ""            // network ↑
    var line2 = ""            // network ↓
    var battery: BatteryReading = .none
    var glyph: BatteryGlyphStyle = .classic
    var showTime = false
    var lowPower = false

    var signature: String {
        let h = history.map { String(Int(($0 * 30).rounded())) }.joined(separator: ",")
        let b = module == .battery
            ? "\(Int(battery.percent * 100))|\(battery.isCharging)|\(battery.isPluggedIn)|\(glyph.rawValue)|\(lowPower)|\(showTime)|\(battery.timeToEmpty ?? -1)|\(battery.timeToFull ?? -1)"
            : ""
        return [module.rawValue, style.rawValue, label, value, h, line1, line2, b].joined(separator: "/")
    }

    @MainActor static func make(_ module: StatsModule) -> StatsBarModel {
        let m = SystemMonitor.shared
        let hist = m.history.suffix(10)
        var model = StatsBarModel(module: module, style: StatsSettings.style(module))
        model.color = module.color
        switch module {
        case .cpu:
            model.label = "CPU"; model.value = StatsFmt.percent(m.cpu.total)
            model.history = hist.map(\.cpu)
            if m.cpu.total > 0.85 { model.color = Color(hex: 0xEF4444) }
        case .memory:
            model.label = "MEM"; model.value = StatsFmt.percent(m.memory.usedFraction)
            model.history = hist.map(\.memory)
            if m.memory.pressureLevel >= 4 { model.color = Color(hex: 0xEF4444) }
        case .gpu:
            model.label = "GPU"; model.value = StatsFmt.percent(m.gpu)
            model.history = hist.map(\.gpu)
        case .disk:
            model.label = "SSD"; model.value = StatsFmt.percent(m.disk.usedFraction)
            // graph = I/O activity (saturates at 200 MB/s)
            model.history = hist.map { min(1, ($0.diskRead + $0.diskWrite) / 200_000_000) }
        case .network:
            model.line1 = StatsFmt.compactRate(m.network.upRate)
            model.line2 = StatsFmt.compactRate(m.network.downRate)
        case .sensors:
            let t = m.thermal.cpu ?? m.thermal.hottest
            model.value = t.map { String(format: "%.0f°", $0) } ?? "—"
            if let t { model.color = StatsFmt.tempColor(t) }
        case .battery:
            model.battery = BatteryMonitor.shared.reading
            model.glyph = StatsSettings.batteryGlyph()
            model.showTime = StatsSettings.batteryShowTime()
            model.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return model
    }
}

struct StatsMiniBars: View {
    let values: [Double]
    var color: Color
    var count = 10
    var height: CGFloat = 14

    var body: some View {
        let padded = Array(repeating: 0.0, count: max(0, count - values.count)) + values.suffix(count)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                    Capsule().fill(color.opacity(0.16))
                    Capsule().fill(color).frame(height: max(1.5, height * min(1, max(0, v))))
                }
                .frame(width: 2.2, height: height)
            }
        }
    }
}

/// The compact view rendered into the status item button.
struct StatsBarItemView: View {
    let model: StatsBarModel

    var body: some View {
        Group {
            switch model.module {
            case .cpu, .memory, .gpu, .disk: metric
            case .network: network
            case .sensors: sensors
            case .battery: battery
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 3)
        .frame(height: 18)
        .fixedSize()
    }

    private var metric: some View {
        HStack(spacing: 4) {
            if model.style != .text {
                StatsMiniBars(values: model.history, color: model.color)
            }
            if model.style != .graph {
                VStack(alignment: .leading, spacing: -1) {
                    Text(model.label).font(.system(size: 7.5, weight: .bold)).opacity(0.55)
                    Text(model.value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 32, alignment: .leading)
            }
        }
    }

    private var network: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 2) {
                Text("↑").foregroundStyle(Theme.Palette.cpu)
                Text(model.line1)
            }
            HStack(spacing: 2) {
                Text("↓").foregroundStyle(Theme.Palette.network)
                Text(model.line2)
            }
        }
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .frame(width: 62, alignment: .trailing)
    }

    private var sensors: some View {
        HStack(spacing: 2) {
            Image(systemName: "thermometer.medium").font(.system(size: 11, weight: .semibold)).foregroundStyle(model.color)
            Text(model.value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private var battery: some View {
        let r = model.battery
        let minutes = r.isCharging ? r.timeToFull : r.timeToEmpty
        if model.style == .compact {
            // Small icon + stacked "BAT / 55%", same layout as the CPU/MEM items.
            return AnyView(HStack(spacing: 3) {
                BatteryGlyph(percent: r.percent, isCharging: r.isCharging, isPluggedIn: r.isPluggedIn,
                             style: model.glyph.compactStyle, height: model.glyph.menuBarHeight(compact: true), lowPower: model.lowPower)
                VStack(alignment: .leading, spacing: -1) {
                    Text(model.showTime ? (minutes.map(BatteryFormat.minutes) ?? "BAT") : "BAT")
                        .font(.system(size: 7.5, weight: .bold)).opacity(0.55)
                    Text("\(Int((r.percent * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .fixedSize()
            })
        }
        return AnyView(HStack(spacing: 4) {
            if model.style != .text {
                BatteryGlyph(percent: r.percent, isCharging: r.isCharging, isPluggedIn: r.isPluggedIn,
                             style: model.glyph, height: model.glyph.menuBarHeight(compact: false), lowPower: model.lowPower)
            }
            if model.style == .text || (model.style == .both && !model.glyph.includesPercent) {
                Text("\(Int((r.percent * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if model.showTime, model.style != .graph, let minutes {
                Text(BatteryFormat.minutes(minutes))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().opacity(0.7)
            }
        })
    }
}

enum StatsBarRenderer {
    @MainActor
    static func image(for model: StatsBarModel, dark: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: StatsBarItemView(model: model).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}
