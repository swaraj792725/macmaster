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
                SectionTitle(text: "Quick Actions", symbol: "bolt.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.spacing)], spacing: Theme.spacing) {
                    action("Optimize Mac", "Speed up memory, CPU & startup", "gauge.with.dots.needle.67percent", Theme.Palette.yellow) { open(.optimizer) }
                    action("Smart Clean", "Scan caches, logs & dev junk", "sparkles", Theme.Palette.cleaner) { open(.cleaner) }
                    action("Leftover Hunter", "Find files of deleted apps", "magnifyingglass", Theme.Palette.uninstaller) { open(.uninstaller) }
                    action("Health Checkup", "Run a full system checkup", "stethoscope", Theme.Palette.health) { open(.health) }
                    KeepAwakeAction()
                }
            }

            DashboardLauncher()
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

    // MARK: Actions

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

// MARK: - Launcher

/// Grid of every feature, grouped like the sidebar, each with a one-line status read from existing state (no extra monitoring).
private struct DashboardLauncher: View {
    var body: some View {
        // Cheap re-read of prefs every few seconds; nothing here polls the system.
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                ForEach(AppGroup.allCases.filter { $0 != .overview }) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: group.title, symbol: group.symbol)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.spacing)], spacing: Theme.spacing) {
                            ForEach(group.sections) { s in
                                LauncherTile(section: s, status: LauncherStatus.text(for: s))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct LauncherTile: View {
    let section: AppSection
    let status: LauncherStatus

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openSection, object: section.rawValue)
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: section.symbol, colors: section.colors, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        if let dot = status.dot {
                            Circle().fill(dot).frame(width: 6, height: 6)
                        }
                        Text(status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .card(padding: 12)
        }
        .buttonStyle(.mmCard)
        .help(section.blurb)
    }
}

private struct LauncherStatus {
    let text: String
    var dot: Color? = nil

    private static func flag(_ key: String) -> Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }
    private static func onOff(_ key: String, on: String = "On", off: String = "Off") -> LauncherStatus? {
        guard let v = flag(key) else { return nil }
        return LauncherStatus(text: v ? on : off, dot: v ? .green : nil)
    }

    /// Live status when it is readily available, otherwise the feature's own blurb.
    @MainActor
    static func text(for s: AppSection) -> LauncherStatus {
        let fallback = LauncherStatus(text: s.blurb)
        switch s {
        case .stats:
            let m = SystemMonitor.shared
            return LauncherStatus(text: "CPU \(Fmt.percent(m.cpu.total)) · RAM \(Fmt.percent(m.memory.usedFraction))")
        case .health:
            let h = HealthMonitor.shared
            return LauncherStatus(text: "Score \(h.score) · \(HealthScoring.label(h.score))",
                                  dot: h.score >= 80 ? .green : h.score >= 60 ? .orange : .red)
        case .battery:
            let r = BatteryMonitor.shared.reading
            guard r.isPresent else { return fallback }
            return LauncherStatus(text: BatteryFormat.shortStatus(r), dot: r.isPluggedIn ? .green : nil)
        case .tools:
            return ToolsKeepAwake.shared.isActive ? LauncherStatus(text: "Keep Awake on", dot: .green) : fallback
        case .keyboard:
            let a = KeyboardEngine.shared.activeFeatures
            return a.isEmpty ? fallback : LauncherStatus(text: a.prefix(2).joined(separator: ", ") + (a.count > 2 ? " +\(a.count - 2)" : ""), dot: .green)
        case .tiling:
            return onOff("mm.tiling.enabled") ?? fallback
        case .mouse:
            return onOff("mm.mouse.enabled") ?? fallback
        case .shelf:
            return onOff("mm.shelf.enabled") ?? fallback
        case .menubar:
            return onOff("mm.menubarmgr.enabled") ?? fallback
        case .controlcenter:
            return onOff("mm.controlcenter.redirectAppleControlCenter", on: "Redirect on", off: "Apple's own") ?? fallback
        case .clock:
            return onOff("mm.clock.show", on: "Icon shown", off: "Icon hidden") ?? fallback
        case .cleaner:
            if flag("mm.cleaner.auto.enabled") == true { return LauncherStatus(text: "Auto-clean on", dot: .green) }
            return fallback
        case .optimizer:
            if flag("mm.optimizer.auto") == true { return LauncherStatus(text: "Auto-optimize on", dot: .green) }
            return fallback
        default:
            return fallback
        }
    }
}
