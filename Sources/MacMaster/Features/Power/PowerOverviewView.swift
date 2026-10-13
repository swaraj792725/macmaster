import SwiftUI
import AppKit
import Observation

// MARK: - Energy model

/// Samples `top -o power` every 10 s while the Overview is visible.
@Observable
@MainActor
final class PowerEnergyModel {
    private(set) var users: [PowerEnergyUser] = []
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var updated: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let own = getpid()
        let result = await Task.detached(priority: .utility) { () -> [PowerEnergyUser]? in
            let r = Shell.run("/usr/bin/top", ["-l", "2", "-n", "25", "-o", "power", "-stats", "pid,command,power"], timeout: 30)
            guard r.ok || !r.stdout.isEmpty else { return nil }
            return PowerEnergyModel.group(PowerParsers.parseTop(r.stdout), ownPID: own)
        }.value
        guard !Task.isCancelled else { return }
        if let result { users = result; failed = false; updated = Date() } else { failed = users.isEmpty }
    }

    /// Merges helper processes into their parent app and ranks by total energy impact.
    nonisolated static func group(_ rows: [(pid: Int32, command: String, power: Double)], ownPID: Int32) -> [PowerEnergyUser] {
        var map: [String: PowerEnergyUser] = [:]
        var order: [String] = []
        for row in rows where row.command != "top" && row.power > 0 {
            let path = ProcessReader.path(of: row.pid)
            let bundle = PowerProcessControl.bundlePath(forExecutable: path)
            let key = bundle ?? "cmd:" + row.command
            if var u = map[key] {
                u.power += row.power; u.pids.append(row.pid)
                map[key] = u
            } else {
                var name = row.command
                if let bundle, let b = Bundle(path: bundle) {
                    name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                }
                let quittable = bundle != nil && !PowerProcessControl.isProtected(path: path) && row.pid != ownPID
                map[key] = PowerEnergyUser(id: key, name: name, power: row.power, pids: [row.pid],
                                           bundlePath: bundle, canQuit: quittable)
                order.append(key)
            }
        }
        return order.compactMap { map[$0] }.sorted { $0.power > $1.power }.prefix(12).map { $0 }
    }
}

// MARK: - Overview

struct PowerOverviewTab: View {
    @State private var energy = PowerEnergyModel()
    private let scheduler = PowerScheduler.shared
    private let battery = BatteryMonitor.shared

    private let actions: [PowerActionKind] = [.sleep, .displaySleep, .lock, .screenSaver, .logOut, .restart, .shutDown]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            hero
            if let p = scheduler.pending { pendingBanner(p) }
            SectionTitle(text: "Actions", symbol: "power")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                ForEach(actions) { kind in
                    PowerActionTile(kind: kind) { Task { await PowerConfirm.run(kind) } }
                }
            }
            energySection
        }
        .onAppear { scheduler.start(); energy.start() }
        .onDisappear { energy.stop() }
    }

    // MARK: Hero

    private var hero: some View {
        let r = battery.reading
        let onAC = r.isPluggedIn
        let draw = r.systemPowerWatts ?? (r.isPresent && !onAC ? max(0, -r.batteryPowerWatts) : nil)
        let colors = onAC ? Theme.Palette.green : (r.percent < 0.2 ? Theme.Palette.red : Theme.Palette.orange)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IconTile(symbol: onAC ? "powerplug.fill" : "battery.75percent", colors: colors, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(onAC ? "Power Adapter" : "Battery Power")
                            .font(.system(size: 20, weight: .bold))
                        Text(sourceSubtitle(r)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 22) {
                    if r.isPresent {
                        heroStat("Charge", Fmt.percent(r.percent), r.isCharging ? "Charging" : (onAC ? "Not charging" : "Discharging"))
                        heroStat(onAC && r.isCharging ? "Until full" : "Remaining", remainingValue(r), nil)
                    }
                    if onAC, let w = r.adapterWatts {
                        heroStat("Adapter", "\(w) W", r.adapterName)
                    }
                    if r.isPresent {
                        heroStat("Battery flow", PowerFmt.watts(r.batteryPowerWatts),
                                 r.batteryPowerWatts > 0.2 ? "Into battery" : (r.batteryPowerWatts < -0.2 ? "From battery" : "Idle"))
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text("System power").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(PowerFmt.watts(draw))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                    .animation(.smooth, value: draw)
                if scheduler.powerTrace.count > 1 {
                    Sparkline(values: scheduler.powerTrace, color: colors.last ?? .accentColor)
                        .frame(width: 220, height: 54)
                } else {
                    Text("Collecting…").font(.caption).foregroundStyle(.tertiary).frame(width: 220, height: 54)
                }
                Text("Last 5 minutes").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .card(padding: 20, kind: .glass, radius: Theme.Radius.hero)
    }

    private func sourceSubtitle(_ r: BatteryReading) -> String {
        if !r.isPresent { return "Connected to power" }
        if r.isPluggedIn {
            if r.isFullyCharged { return "Fully charged" }
            return r.isCharging ? "Charging" : "Plugged in, not charging"
        }
        return "Running on battery"
    }

    private func remainingValue(_ r: BatteryReading) -> String {
        if r.isFullyCharged && r.isPluggedIn { return "Full" }
        if r.isCharging, let m = r.timeToFull, m > 0, m < 6000 { return Fmt.duration(Double(m) * 60) }
        if !r.isPluggedIn, let m = r.timeToEmpty, m > 0, m < 6000 { return Fmt.duration(Double(m) * 60) }
        return "Calculating…"
    }

    private func heroStat(_ title: String, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }

    private func pendingBanner(_ p: PowerPending) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: p.action.symbol, colors: p.action.colors, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Mac will \(p.action.progressive) in \(PowerFmt.clock(p.remaining))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
                Text(p.source == .timer ? "Scheduled timer" : p.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { scheduler.cancelPending() }.buttonStyle(.mmSecondary)
        }
        .card()
    }

    // MARK: Energy

    private var energySection: some View {
        let maxPower = max(10, energy.users.map(\.power).max() ?? 10)
        return GroupedSection("Top energy users", symbol: "bolt.fill",
                              footer: "Energy impact from the system's power accounting, refreshed every 10 seconds while this page is open. Helper processes are grouped under their app.") {
            if energy.users.isEmpty {
                HStack(spacing: 10) {
                    if energy.failed {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Text("Couldn't read energy data.").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Measuring (takes a couple of seconds)…").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                ForEach(energy.users) { u in
                    PowerEnergyRow(user: u, maxPower: maxPower)
                }
            }
        }
    }
}

private struct PowerEnergyRow: View {
    let user: PowerEnergyUser
    let maxPower: Double

    var body: some View {
        HStack(spacing: 12) {
            PowerAppIcon(pid: user.pids.first, bundlePath: user.bundlePath, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(user.name).font(.callout).lineLimit(1)
                    if user.pids.count > 1 {
                        Text("\(user.pids.count) processes").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                CapsuleBar(fraction: user.power / maxPower,
                           color: Theme.levelColor(user.power / 60, warn: 0.35, critical: 0.7), height: 6)
            }
            Text(String(format: "%.1f", user.power))
                .font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            if user.canQuit {
                Button("Quit") {
                    if let pid = PowerProcessControl.appPID(bundlePath: user.bundlePath) ?? user.pids.first {
                        Task { await PowerConfirm.quitProcess(pid: pid, name: user.name) }
                    }
                }
                .buttonStyle(.mmGhost)
            } else {
                Color.clear.frame(width: 52, height: 1)
            }
        }
    }
}
