import SwiftUI
import AppKit
import Observation

// MARK: - Schedule tab

struct PowerScheduleTab: View {
    @Bindable private var scheduler = PowerScheduler.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PowerTimerCard()
            PowerAutomationsSection(scheduler: scheduler)
            PowerSystemScheduleSection()
        }
        .onAppear { scheduler.start() }
    }
}

// MARK: - Timer

private struct PowerTimerCard: View {
    private let scheduler = PowerScheduler.shared
    @AppStorage("mm.power.timer.action") private var actionRaw = PowerTimedAction.sleep.rawValue
    @AppStorage("mm.power.timer.minutes") private var minutes = 30
    @AppStorage("mm.power.timer.useClock") private var useClock = false
    @State private var clockTime = Date().addingTimeInterval(3600)

    private var action: PowerTimedAction { PowerTimedAction(rawValue: actionRaw) ?? .sleep }
    private let presets = [10, 15, 30, 45, 60, 90, 120, 180]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "timer", colors: Theme.Palette.orange, size: 30)
                Text("Timer").font(.headline)
                Spacer()
            }
            if let t = scheduler.timer {
                active(t)
            } else {
                form
            }
        }
        .card()
    }

    private func active(_ t: PowerPending) -> some View {
        HStack(spacing: 28) {
            PowerCountdownRing(pending: t, size: 190)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Mac will \(t.action.progressive) at \(PowerFmt.time(t.fireDate)).")
                    .font(.title3.weight(.semibold))
                Text("You'll get a notification one minute before. Save your work.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Add 10 min") { scheduler.extendTimer(byMinutes: 10) }.buttonStyle(.mmSecondary)
                    Button("Cancel Timer") { scheduler.cancelTimer() }.buttonStyle(.mmPrimary(tint: Color(hex: 0xFF3B30)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: $actionRaw) {
                ForEach(PowerTimedAction.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Picker("When", selection: $useClock) {
                Text("In a number of minutes").tag(false)
                Text("At a time").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)

            if useClock {
                HStack(spacing: 12) {
                    DatePicker("Time", selection: $clockTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Text("Next \(PowerFmt.time(nextOccurrence(of: clockTime)))").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(minutes)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("minutes").font(.title3).foregroundStyle(.secondary)
                        Stepper("", value: $minutes, in: 1...1440, step: 5).labelsHidden()
                    }
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { m in
                            PowerChip(title: m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m) m") : "\(m) m",
                                      selected: minutes == m, tint: action.colors.last ?? .accentColor) { minutes = m }
                        }
                    }
                }
            }

            HStack {
                Button {
                    let date = useClock ? nextOccurrence(of: clockTime) : Date().addingTimeInterval(Double(minutes) * 60)
                    guard PowerConfirm.confirmSchedule(action, at: date) else { return }
                    scheduler.schedule(action, at: date)
                } label: {
                    Label("Start Timer", systemImage: "play.fill")
                }
                .buttonStyle(.mmPrimary(tint: action.colors.last ?? .accentColor))
                if action != .sleep {
                    Text("You'll be asked to confirm.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nextOccurrence(of time: Date) -> Date {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) ?? time
    }
}

// MARK: - Automations

private struct PowerAutomationsSection: View {
    @Bindable var scheduler: PowerScheduler
    @State private var runningApps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let w = scheduler.warning {
                HStack(spacing: 12) {
                    IconTile(symbol: "exclamationmark.triangle.fill", colors: Theme.Palette.orange, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("Mac will \(w.action.progressive) in \(PowerFmt.clock(w.remaining))")
                                .font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        Text(w.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { scheduler.cancelWarning() }.buttonStyle(.mmPrimary)
                }
                .card()
            }

            GroupedSection("When…", symbol: "wand.and.stars",
                           footer: "Automations are off by default. When one triggers you get a notification and 60 seconds to cancel here before anything happens.") {
                batteryRow
                processRow
                if scheduler.automations.processEnabled { processDetail }
                idleRow
            }
        }
    }

    private var batteryRow: some View {
        SettingsRow(title: "Sleep when battery is low",
                    subtitle: "Only while running on battery.",
                    symbol: "battery.25percent", colors: Theme.Palette.red) {
            HStack(spacing: 10) {
                if scheduler.automations.batteryEnabled {
                    Stepper("\(scheduler.automations.batteryPercent)%", value: $scheduler.automations.batteryPercent, in: 3...50)
                        .monospacedDigit().fixedSize()
                }
                Toggle("", isOn: $scheduler.automations.batteryEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var processRow: some View {
        SettingsRow(title: "Act after an app or process quits",
                    subtitle: "Handy for downloads, renders and exports.",
                    symbol: "arrow.down.app.fill", colors: Theme.Palette.blue) {
            Toggle("", isOn: $scheduler.automations.processEnabled).labelsHidden().toggleStyle(.switch)
        }
    }

    private var processDetail: some View {
        HStack(spacing: 10) {
            TextField("App or process name", text: $scheduler.automations.processName)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Menu("Running apps") {
                ForEach(runningApps, id: \.self) { name in
                    Button(name) { scheduler.automations.processName = name }
                }
            }
            .menuStyle(.button).fixedSize()
            .onAppear { refreshApps() }
            Picker("Then", selection: $scheduler.automations.processAction) {
                Text("Sleep").tag(PowerTimedAction.sleep)
                Text("Shut Down").tag(PowerTimedAction.shutDown)
            }
            .pickerStyle(.segmented).frame(width: 170)
            Spacer(minLength: 0)
        }
    }

    private var idleRow: some View {
        SettingsRow(title: "Shut down when the Mac is idle",
                    subtitle: "CPU quiet and no keyboard or mouse input for the chosen time.",
                    symbol: "moon.zzz.fill", colors: Theme.Palette.indigo) {
            HStack(spacing: 10) {
                if scheduler.automations.idleEnabled {
                    Stepper("\(scheduler.automations.idleMinutes) min", value: $scheduler.automations.idleMinutes, in: 5...480, step: 5)
                        .monospacedDigit().fixedSize()
                }
                Toggle("", isOn: Binding(
                    get: { scheduler.automations.idleEnabled },
                    set: { on in
                        if on {
                            guard PowerConfirm.ask("Shut down when idle?",
                                                   "Your Mac will shut down after it has been idle for \(scheduler.automations.idleMinutes) minutes. You get a 60 second warning first, but unsaved work may be lost.",
                                                   confirm: "Turn On", destructive: true) else { return }
                        }
                        scheduler.automations.idleEnabled = on
                    }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func refreshApps() {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        runningApps = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - System schedule (pmset repeat)

@Observable
@MainActor
private final class PowerSystemScheduleModel {
    private(set) var lines: [String] = []
    private(set) var loading = false
    private(set) var busy = false
    var error: String?

    func refresh() async {
        loading = true
        defer { loading = false }
        let r = await Shell.runAsync("/usr/bin/pmset", ["-g", "sched"], timeout: 10)
        lines = PowerParsers.parseSchedule(r.stdout)
    }

    func run(_ args: [String], prompt: String) async {
        busy = true; error = nil
        defer { busy = false }
        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/usr/bin/pmset", args, prompt: prompt)
        }.value
        if !r.ok, !r.stderr.lowercased().contains("cancel") { error = r.stderr.isEmpty ? "pmset failed." : r.stderr }
        await refresh()
    }
}

private struct PowerSystemScheduleSection: View {
    @State private var model = PowerSystemScheduleModel()

    @State private var wakeOn = false
    @State private var wakeKind = "wakeorpoweron"
    @State private var wakeDays: Set<String> = ["M", "T", "W", "R", "F"]
    @State private var wakeTime = PowerSystemScheduleSection.time(7, 0)

    @State private var offOn = false
    @State private var offKind = "sleep"
    @State private var offDays: Set<String> = ["M", "T", "W", "R", "F"]
    @State private var offTime = PowerSystemScheduleSection.time(23, 0)

    @State private var confirmCancel = false

    private static let days: [(code: String, name: String)] = [
        ("M", "Mon"), ("T", "Tue"), ("W", "Wed"), ("R", "Thu"), ("F", "Fri"), ("S", "Sat"), ("U", "Sun"),
    ]

    private static func time(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupedSection("System schedule", symbol: "calendar.badge.clock",
                           footer: "Handled by macOS itself (pmset), so it works even when MacMaster isn't running. Setting a schedule replaces any existing repeating schedule and needs your password.") {
                if model.lines.isEmpty {
                    SettingsRow(title: model.loading ? "Reading schedule…" : "Nothing scheduled",
                                subtitle: "No repeating or one-off power events are set.",
                                symbol: "calendar", colors: Theme.Palette.gray)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                eventEditor(title: "Wake or power on", symbol: "sunrise.fill", colors: Theme.Palette.orange,
                            enabled: $wakeOn, kind: $wakeKind,
                            kinds: [("wakeorpoweron", "Wake or power on"), ("wake", "Wake only"), ("poweron", "Power on only")],
                            days: $wakeDays, time: $wakeTime)
                eventEditor(title: "Sleep or shut down", symbol: "moon.fill", colors: Theme.Palette.indigo,
                            enabled: $offOn, kind: $offKind,
                            kinds: [("sleep", "Sleep"), ("shutdown", "Shut down")],
                            days: $offDays, time: $offTime)
                HStack(spacing: 10) {
                    Button("Apply Schedule") { Task { await apply() } }
                        .buttonStyle(.mmPrimary).disabled(!canApply || model.busy)
                    Button("Clear Schedule") { confirmCancel = true }
                        .buttonStyle(.mmSecondary).disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.mmGhost).help("Reload schedule")
                }
            }
            if let e = model.error {
                PowerCallout(symbol: "exclamationmark.triangle.fill", title: "Couldn't change the schedule", message: e)
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Clear the repeating schedule?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Clear Schedule", role: .destructive) {
                Task { await model.run(["repeat", "cancel"], prompt: "MacMaster wants to clear the repeating wake and sleep schedule.") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the repeating wake, power on, sleep and shut down events. You'll be asked for your password.")
        }
    }

    private var canApply: Bool {
        (wakeOn || offOn) && (!wakeOn || !wakeDays.isEmpty) && (!offOn || !offDays.isEmpty)
    }

    private func apply() async {
        var args = ["repeat"]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"
        func codes(_ s: Set<String>) -> String { Self.days.map(\.code).filter(s.contains).joined() }
        if wakeOn { args += [wakeKind, codes(wakeDays), f.string(from: wakeTime)] }
        if offOn { args += [offKind, codes(offDays), f.string(from: offTime)] }
        guard args.count > 1 else { return }
        await model.run(args, prompt: "MacMaster wants to set a repeating wake and sleep schedule.")
    }

    private func eventEditor(title: String, symbol: String, colors: [Color],
                             enabled: Binding<Bool>, kind: Binding<String>, kinds: [(String, String)],
                             days: Binding<Set<String>>, time: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(title: title, symbol: symbol, colors: colors) {
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch)
            }
            if enabled.wrappedValue {
                HStack(spacing: 12) {
                    Picker("Type", selection: kind) {
                        ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().fixedSize()
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    ForEach(Self.days, id: \.code) { d in
                        PowerChip(title: d.name, selected: days.wrappedValue.contains(d.code), tint: colors.last ?? .accentColor) {
                            if days.wrappedValue.contains(d.code) { days.wrappedValue.remove(d.code) }
                            else { days.wrappedValue.insert(d.code) }
                        }
                    }
                }
            }
        }
    }
}
