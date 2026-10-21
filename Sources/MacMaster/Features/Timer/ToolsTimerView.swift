import SwiftUI
import AppKit

/// Timer & Stopwatch tool. Everything here only reads the engine; the engine owns the clock.
struct ToolsTimerView: View {
    private let engine = TimerEngine.shared
    @State private var customText = ""
    @State private var customLabel = ""
    @State private var customError = false

    @AppStorage(TimerPrefs.menuBar) private var menuBar = true
    @AppStorage(TimerPrefs.sound) private var soundName = "Glass"
    @AppStorage(TimerPrefs.notify) private var notify = true
    @AppStorage(TimerPrefs.banner) private var banner = true
    @AppStorage(TimerPrefs.pomoWork) private var pomoWork = 25
    @AppStorage(TimerPrefs.pomoShort) private var pomoShort = 5
    @AppStorage(TimerPrefs.pomoLong) private var pomoLong = 15
    @AppStorage(TimerPrefs.pomoCycles) private var pomoCycles = 4
    @AppStorage(TimerPrefs.pomoAuto) private var pomoAuto = true

    private let presets: [Int] = [1, 3, 5, 10, 15, 25, 45, 60]
    private var tint: Color { Theme.Palette.orange[1] }

    var body: some View {
        Page {
            startCard
            if !engine.timers.isEmpty { activeCard }
            pomodoroCard
            stopwatchCard
            alertSettings
        }
    }

