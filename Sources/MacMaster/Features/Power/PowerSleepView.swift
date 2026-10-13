import SwiftUI
import Charts
import AppKit
import Observation

// MARK: - Models

@Observable
@MainActor
private final class PowerAssertionsModel {
    private(set) var items: [PowerAssertion] = []
    private(set) var loaded = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    func refresh() async {
        let parsed = await Task.detached(priority: .utility) { () -> [PowerAssertion] in
            let r = Shell.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 10)
            return PowerParsers.parseAssertions(r.stdout)
        }.value
        guard !Task.isCancelled else { return }
        items = parsed.sorted {
            if $0.blocksSleep != $1.blocksSleep { return $0.blocksSleep && !$1.blocksSleep }
            return $0.age > $1.age
        }
        loaded = true
    }
}

@Observable
@MainActor
private final class PowerHistoryModel {
    private(set) var summary: PowerHistorySummary?
    private(set) var loading = false
    private(set) var failed = false

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await Task.detached(priority: .utility) { () -> PowerHistorySummary? in
            // The raw log is many MB; filter and cap it before it reaches Swift.
            let cmd = "/usr/bin/pmset -g log | /usr/bin/grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} [+-][0-9]{4} (Sleep|Wake|DarkWake) {2,}' | /usr/bin/tail -n 4000"
            let r = Shell.run("/bin/sh", ["-c", cmd], timeout: 45)
            guard !r.stdout.isEmpty else { return nil }
            let since = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
            let events = PowerParsers.parseSleepLog(r.stdout, since: since)
            return PowerParsers.summarize(events, days: 3)
        }.value
        summary = result
        failed = result == nil
    }
}

// MARK: - Tab

struct PowerSleepTab: View {
    @State private var assertions = PowerAssertionsModel()
    @State private var history = PowerHistoryModel()
    private let scheduler = PowerScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PowerAssertionsSection(model: assertions)
            PowerKeepAwakeSection()
            PowerHistorySection(model: history)
        }
        .onAppear { scheduler.start(); assertions.start() }
        .onDisappear { assertions.stop() }
        .task { await history.load() }
    }
}

// MARK: - What's keeping your Mac awake

private struct PowerAssertionsSection: View {
    let model: PowerAssertionsModel
    @AppStorage("mm.power.showAllAssertions") private var showAll = false

    var body: some View {
        let blockers = model.items.filter(\.blocksSleep)
        let shown = showAll ? model.items : blockers
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: blockers.isEmpty ? "moon.zzz.fill" : "cup.and.saucer.fill",
                         colors: blockers.isEmpty ? Theme.Palette.green : Theme.Palette.orange, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(!model.loaded ? "Checking…" : (blockers.isEmpty ? "Nothing is keeping your Mac awake"
                                                         : "\(blockers.count) thing\(blockers.count == 1 ? " is" : "s are") keeping your Mac awake"))
                        .font(.headline)
                    Text("Apps and system services can ask macOS not to sleep. Quit the app to let the Mac sleep again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show all", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
            }
            .card()

            if !shown.isEmpty {
                GroupedSection {
                    ForEach(shown) { a in PowerAssertionRow(assertion: a) }
                }
            }
        }
    }
}

private struct PowerAssertionRow: View {
    let assertion: PowerAssertion

