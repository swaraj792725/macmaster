import SwiftUI
import AppKit

// MARK: - CPU

enum StatsCoreLabels {
    /// On Apple Silicon efficiency cores are listed first. Falls back to "Core N" when counts don't add up.
    static func labels(count: Int) -> [String] {
        let info = SystemInfo.current
        let e = info.efficiencyCores, p = info.performanceCores
        if e > 0, p > 0, e + p == count {
            return (1...e).map { "E\($0)" } + (1...p).map { "P\($0)" }
        }
        return (1...max(1, count)).map { "Core \($0)" }
    }
    static func isEfficiency(_ label: String) -> Bool { label.hasPrefix("E") }
}

struct StatsCPUDetail: View {
    var showProcesses = true
    private var m: SystemMonitor { .shared }

    var body: some View {
        let cpu = m.cpu
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                StatsSplitBar(first: cpu.user, second: cpu.system)
                HStack(spacing: 14) {
                    legend("User", cpu.user, Theme.Palette.cpu)
                    legend("System", cpu.system, Theme.Palette.thermal)
                    legend("Idle", max(0, 1 - cpu.total), .secondary)
                }
            }
            StatsCoreGrid(perCore: cpu.perCore)
            HStack {
                Label("Load average", systemImage: "gauge.with.dots.needle.50percent").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f  %.2f  %.2f", cpu.loadAverage.0, cpu.loadAverage.1, cpu.loadAverage.2)).monospacedDigit()
            }.font(.callout)
            HStack {
                Label("Uptime", systemImage: "clock").foregroundStyle(.secondary)
                Spacer()
                Text(StatsFmt.uptime(SystemInfo.uptime)).monospacedDigit()
            }.font(.callout)
            if showProcesses {
                Text("Top processes").font(.subheadline.weight(.semibold))
                StatsProcessList(processes: m.topCPU) { String(format: "%.1f%%", $0.cpu * 100) }
            }
        }
    }

    private func legend(_ t: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).foregroundStyle(.secondary)
            Text(StatsFmt.percent(v)).monospacedDigit()
        }.font(.caption)
    }
}

struct StatsCoreGrid: View {
    let perCore: [Double]
    var barHeight: CGFloat = 46

    var body: some View {
        let labels = StatsCoreLabels.labels(count: perCore.count)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 44), spacing: 6)], spacing: 8) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { i, v in
                let label = i < labels.count ? labels[i] : "Core \(i + 1)"
                let color = StatsCoreLabels.isEfficiency(label) ? Theme.Palette.network : Theme.Palette.cpu
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(LinearGradient(colors: [v > 0.85 ? Color(hex: 0xEF4444) : color, color.opacity(0.65)],
                                                      startPoint: .top, endPoint: .bottom))
                            .frame(height: max(4, barHeight * min(1, v)))
                            .animation(.smooth(duration: 0.4), value: v)
                    }
                    .frame(width: 12, height: barHeight)
                    Text(label.replacingOccurrences(of: "Core ", with: "")).font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .help("\(label): \(StatsFmt.percent(v))")
            }
        }
    }
}

// MARK: - Memory

struct StatsMemoryDetail: View {
    var showProcesses = true
    private var m: SystemMonitor { .shared }

    var body: some View {
        let mem = m.memory
        let cached = min(mem.cached, mem.free)
        VStack(alignment: .leading, spacing: 14) {
            StatsStackedBar(segments: [
                .init(label: "App", value: Double(mem.app), color: Theme.Palette.memory),
                .init(label: "Wired", value: Double(mem.wired), color: Theme.Palette.thermal),
                .init(label: "Compressed", value: Double(mem.compressed), color: Theme.Palette.gpu),
                .init(label: "Cached", value: Double(cached), color: Theme.Palette.cpu.opacity(0.7)),
                .init(label: "Free", value: Double(mem.free - cached), color: Color.gray.opacity(0.35)),
            ])
            HStack {
                Label("Swap used", systemImage: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.bytes(mem.swapUsed)) of \(Fmt.bytes(mem.swapTotal))").monospacedDigit()
            }.font(.callout)
            if showProcesses {
                Text("Top processes").font(.subheadline.weight(.semibold))
                StatsProcessList(processes: m.topMemory) { Fmt.bytes($0.memory) }
            }
        }
    }
}

