import SwiftUI

// MARK: - Security & maintenance checklist

struct HealthChecklistCard: View {
    private let monitor = HealthMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Security & maintenance", symbol: "checklist")
                Spacer()
                if let d = monitor.checkupDate {
                    Text("Checked \(d, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            if monitor.checkup.isEmpty && !monitor.isCheckingUp {
                EmptyStateView(symbol: "stethoscope", title: "No checkup yet",
                               message: "Run a full checkup to verify disk health, encryption, backups, updates and security settings.")
                    .padding(.vertical, 6)
            } else {
                ForEach(monitor.checkup) { item in
                    HealthCheckRow(item: item)
                }
            }
        }
        .card()
    }
}

private struct HealthCheckRow: View {
    let item: HealthCheckItem

    private var color: Color {
        switch item.status {
        case .ok: .green
        case .warning: .orange
        case .info: .blue
        case .unknown, .running: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch item.status {
                case .running: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle.fill")
                case .warning: Image(systemName: "exclamationmark.triangle.fill")
                case .info: Image(systemName: "arrow.down.circle.fill")
                case .unknown: Image(systemName: "questionmark.circle")
                }
            }
            .foregroundStyle(color)
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout.weight(.medium))
                if item.status == .running {
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                } else if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.id == "backup", item.status == .unknown, !Permissions.isGranted(.fullDiskAccess) {
                    Button("Grant Full Disk Access") { Permissions.request(.fullDiskAccess) }
                        .controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Activity (sparklines + sleep blockers)

struct HealthActivityCard: View {
    private let monitor = HealthMonitor.shared

    private func pressureText(_ level: Int) -> String {
        level >= 4 ? "Critical" : level >= 2 ? "Warning" : "Normal"
    }

    var body: some View {
        let h = monitor.history
        let last = h.last
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Last hour", symbol: "chart.xyaxis.line")

            HealthTrendRow(title: "CPU", value: Fmt.percent(last?.cpu ?? 0),
                           values: h.map(\.cpu), color: Theme.Palette.cpu, maxValue: 1)
            HealthTrendRow(title: "Memory", value: Fmt.percent(last?.memUsed ?? 0),
                           caption: "Pressure: \(pressureText(last?.pressure ?? 1))",
                           values: h.map(\.memUsed), color: Theme.Palette.memory, maxValue: 1)
            let temps = h.compactMap(\.cpuTemp)
            HealthTrendRow(title: "Temperature", value: temps.last.map { Fmt.temperature($0) } ?? "—",
                           caption: temps.isEmpty ? "No sensor data" : nil,
                           values: temps, color: Theme.Palette.thermal, maxValue: 110)

            Divider()
            HStack {
                SectionTitle(text: "Apps preventing sleep", symbol: "moon.zzz")
                Spacer()
                Button { monitor.refreshAssertions() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if monitor.sleepBlockers.isEmpty {
                Text("Nothing is keeping your Mac awake.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.sleepBlockers) { b in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.app).font(.callout.weight(.medium))
                            Text("\(HealthAssertions.describe(b.type)) · \(b.reason)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(Fmt.duration(TimeInterval(b.seconds))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }
}

private struct HealthTrendRow: View {
    let title: String
    let value: String
    var caption: String? = nil
    let values: [Double]
    let color: Color
    let maxValue: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 110, alignment: .leading)
            if values.count >= 2 {
                Sparkline(values: values, color: color, maxValue: maxValue).frame(height: 44)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)).frame(height: 44)
            }
        }
    }
}

// MARK: - Event log

private enum HealthLogFilter: String, CaseIterable, Identifiable {
    case all = "All", issues = "Issues", resolved = "Resolved", actions = "Actions"
    var id: String { rawValue }
    func matches(_ e: HealthEvent) -> Bool {
        switch self {
        case .all: true
        case .issues: e.kind == .detected
        case .resolved: e.kind == .resolved
        case .actions: e.kind == .action
        }
    }
}

struct HealthLogCard: View {
    private let monitor = HealthMonitor.shared
    @State private var filter: HealthLogFilter = .all
    @State private var limit = 25

    var body: some View {
        let filtered = monitor.events.filter { filter.matches($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Event log", symbol: "list.bullet.rectangle")
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(HealthLogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Button("Clear") { monitor.clearLog() }
                    .controlSize(.small).disabled(monitor.events.isEmpty)
            }
            if filtered.isEmpty {
                Text("No events yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(filtered.prefix(limit)) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(color(e)).frame(width: 9, height: 9).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.callout.weight(.medium))
                            if !e.detail.isEmpty {
                                Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(Calendar.current.isDateInToday(e.date)
                             ? e.date.formatted(date: .omitted, time: .shortened)
                             : e.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if filtered.count > limit {
                    Button("Show more") { limit += 25 }.controlSize(.small)
                }
            }
        }
        .card()
    }

    private func color(_ e: HealthEvent) -> Color {
        switch e.kind {
        case .resolved: .green
        case .action: .purple
        case .info: e.severity == .info ? Color.secondary : e.severity.color
        case .detected: e.severity.color
        }
    }
}

// MARK: - Settings

struct HealthSettingsCard: View {
    @Bindable private var monitor = HealthMonitor.shared

    private func timeBinding(_ get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: get() / 60, minute: get() % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Settings", symbol: "slider.horizontal.3")

            Toggle("Monitor my Mac in the background", isOn: $monitor.monitoringEnabled)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Picker("", selection: $monitor.sensitivity) {
                        ForEach(HealthSensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                Text(monitor.sensitivity.blurb).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Toggle("Send notifications for warnings and critical issues", isOn: $monitor.notificationsEnabled)
            Toggle("Do not disturb (quiet hours)", isOn: $monitor.quietHoursEnabled)
            if monitor.quietHoursEnabled {
                HStack(spacing: 12) {
                    Text("From").foregroundStyle(.secondary)
                    DatePicker("", selection: timeBinding({ monitor.quietStartMinutes }, { monitor.quietStartMinutes = $0 }),
                               displayedComponents: .hourAndMinute).labelsHidden()
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("", selection: timeBinding({ monitor.quietEndMinutes }, { monitor.quietEndMinutes = $0 }),
                               displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                }
                .padding(.leading, 20)
            }

            Divider()
            Text("Detection rules").font(.subheadline.weight(.semibold))
            ForEach(Array(HealthRules.all.enumerated()), id: \.offset) { _, rule in
                Toggle(isOn: Binding(get: { monitor.isRuleEnabled(rule.id) },
                                     set: { monitor.setRule(rule.id, enabled: $0) })) {
                    HStack(spacing: 10) {
                        Image(systemName: rule.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rule.title).font(.callout)
                            Text(rule.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !monitor.ignoredApps.isEmpty || !monitor.snoozedUntil.isEmpty {
                Divider()
                if !monitor.ignoredApps.isEmpty {
                    Text("Ignored apps").font(.subheadline.weight(.semibold))
                    HealthFlowLayout(spacing: 6) {
                        ForEach(monitor.ignoredApps, id: \.self) { app in
                            Button { monitor.unignoreApp(app) } label: {
                                Label(app, systemImage: "xmark.circle.fill").font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if !monitor.snoozedUntil.isEmpty {
                    HStack {
                        Text("\(monitor.snoozedUntil.count) snoozed alert\(monitor.snoozedUntil.count == 1 ? "" : "s")")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Clear snoozes") { monitor.clearSnoozes() }.controlSize(.small)
                    }
                }
            }
        }
        .card()
    }
}