    // MARK: Start

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Start a timer", symbol: "timer")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                ForEach(presets, id: \.self) { m in
                    Button { engine.startTimer(duration: TimeInterval(m * 60), label: customLabel) } label: {
                        Text(m >= 60 ? "\(m / 60) h" : "\(m) min").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.mmSecondary)
                }
            }
            HStack(spacing: 8) {
                TextField("Custom: 25m, 1h30, 90s", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startCustom)
                    .onChange(of: customText) { _, _ in customError = false }
                TextField("Label (optional)", text: $customLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startCustom)
                Button("Start", action: startCustom)
                    .buttonStyle(.mmPrimary(tint: tint))
                    .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if customError {
                Text("Couldn't read that. Try 25m, 1h30, 90s or 1:30.")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Text("The label is used for the presets too. Timers keep running if you quit MacMaster.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .searchAnchor("timer.start")
    }

    private func startCustom() {
        guard let secs = TimerParse.seconds(from: customText) else {
            if !customText.trimmingCharacters(in: .whitespaces).isEmpty { customError = true }
            return
        }
        engine.startTimer(duration: secs, label: customLabel)
        customText = ""
        customError = false
    }

    // MARK: Active timers

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Timers", symbol: "list.bullet")
                Spacer()
                if engine.timers.contains(where: { $0.status == .finished }) {
                    Button("Clear finished") { engine.clearFinished() }.buttonStyle(.mmGhost)
                }
            }
            ForEach(engine.timers) { t in
                TimerRowView(timer: t, tint: tint)
                if t.id != engine.timers.last?.id { HairlineDivider() }
            }
        }
        .card()
    }

    // MARK: Pomodoro

    private var pomodoroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Pomodoro", symbol: "brain.head.profile")
                Spacer()
                if let p = engine.pomodoroTimer {
                    StatusPill(text: p.pomodoro?.title ?? "Pomodoro", color: p.pomodoro == .work ? .orange : .green)
                    Button("Stop") { engine.stopPomodoro() }.buttonStyle(.mmSecondary)
                } else {
                    Button("Start Pomodoro") { engine.startPomodoro() }.buttonStyle(.mmPrimary(tint: tint))
                }
            }
            Text("Focus, short break, repeat. After a set number of focus sessions you get a long break.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    stepper("Focus", value: $pomoWork, range: 1...180, unit: "min")
                    stepper("Short break", value: $pomoShort, range: 1...60, unit: "min")
                }
                GridRow {
                    stepper("Long break", value: $pomoLong, range: 1...120, unit: "min")
                    stepper("Sessions before long break", value: $pomoCycles, range: 2...12, unit: "")
                }
            }
            Toggle("Start the next phase automatically", isOn: $pomoAuto)
                .toggleStyle(.switch)
        }
        .card()
        .searchAnchor("timer.pomodoro")
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout)
            Spacer(minLength: 4)
            Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Stepper("", value: value, in: range).labelsHidden()
        }
        .frame(minWidth: 220)
    }

    // MARK: Stopwatch

    private var stopwatchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Stopwatch", symbol: "stopwatch")
                Spacer()
                if !engine.swLaps.isEmpty {
                    Button { copyLaps() } label: { Label("Copy laps", systemImage: "doc.on.doc") }
                        .buttonStyle(.mmGhost)
                }
            }
            HStack(alignment: .center, spacing: 16) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.swRunning)) { ctx in
                    Text(TimerFormat.stopwatch(engine.swElapsed(at: ctx.date)))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Button(engine.swRunning ? "Stop" : (engine.swHasTime ? "Resume" : "Start")) { engine.swStartStop() }
                    .buttonStyle(.mmPrimary(tint: engine.swRunning ? .red : tint))
                Button("Lap") { engine.swLap() }
                    .buttonStyle(.mmSecondary)
                    .disabled(!engine.swRunning)
                Button("Reset") { engine.swReset() }
                    .buttonStyle(.mmSecondary)
                    .disabled(!engine.swHasTime)
            }
            if !engine.swLaps.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Lap").frame(width: 50, alignment: .leading)
                        Text("Split").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Total").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    HairlineDivider()
                    ForEach(engine.swLaps.reversed()) { lap in
                        HStack {
                            Text("\(lap.id)").frame(width: 50, alignment: .leading)
                            Text(TimerFormat.stopwatch(lap.split)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(TimerFormat.stopwatch(lap.total)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.callout).monospacedDigit()
                        .padding(.vertical, 5)
                        HairlineDivider()
                    }
                }
            }
        }
        .card()
        .searchAnchor("timer.stopwatch")
    }

    private func copyLaps() {
        let text = engine.swLapsText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToolsToastCenter.shared.show("Laps copied")
    }

    // MARK: Settings

    private var alertSettings: some View {
        GroupedSection("Alerts", symbol: "bell", footer: "Pick any macOS system sound. \"None\" keeps alerts silent.") {
            SettingsRow(title: "Show in menu bar", subtitle: "Remaining time of the soonest timer, only while one is running.",
                        symbol: "menubar.rectangle", colors: Theme.Palette.blue) {
                Toggle("", isOn: $menuBar).labelsHidden().toggleStyle(.switch)
                    .onChange(of: menuBar) { _, _ in TimerMenuBar.shared.update() }
            }
            HairlineDivider(leadingInset: 14)
            SettingsRow(title: "Sound", symbol: "speaker.wave.2.fill", colors: Theme.Palette.pink) {
                HStack(spacing: 8) {
                    Picker("", selection: $soundName) {
                        Text("None").tag("None")
                        ForEach(TimerSounds.systemNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                    Button { engine.playAlertSound(name: soundName) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.mmGhost).help("Preview")
                }
            }
            HairlineDivider(leadingInset: 14)
            SettingsRow(title: "Notification", subtitle: "A banner in Notification Center when a timer ends.",
                        symbol: "bell.badge.fill", colors: Theme.Palette.red) {
                Toggle("", isOn: $notify).labelsHidden().toggleStyle(.switch)
            }
            HairlineDivider(leadingInset: 14)
            SettingsRow(title: "\"Time's up\" banner and screen flash",
                        subtitle: "A banner with Stop and Snooze 5 min, and a gentle flash. Skipped with Reduce Motion.",
                        symbol: "rectangle.on.rectangle", colors: Theme.Palette.orange) {
                Toggle("", isOn: $banner).labelsHidden().toggleStyle(.switch)
            }
        }
        .searchAnchor("timer.alerts")
    }
}

// MARK: - Row

private struct TimerRowView: View {
    let timer: CountdownTimer
    let tint: Color
    private let engine = TimerEngine.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: timer.status != .running)) { ctx in
            let remaining = timer.remaining(at: ctx.date)
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(tint.opacity(0.15), lineWidth: 5)
                    Circle().trim(from: 0, to: 1 - timer.progress(at: ctx.date))
                        .stroke(timer.status == .finished ? Color.green : tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if timer.status == .finished {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                    }
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(timer.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(timer.status == .finished ? "Done" : TimerFormat.clock(remaining))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(timer.status == .paused ? .secondary : .primary)
                controls
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch timer.status {
        case .running: "Running"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            switch timer.status {
            case .running:
                iconButton("pause.fill", help: "Pause") { engine.pause(timer.id) }
            case .paused:
                iconButton("play.fill", help: "Resume") { engine.resume(timer.id) }
            case .finished:
                iconButton("arrow.counterclockwise", help: "Restart") { engine.restart(timer.id) }
            }
            if timer.status != .finished {
                Button("+1 min") { engine.addMinute(timer.id) }.buttonStyle(.mmGhost)
            }
            iconButton("xmark", help: timer.status == .finished ? "Remove" : "Cancel") { engine.cancel(timer.id) }
        }
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.mmGhost)
        .help(help)
    }
}