enum StatsPressure {
    static func info(_ level: Int) -> (String, Color) {
        switch level {
        case 4: ("Critical", Color(hex: 0xEF4444))
        case 2: ("Warning", Color(hex: 0xF59E0B))
        default: ("Normal", Color(hex: 0x22C55E))
        }
    }
}

// MARK: - Disk

struct StatsDiskDetail: View {
    private var m: SystemMonitor { .shared }
    @State private var volumes: [StatsVolume] = []

    var body: some View {
        let d = m.disk
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                rate("Read", d.readRate, "arrow.down.doc.fill", Theme.Palette.network)
                rate("Write", d.writeRate, "arrow.up.doc.fill", Theme.Palette.disk)
            }
            StatsDualLineChart(a: m.history.map(\.diskRead), b: m.history.map(\.diskWrite),
                               aName: "Read", bName: "Write", aColor: Theme.Palette.network, bColor: Theme.Palette.disk)
                .frame(height: 60)
            Text("Volumes").font(.subheadline.weight(.semibold))
            ForEach(volumes) { v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: v.isInternal ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                        Text(v.name).lineLimit(1)
                        Spacer()
                        Text("\(Fmt.bytes(v.available)) free of \(Fmt.bytes(v.total))").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout)
                    CapsuleBar(fraction: v.fraction, color: Theme.levelColor(v.fraction, warn: 0.8, critical: 0.92), height: 6)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                volumes = await Task.detached(priority: .utility) { StatsVolumeLoader.load() }.value
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func rate(_ t: String, _ v: Double, _ symbol: String, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(c)
            VStack(alignment: .leading, spacing: 0) {
                Text(t).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.rate(v)).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Network

struct StatsNetworkDetail: View {
    private var m: SystemMonitor { .shared }
    @State private var publicIP = StatsPublicIPModel()
    @State private var wifi: StatsWiFiInfo?
    @State private var wifiChecked = false

    var body: some View {
        let n = m.network
        VStack(alignment: .leading, spacing: 10) {
            InfoRow(label: "Total downloaded", value: Fmt.bytes(n.totalDown), symbol: "arrow.down.circle")
            InfoRow(label: "Total uploaded", value: Fmt.bytes(n.totalUp), symbol: "arrow.up.circle")
            InfoRow(label: "Interface", value: n.primaryInterface ?? "—", symbol: "cable.connector")
            InfoRow(label: "Local IP", value: n.localIP ?? "—", symbol: "network")
            HStack {
                Label("Public IP", systemImage: "globe").foregroundStyle(.secondary)
                Spacer()
                switch publicIP.state {
                case .idle:
                    Button("Show") { publicIP.fetch() }.controlSize(.small)
                case .loading:
                    ProgressView().controlSize(.small)
                case .value(let ip):
                    Text(ip).monospacedDigit().textSelection(.enabled)
                    Button { publicIP.fetch() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh")
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                    Button("Retry") { publicIP.fetch() }.controlSize(.small)
                }
            }
            .font(.callout)
            Text("Public IP is fetched from api.ipify.org only when you ask.").font(.caption2).foregroundStyle(.tertiary)

            if let w = wifi {
                Divider()
                HStack {
                    Image(systemName: "wifi").foregroundStyle(Theme.Palette.network)
                    Text("Wi-Fi").font(.subheadline.weight(.semibold))
                    Spacer()
                    if w.poweredOn { StatusPill(text: "\(w.rssi) dBm", color: Theme.levelColor(1 - w.quality, warn: 0.5, critical: 0.75)) }
                }
                if w.poweredOn {
                    CapsuleBar(fraction: w.quality, color: Theme.levelColor(1 - w.quality, warn: 0.5, critical: 0.75), height: 6)
                    InfoRow(label: "Network", value: w.ssid ?? "Hidden (needs Location access)")
                    InfoRow(label: "Link speed", value: String(format: "%.0f Mbps", w.txRate))
                    InfoRow(label: "Noise / SNR", value: "\(w.noise) dBm / \(w.snr) dB")
                    InfoRow(label: "Channel", value: [w.channel.map(String.init), w.band].compactMap { $0 }.joined(separator: " · "))
                    InfoRow(label: "Security", value: w.security)
                } else {
                    Text("Wi-Fi is turned off.").font(.callout).foregroundStyle(.secondary)
                }
            } else if wifiChecked {
                Text("No Wi-Fi interface.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task {
            while !Task.isCancelled {
                wifi = await Task.detached(priority: .utility) { StatsWiFiReader.read() }.value
                wifiChecked = true
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Sensors

enum StatsSensorGroup: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", battery = "Battery", ssd = "SSD", other = "Other"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .battery: "battery.50percent"
        case .ssd: "internaldrive"
        case .other: "thermometer.medium"
        }
    }
    static func classify(_ name: String) -> StatsSensorGroup {
        let n = name.lowercased()
        if n.contains("gpu") { return .gpu }
        if n.contains("battery") { return .battery }
        if n.contains("nand") || n.contains("ssd") { return .ssd }
        if n.contains("tdie") || n.hasPrefix("pacc") || n.hasPrefix("eacc") || n.contains("cpu") || n.contains("soc") { return .cpu }
        return .other
    }
}

struct StatsSensorsDetail: View {
    private var m: SystemMonitor { .shared }
    @State private var fans: StatsFanState = .unavailable

    var body: some View {
        let t = m.thermal
        let groups = Dictionary(grouping: t.sensors) { StatsSensorGroup.classify($0.name) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Thermal state", systemImage: "flame").foregroundStyle(.secondary)
                Spacer()
                StatsThermalPill(state: t.state)
            }.font(.callout)

            if t.sensors.isEmpty {
                Text("No temperature sensors available on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(StatsSensorGroup.allCases) { g in
                if let list = groups[g], !list.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(g.rawValue, systemImage: g.symbol).font(.subheadline.weight(.semibold))
                        ForEach(list) { s in
                            HStack {
                                Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Fmt.temperature(s.celsius))
                                    .font(.callout.weight(.medium)).monospacedDigit()
                                    .foregroundStyle(StatsFmt.tempColor(s.celsius))
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                }
            }

            Divider()
            Label("Fans", systemImage: "fanblades.fill").font(.subheadline.weight(.semibold))
            switch fans {
            case .unavailable, .none:
                Text("No fans (fanless Mac)").font(.callout).foregroundStyle(.secondary)
            case .fans(let list):
                ForEach(list) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Fan \(f.index + 1)").foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f RPM", f.rpm)).monospacedDigit().contentTransition(.numericText())
                        }.font(.callout)
                        CapsuleBar(fraction: f.fraction, color: Theme.Palette.network, height: 6)
                        Text(String(format: "%.0f – %.0f RPM range", f.minRPM, f.maxRPM)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                fans = await Task.detached(priority: .utility) { StatsSMCReader.shared.fans() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct StatsThermalPill: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        let color: Color = switch state {
        case .nominal: Color(hex: 0x22C55E)
        case .fair: Color(hex: 0xEAB308)
        case .serious: Color(hex: 0xF97316)
        default: Color(hex: 0xEF4444)
        }
        StatusPill(text: state.label, color: color)
    }
}

// MARK: - Power

struct StatsPowerDetail: View {
    var body: some View {
        let r = BatteryMonitor.shared.reading
        VStack(alignment: .leading, spacing: 6) {
            if r.isPresent {
                InfoRow(label: "System draw", value: StatsPower.systemWatts(r).map { BatteryFormat.watts($0) } ?? "—", symbol: "bolt.fill")
                InfoRow(label: r.batteryPowerWatts >= 0 ? "Battery charging at" : "Battery draining at",
                        value: BatteryFormat.watts(abs(r.batteryPowerWatts)), symbol: "battery.50percent")
                InfoRow(label: "Adapter", value: r.adapterWatts.map { "\($0) W" } ?? (r.isPluggedIn ? "Connected" : "None"), symbol: "powerplug")
                if let n = r.adapterName { InfoRow(label: "Adapter name", value: n, symbol: "tag") }
                InfoRow(label: "Source", value: r.isPluggedIn ? "Power adapter" : "Battery", symbol: "cable.connector")
            } else {
                Text("Power details need a battery-equipped Mac.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

enum StatsPower {
    /// Best estimate of total system power in watts.
    static func systemWatts(_ r: BatteryReading) -> Double? {
        if let s = r.systemPowerWatts, s > 0 { return s }
        if !r.isPluggedIn { return abs(r.batteryPowerWatts) }
        return nil
    }
}