    var body: some View {
        let path = ProcessReader.path(of: assertion.pid)
        let bundle = PowerProcessControl.bundlePath(forExecutable: path)
        let canQuit = !PowerProcessControl.isProtected(path: path) && assertion.pid != getpid()
        HStack(alignment: .top, spacing: 12) {
            PowerAppIcon(pid: assertion.pid, bundlePath: bundle, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(assertion.processName).font(.callout.weight(.semibold)).lineLimit(1)
                    StatusPill(text: assertion.typeTitle, color: assertion.blocksSleep ? Color(hex: 0xFF9F0A) : .secondary)
                }
                if !assertion.reason.isEmpty {
                    Text(assertion.reason).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                if let d = assertion.detail {
                    Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(PowerFmt.age(assertion.age)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if canQuit {
                    Button("Quit") {
                        Task { await PowerConfirm.quitProcess(pid: assertion.pid, name: assertion.processName) }
                    }
                    .buttonStyle(.mmGhost)
                }
            }
        }
    }
}

// MARK: - Keep awake with the lid closed

private struct PowerKeepAwakeSection: View {
    private let scheduler = PowerScheduler.shared
    @AppStorage("mm.power.lid.minutes") private var minutes = 60
    @AppStorage("mm.power.lid.floorOn") private var floorOn = true
    @AppStorage("mm.power.lid.floor") private var floor = 20

    private let durations: [(Int, String)] = [(30, "30 minutes"), (60, "1 hour"), (120, "2 hours"),
                                              (240, "4 hours"), (480, "8 hours"), (0, "Until I turn it off")]

    var body: some View {
        let state = scheduler.lidState
        VStack(alignment: .leading, spacing: 10) {
            PowerCallout(symbol: "flame.fill", title: "Heat warning",
                         message: "With the lid closed and sleep disabled the Mac keeps running. Never put it in a bag, case or any enclosed space while this is on: it can overheat and damage the battery.",
                         color: Color(hex: 0xFF3B30))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(symbol: "laptopcomputer", colors: isOn(state) ? Theme.Palette.red : Theme.Palette.gray, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep awake with the lid closed").font(.headline)
                        Text("Runs with the screen off, for downloads, servers or an external display.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusPill(state)
                }

                switch state {
                case .on(let until, let floor):
                    onControls(until: until, floor: floor)
                case .external:
                    Text("Sleep is currently disabled, but not by this MacMaster session. Turning it off needs your password.")
                        .font(.callout).foregroundStyle(.secondary)
                    turnOff
                default:
                    offControls
                }
                if let e = scheduler.lidError {
                    Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .card()
        }
    }

    private func isOn(_ s: PowerLidState) -> Bool { if case .on = s { return true }; return s == .external }

    @ViewBuilder
    private func statusPill(_ s: PowerLidState) -> some View {
        switch s {
        case .on: StatusPill(text: "On", color: Color(hex: 0xFF3B30))
        case .external: StatusPill(text: "On (external)", color: Color(hex: 0xFF9F0A))
        case .off: StatusPill(text: "Off", color: Color(hex: 0x30D158))
        case .unknown: StatusPill(text: "Checking…", color: .secondary)
        }
    }

    private func onControls(until: Date?, floor: Int?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let until {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Turns off in \(PowerFmt.clock(until.timeIntervalSinceNow)) (at \(PowerFmt.time(until)))")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    }
                } else {
                    Text("Stays on until you turn it off").font(.title3.weight(.semibold))
                }
                Text(revertSummary(floor: floor)).font(.caption).foregroundStyle(.secondary)
            }
            turnOff
        }
    }

    private func revertSummary(floor: Int?) -> String {
        var parts = ["when MacMaster quits"]
        if let floor { parts.append("if the battery drops below \(floor)%") }
        return "Sleep returns automatically " + parts.joined(separator: " or ") + "."
    }

    private var turnOff: some View {
        HStack(spacing: 10) {
            Button { Task { await scheduler.disableClosedLid() } } label: {
                Label("Turn Off", systemImage: "power")
            }
            .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF3B30)))
            .disabled(scheduler.lidBusy)
            if scheduler.lidBusy { ProgressView().controlSize(.small) }
        }
    }

    private var offControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Turn off automatically after").font(.callout)
                Picker("Duration", selection: $minutes) {
                    ForEach(durations, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("Also turn off when battery drops below", isOn: $floorOn).toggleStyle(.checkbox)
                Stepper("\(floor)%", value: $floor, in: 5...80, step: 5).monospacedDigit().fixedSize().disabled(!floorOn)
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    guard PowerConfirm.ask("Keep your Mac awake with the lid closed?",
                                           "Your Mac will keep running with the lid shut and may get warm. Do not put it in a bag or enclosed space. You'll be asked for your password once.",
                                           confirm: "Keep Awake", destructive: true) else { return }
                    Task {
                        await scheduler.enableClosedLid(duration: minutes > 0 ? Double(minutes) * 60 : nil,
                                                        batteryFloor: floorOn ? floor : nil)
                    }
                } label: {
                    Label("Keep Awake with Lid Closed", systemImage: "laptopcomputer")
                }
                .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF9F0A)))
                .disabled(scheduler.lidBusy || scheduler.lidState == .unknown)
                if scheduler.lidBusy { ProgressView().controlSize(.small) }
            }
        }
    }
}

