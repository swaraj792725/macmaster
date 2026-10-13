import SwiftUI

struct DashboardView: View {
    @State private var monitor = SystemMonitor.shared
    @State private var battery = BatteryMonitor.shared
    @State private var health = HealthMonitor.shared
    private let info = SystemInfo.current

    var body: some View {
        Page(spacing: 20) {
            PageHeader(title: greeting, subtitle: "Here's how your Mac is doing right now",
                       symbol: "square.grid.2x2.fill", colors: Theme.Palette.dashboard) {
                StatusPill(text: "Up \(Fmt.duration(SystemInfo.uptime))", color: .blue)
            }

            heroCard
            storageCard

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Live", symbol: "waveform.path.ecg")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Theme.spacing)], spacing: Theme.spacing) {
                    liveTile("CPU", Fmt.percent(monitor.cpu.total), "cpu.fill", Theme.Palette.blue,
                             monitor.history.map(\.cpu), Theme.Palette.cpu,
                             caption: "Load \(String(format: "%.2f", monitor.cpu.loadAverage.0))")
                    liveTile("Memory", Fmt.percent(monitor.memory.usedFraction), "memorychip.fill", Theme.Palette.purple,
                             monitor.history.map(\.memory), Theme.Palette.memory,
                             caption: "\(Fmt.bytes(monitor.memory.used)) of \(Fmt.bytes(monitor.memory.total))")
                    liveTile("GPU", Fmt.percent(monitor.gpu), "cube.transparent.fill", Theme.Palette.pink,
                             monitor.history.map(\.gpu), Theme.Palette.gpu, caption: info.chip)
                    liveTile("Network", "↓ " + Fmt.rate(monitor.network.downRate), "network", Theme.Palette.green,
                             monitor.history.map(\.netDown), Theme.Palette.network, normalized: false,
                             caption: "↑ " + Fmt.rate(monitor.network.upRate))
                    liveTile("Disk", Fmt.bytes(monitor.disk.available) + " free", "internaldrive.fill", Theme.Palette.orange,
                             monitor.history.map { $0.diskRead + $0.diskWrite }, Theme.Palette.disk, normalized: false,
                             caption: "R \(Fmt.rate(monitor.disk.readRate)) · W \(Fmt.rate(monitor.disk.writeRate))")
                    liveTile("Temperature", monitor.thermal.cpu.map(Fmt.temperature) ?? monitor.thermal.state.label,
                             "thermometer.medium", Theme.Palette.red,
                             monitor.history.compactMap(\.cpuTemp), Theme.Palette.thermal, range: 20...105,
                             caption: "Thermal state: \(monitor.thermal.state.label)")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Quick Actions", symbol: "bolt.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.spacing)], spacing: Theme.spacing) {
                    action("Optimize Mac", "Speed up memory, CPU & startup", "gauge.with.dots.needle.67percent", Theme.Palette.yellow) { open(.optimizer) }
                    action("Smart Clean", "Scan caches, logs & dev junk", "sparkles", Theme.Palette.cleaner) { open(.cleaner) }
                    action("Leftover Hunter", "Find files of deleted apps", "magnifyingglass", Theme.Palette.uninstaller) { open(.uninstaller) }
                    action("Health Checkup", "Run a full system checkup", "stethoscope", Theme.Palette.health) { open(.health) }
                    KeepAwakeAction()
                }
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: Hero

    private var healthColors: [Color] {
        health.score >= 80 ? Theme.Palette.green : health.score >= 60 ? Theme.Palette.orange : Theme.Palette.red
    }

    private var heroCard: some View {
        let hasBattery = battery.reading.isPresent
        let laptop = MacIdentity.isLaptop(modelIdentifier: info.modelIdentifier, hasBattery: hasBattery)
        return HStack(alignment: .center, spacing: 24) {
            MacIllustration(isLaptop: laptop, width: 150)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(info.hostName)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                Text(info.chip)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Text("\(Fmt.bytes(info.memory)) memory · \(info.logicalCores) cores · \(info.osVersion)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    StatusPill(text: health.issues.isEmpty ? "No issues" : "\(health.issues.count) issue\(health.issues.count == 1 ? "" : "s")",
                               color: health.issues.isEmpty ? .green : .orange)
                    Text(health.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)

            HStack(spacing: 18) {
                ringBlock(title: "Health", caption: HealthScoring.label(health.score)) {
                    RingGauge(fraction: Double(health.score) / 100, lineWidth: 9, colors: healthColors,
                              valueText: "\(health.score)")
                } action: { open(.health) }

                if hasBattery {
                    let r = battery.reading
                    ringBlock(title: "Battery", caption: BatteryFormat.shortStatus(r)) {
                        RingGauge(fraction: r.percent, lineWidth: 9,
                                  colors: r.percent <= 0.2 && !r.isPluggedIn ? Theme.Palette.red : Theme.Palette.green,
                                  valueText: Fmt.percent(r.percent))
                    } action: { open(.battery) }
                }
            }
        }
        .card(padding: 22, kind: .glass, radius: Theme.Radius.hero)
    }

    private func ringBlock<G: View>(title: String, caption: String,
                                    @ViewBuilder gauge: () -> G,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                gauge().frame(width: 88, height: 88)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 96)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.mmCard)
    }

    // MARK: Storage

    private var storageCard: some View {
        let total = Double(monitor.disk.total)
        let used = Double(monitor.disk.total &- min(monitor.disk.total, monitor.disk.available))
        let free = Double(monitor.disk.available)
        let usedFrac = total > 0 ? used / total : 0
        let usedColor = usedFrac > 0.92 ? Theme.Palette.red[1] : usedFrac > 0.8 ? Theme.Palette.orange[1] : Theme.Palette.cpu
        let seg = StorageSegment("Used", bytes: used, color: usedColor)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    IconTile(symbol: "internaldrive.fill", colors: Theme.Palette.gray, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Macintosh HD").font(.system(size: 15, weight: .semibold))
                        Text("\(Fmt.bytes(Int64(used))) of \(Fmt.bytes(monitor.disk.total)) used")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Fmt.bytes(Int64(free)) + " available")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.levelColor(usedFrac))
                Button("Clean…") { open(.cleaner) }.buttonStyle(.mmSecondary)
            }
            SegmentedBar(segments: [seg], total: total, height: 14)
            SegmentLegend(segments: [seg], freeBytes: free)
        }
        .card(padding: 18)
    }

    // MARK: Tiles

    private func liveTile(_ title: String, _ value: String, _ symbol: String, _ colors: [Color],
                          _ series: [Double], _ color: Color, normalized: Bool = true,
                          range: ClosedRange<Double>? = nil, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, colors: colors, size: 24)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: series.isEmpty ? [0, 0] : series, color: color,
                      maxValue: range?.upperBound ?? (normalized ? 1 : nil), minValue: range?.lowerBound ?? 0)
                .frame(height: 36)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .card()
    }

    private func action(_ title: String, _ subtitle: String, _ symbol: String, _ colors: [Color], perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            DashboardActionLabel(title: title, subtitle: subtitle, symbol: symbol, colors: colors)
        }
        .buttonStyle(.mmCard)
    }

    private func open(_ s: AppSection) { NotificationCenter.default.post(name: .openSection, object: s.rawValue) }
}

struct DashboardActionLabel: View {
    let title: String, subtitle: String, symbol: String, colors: [Color]
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing { trailing } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .card()
    }
}

private struct KeepAwakeAction: View {
    @State private var awake = ToolsKeepAwake.shared
    var body: some View {
        Button { awake.toggle() } label: {
            DashboardActionLabel(title: "Keep Awake", subtitle: awake.isActive ? "Mac won't sleep" : "Prevent sleep",
                                 symbol: awake.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill",
                                 colors: Theme.Palette.orange,
                                 trailing: AnyView(StatusPill(text: awake.isActive ? "On" : "Off", color: awake.isActive ? .green : .gray)))
        }
        .buttonStyle(.mmCard)
    }
}
