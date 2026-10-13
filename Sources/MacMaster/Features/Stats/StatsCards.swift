import SwiftUI

// Dashboard module cards. Each reads SystemMonitor.shared, so SwiftUI Observation keeps them live.

struct StatsCPUCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        let info = SystemInfo.current
        StatsCardShell(module: .cpu, valueText: Fmt.percent(m.cpu.total),
                       caption: "\(info.chip) · \(info.logicalCores) cores") {
            if let t = m.thermal.cpu {
                StatusPill(text: Fmt.temperature(t), color: StatsFmt.tempColor(t))
            }
        } spark: {
            Sparkline(values: m.history.map(\.cpu), color: Theme.Palette.cpu, maxValue: 1)
        } details: {
            StatsCPUDetail()
        }
    }
}

struct StatsMemoryCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        let mem = m.memory
        let (label, color) = StatsPressure.info(mem.pressureLevel)
        StatsCardShell(module: .memory, valueText: Fmt.percent(mem.usedFraction),
                       caption: "\(Fmt.bytes(mem.used)) of \(Fmt.bytes(mem.total))") {
            HStack(spacing: 10) {
                StatusPill(text: label, color: color)
                StatsMiniRing(fraction: mem.usedFraction, color: Theme.Palette.memory)
            }
        } spark: {
            Sparkline(values: m.history.map(\.memory), color: Theme.Palette.memory, maxValue: 1)
        } details: {
            StatsMemoryDetail()
        }
    }
}

struct StatsGPUCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        StatsCardShell(module: .gpu, valueText: Fmt.percent(m.gpu), caption: "GPU utilization") {
            if let t = m.thermal.gpu { StatusPill(text: Fmt.temperature(t), color: StatsFmt.tempColor(t)) }
        } spark: {
            Sparkline(values: m.history.map(\.gpu), color: Theme.Palette.gpu, maxValue: 1)
        } details: {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Utilization", value: Fmt.percent(m.gpu, digits: 1), symbol: "speedometer")
                InfoRow(label: "Peak (last 5 min)", value: Fmt.percent(m.history.map(\.gpu).max() ?? 0, digits: 0), symbol: "chart.line.uptrend.xyaxis")
                InfoRow(label: "Temperature", value: m.thermal.gpu.map { Fmt.temperature($0) } ?? "—", symbol: "thermometer.medium")
                InfoRow(label: "Chip", value: SystemInfo.current.chip, symbol: "cpu")
            }
        }
    }
}

struct StatsDiskCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        let d = m.disk
        let name = FileManager.default.displayName(atPath: "/")
        StatsCardShell(module: .disk, valueText: Fmt.percent(d.usedFraction),
                       caption: "\(name) · \(Fmt.bytes(d.available)) free") {
            StatsMiniRing(fraction: d.usedFraction, color: Theme.Palette.disk)
        } spark: {
            StatsDualLineChart(a: m.history.map(\.diskRead), b: m.history.map(\.diskWrite),
                               aName: "Read", bName: "Write", aColor: Theme.Palette.network, bColor: Theme.Palette.disk)
        } details: {
            StatsDiskDetail()
        }
    }
}

struct StatsNetworkCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        let n = m.network
        StatsCardShell(module: .network, valueText: "↓ " + StatsFmt.compactRate(n.downRate),
                       caption: "↑ " + StatsFmt.compactRate(n.upRate) + (n.localIP.map { " · \($0)" } ?? "")) {
            if let i = n.primaryInterface { StatusPill(text: i, color: Theme.Palette.network) }
        } spark: {
            StatsDualLineChart(a: m.history.map(\.netDown), b: m.history.map(\.netUp))
        } details: {
            StatsNetworkDetail()
        }
    }
}

struct StatsSensorsCard: View {
    private var m: SystemMonitor { .shared }
    var body: some View {
        let t = m.thermal
        let main = t.cpu ?? t.hottest
        StatsCardShell(module: .sensors, valueText: main.map { Fmt.temperature($0) } ?? "—",
                       caption: t.cpu != nil ? "CPU temperature" : "Hottest sensor") {
            StatsThermalPill(state: t.state)
        } spark: {
            Sparkline(values: m.history.compactMap(\.cpuTemp), color: Theme.Palette.thermal, maxValue: 110)
        } details: {
            StatsSensorsDetail()
        }
    }
}

struct StatsPowerCard: View {
    @State private var samples: [Double] = []
    private var m: SystemMonitor { .shared }

    var body: some View {
        let r = BatteryMonitor.shared.reading
        let w = StatsPower.systemWatts(r)
        StatsCardShell(key: "power", title: "Power", symbol: "bolt.fill", colors: Theme.Palette.tools,
                       valueText: w.map { String(format: "%.1f W", $0) } ?? "—",
                       caption: r.isPresent ? (r.isPluggedIn ? "System draw · on adapter" : "System draw · on battery") : "No battery") {
            if r.isPresent { StatusPill(text: Fmt.percent(r.percent), color: BatteryPalette.level(r.percent)) }
        } spark: {
            Sparkline(values: samples, color: Theme.Palette.disk, maxValue: nil)
        } details: {
            StatsPowerDetail()
        }
        .onChange(of: m.lastUpdate) { _, _ in
            if let w = StatsPower.systemWatts(BatteryMonitor.shared.reading) {
                samples.append(w)
                if samples.count > 90 { samples.removeFirst(samples.count - 90) }
            }
        }
    }
}