// MARK: - Sleep / wake history

private struct PowerHistorySection: View {
    let model: PowerHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Sleep and wake history", symbol: "clock.arrow.circlepath")
                Spacer()
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.mmGhost).disabled(model.loading).help("Reload")
            }
            if let s = model.summary {
                if s.events.isEmpty {
                    EmptyStateView(symbol: "moon.zzz", title: "No sleep or wake events",
                                   message: "macOS has nothing logged for the last 3 days.")
                        .card()
                } else {
                    stats(s)
                    timeline(s)
                    if !s.topReasons.isEmpty { reasons(s) }
                    recent(s)
                }
            } else if model.loading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the power log…").foregroundStyle(.secondary) }
                    .card()
            } else if model.failed {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't read the power log",
                               message: "pmset returned no sleep or wake data.")
                    .card()
            }
        }
    }

    private func stats(_ s: PowerHistorySummary) -> some View {
        let total = s.awakeSeconds + s.asleepSeconds
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.spacing)], spacing: Theme.spacing) {
            StatTile(title: "Wakes", value: "\(s.wakes)", caption: "Full wakes, last 3 days",
                     symbol: "sun.max.fill", colors: Theme.Palette.green)
            StatTile(title: "Dark wakes", value: "\(s.darkWakes)", caption: "Background wakes",
                     symbol: "moon.stars.fill", colors: Theme.Palette.orange)
            StatTile(title: "Sleeps", value: "\(s.sleeps)", caption: "Times the Mac slept",
                     symbol: "moon.fill", colors: Theme.Palette.indigo)
            StatTile(title: "Asleep", value: total > 0 ? Fmt.percent(s.asleepSeconds / total) : "–",
                     caption: total > 0 ? Fmt.duration(s.asleepSeconds) + " of logged time" : nil,
                     symbol: "bed.double.fill", colors: Theme.Palette.purple)
        }
    }

    private func timeline(_ s: PowerHistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(s.pieces) { p in
                BarMark(xStart: .value("Start", p.startHour), xEnd: .value("End", p.endHour),
                        y: .value("Day", p.day), height: .fixed(20))
                    .foregroundStyle(by: .value("State", p.state.rawValue))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .chartForegroundStyleScale(domain: PowerTimelineState.allCases.map(\.rawValue),
                                       range: PowerTimelineState.allCases.map(\.color))
            .chartXScale(domain: 0...24)
            .chartYScale(domain: s.dayLabels)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20, 24]) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = v.as(Int.self) { Text(String(format: "%02d:00", h % 24)).font(.caption2) }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: CGFloat(max(1, s.dayLabels.count)) * 40 + 56)
        }
        .card()
    }

    private func reasons(_ s: PowerHistorySummary) -> some View {
        let top = max(1, s.topReasons.first?.count ?? 1)
        return GroupedSection("Top wake reasons", symbol: "bolt.badge.clock") {
            ForEach(s.topReasons, id: \.reason) { r in
                HStack(spacing: 12) {
                    Text(r.reason).font(.callout).lineLimit(1).frame(width: 200, alignment: .leading)
                    CapsuleBar(fraction: Double(r.count) / Double(top), color: Theme.Palette.cpu, height: 6)
                    Text("\(r.count)").font(.callout.weight(.semibold)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func recent(_ s: PowerHistorySummary) -> some View {
        let recent = Array(s.events.suffix(14).reversed())
        return GroupedSection("Recent events", symbol: "list.bullet") {
            ForEach(recent) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.kind == .sleep ? "moon.fill" : (e.kind == .darkWake ? "moon.stars.fill" : "sun.max.fill"))
                        .foregroundStyle(e.kind == .sleep ? Color(hex: 0x5856D6) : (e.kind == .darkWake ? Color(hex: 0xFF9F0A) : Color(hex: 0x30D158)))
                        .frame(width: 20)
                    Text(e.kind == .sleep ? "Sleep" : (e.kind == .darkWake ? "Dark wake" : "Wake")).font(.callout.weight(.medium))
                        .frame(width: 80, alignment: .leading)
                    Text(PowerParsers.friendlyReason(e.reason)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(PowerFmt.dayTime(e.date)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }
}
