import SwiftUI
import AppKit

/// Rich detail popover shown when a menu bar item is clicked.
struct StatsPopoverView: View {
    let module: StatsModule
    var onOpen: () -> Void = {}
    private var m: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            Divider()
            HStack {
                Spacer()
                Button {
                    FrontAppTracker.markDeliberate()
                    NSApp.activate()
                    NotificationCenter.default.post(name: Notification.Name("MacMaster.openSection"), object: module.openSection)
                    onOpen()
                } label: {
                    Label("Open MacMaster", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: module.symbol, colors: module.colors, size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text(module.title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(bigValue)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private var bigValue: String {
        switch module {
        case .cpu: Fmt.percent(m.cpu.total)
        case .memory: Fmt.percent(m.memory.usedFraction)
        case .gpu: Fmt.percent(m.gpu)
        case .disk: Fmt.percent(m.disk.usedFraction)
        case .network: StatsFmt.compactRate(m.network.downRate)
        case .sensors: (m.thermal.cpu ?? m.thermal.hottest).map { Fmt.temperature($0) } ?? "—"
        case .battery: Fmt.percent(BatteryMonitor.shared.reading.percent)
        }
    }

    private var subtitle: String {
        switch module {
        case .cpu: "\(SystemInfo.current.chip)"
        case .memory: "\(Fmt.bytes(m.memory.used)) of \(Fmt.bytes(m.memory.total))"
        case .gpu: "Utilization"
        case .disk: "\(Fmt.bytes(m.disk.available)) free of \(Fmt.bytes(m.disk.total))"
        case .network: "↑ \(StatsFmt.compactRate(m.network.upRate)) · \(m.network.primaryInterface ?? "offline")"
        case .sensors: "Thermal state: \(m.thermal.state.label)"
        case .battery: BatteryFormat.statusLine(BatteryMonitor.shared.reading)
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch module {
        case .cpu:
            Sparkline(values: m.history.map(\.cpu), color: Theme.Palette.cpu, maxValue: 1).frame(height: 70)
            StatsCPUDetail()
        case .memory:
            Sparkline(values: m.history.map(\.memory), color: Theme.Palette.memory, maxValue: 1).frame(height: 70)
            HStack {
                let (label, color) = StatsPressure.info(m.memory.pressureLevel)
                Text("Memory pressure").foregroundStyle(.secondary)
                Spacer()
                StatusPill(text: label, color: color)
            }.font(.callout)
            StatsMemoryDetail()
        case .gpu:
            Sparkline(values: m.history.map(\.gpu), color: Theme.Palette.gpu, maxValue: 1).frame(height: 90)
            InfoRow(label: "Temperature", value: m.thermal.gpu.map { Fmt.temperature($0) } ?? "—", symbol: "thermometer.medium")
            InfoRow(label: "Peak (5 min)", value: Fmt.percent(m.history.map(\.gpu).max() ?? 0), symbol: "chart.line.uptrend.xyaxis")
        case .disk:
            HStack(spacing: 14) {
                StatsMiniRing(fraction: m.disk.usedFraction, color: Theme.Palette.disk, size: 60)
                VStack(alignment: .leading) {
                    Text("Used \(Fmt.bytes(m.disk.used))").font(.callout)
                    Text("Free \(Fmt.bytes(m.disk.available))").font(.callout).foregroundStyle(.secondary)
                }
            }
            StatsDiskDetail()
        case .network:
            HStack {
                rate("Download", m.network.downRate, "arrow.down", Theme.Palette.network)
                rate("Upload", m.network.upRate, "arrow.up", Theme.Palette.cpu)
            }
            StatsDualLineChart(a: m.history.map(\.netDown), b: m.history.map(\.netUp)).frame(height: 80)
            StatsNetworkDetail()
        case .sensors:
            ScrollView { StatsSensorsDetail() }.frame(height: 360)
        case .battery:
            StatsBatteryPopoverBody()
        }
    }

    private func rate(_ t: String, _ v: Double, _ s: String, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s).foregroundStyle(c).font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                Text(t).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.rate(v)).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatsBatteryPopoverBody: View {
    @State private var level: [BatterySeriesPoint] = []
    private var b: BatteryMonitor { .shared }
    private var sys: SystemMonitor { .shared }

    var body: some View {
        let r = b.reading
        VStack(alignment: .leading, spacing: 12) {
            if !r.isPresent {
                Text("No battery on this Mac.").foregroundStyle(.secondary)
            } else {
                BatteryHeroGlyph(percent: r.percent, isCharging: r.isCharging, isPluggedIn: r.isPluggedIn, width: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                InfoRow(label: "Health", value: "\(Fmt.percent(r.health)) · \(r.cycleCount) cycles", symbol: "heart.fill")
                InfoRow(label: r.batteryPowerWatts >= 0 ? "Charging at" : "Discharging at",
                        value: BatteryFormat.watts(abs(r.batteryPowerWatts)), symbol: "bolt.fill")
                InfoRow(label: "Temperature", value: r.temperature.map { Fmt.temperature($0) } ?? "—", symbol: "thermometer.medium")
                if !level.isEmpty {
                    BatterySegmentedChart(points: level, yDomain: 0...100, unit: "%").frame(height: 110)
                }
                Text("Apps using energy").font(.subheadline.weight(.semibold))
                StatsProcessList(processes: sys.topCPU, value: { String(format: "%.1f%%", $0.cpu * 100) }, limit: 4)
            }
        }
        .task(id: b.history.last?.date) {
            level = BatteryChartPrep.prepare(b.history, range: .day, maxPoints: 120) { $0.percent * 100 }
        }
    }
}
