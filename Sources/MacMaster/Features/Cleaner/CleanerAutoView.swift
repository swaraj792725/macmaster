import SwiftUI

struct CleanerAutoView: View {
    private let scheduler = CleanerScheduler.shared
    @AppStorage(CleanerSettings.enabled) private var enabled = false
    @AppStorage(CleanerSettings.intervalDays) private var intervalDays = 7
    @AppStorage(CleanerSettings.categories) private var catRaw = CleanerSettings.defaultCategories
    @AppStorage(CleanerSettings.minAgeDays) private var minAgeDays = 3
    @AppStorage(CleanerSettings.onlyOnAC) private var onlyAC = true
    @AppStorage(CleanerSettings.onlyWhenIdle) private var onlyIdle = true
    @AppStorage(CleanerSettings.notify) private var notify = true
    @AppStorage(CleanerSettings.emptyTrash) private var emptyTrash = false
    @State private var confirmRunNow = false

    private var selected: Set<CleanerCategoryID> { CleanerSettings.parseCategories(catRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            mainCard
            if enabled { settingsCard }
            historyCard
        }
        .onChange(of: enabled) { _, on in if on { Notifier.requestAuthorization() } }
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "clock.badge.checkmark", colors: Theme.Palette.cleaner, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic cleaning").font(.title3.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(statusLine).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
            }
            Text("Runs in the background on a schedule, deleting only regenerable files from the categories you pick. Admin-only and review categories are never cleaned automatically.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { _ = await scheduler.runNow(manual: true) }
                } label: {
                    if scheduler.isRunning { ProgressView().controlSize(.small) } else { Text("Run now") }
                }
                .disabled(scheduler.isRunning || selected.isEmpty)
                if let s = scheduler.lastStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .card()
    }

    private var statusLine: String {
        guard enabled else { return "Off" }
        if scheduler.isRunning { return "Cleaning now…" }
        guard let next = scheduler.nextRunDate else { return "Off" }
        if next <= Date() { return "Due now — waiting for the right moment" }
        let f = DateComponentsFormatter()
        f.allowedUnits = next.timeIntervalSinceNow > 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return "Next clean in " + (f.string(from: max(60, next.timeIntervalSinceNow)) ?? "—")
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Schedule & rules", symbol: "slider.horizontal.3")
            Picker("Run every", selection: $intervalDays) {
                Text("Day").tag(1); Text("3 days").tag(3); Text("Week").tag(7)
            }
            .pickerStyle(.segmented).frame(maxWidth: 360)

            Text("Categories").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(CleanerCategoryID.allCases.filter(\.autoCleanEligible)) { c in
                    Toggle(isOn: Binding(
                        get: { selected.contains(c) },
                        set: { on in
                            var s = selected
                            if on { s.insert(c) } else { s.remove(c) }
                            catRaw = CleanerSettings.encode(s)
                        })) {
                        HStack(spacing: 8) { IconTile(symbol: c.symbol, colors: c.colors, size: 22); Text(c.title) }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Stepper(value: $minAgeDays, in: 0...90) {
                Text(minAgeDays == 0 ? "Delete files of any age" : "Only delete files not modified in the last \(minAgeDays) day\(minAgeDays == 1 ? "" : "s")")
            }
            Toggle("Only when plugged in to power", isOn: $onlyAC)
            Toggle("Only when the Mac is idle (2+ minutes without input)", isOn: $onlyIdle)
            Toggle("Notify me after cleaning", isOn: $notify)

            Divider()
            Toggle(isOn: $emptyTrash) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also empty the Trash automatically")
                    Text("Permanent. Items in the Trash that were not modified for the number of days above are deleted.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .card()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "History", symbol: "clock")
                Spacer()
                if scheduler.totalFreedAllTime > 0 {
                    Text("\(Fmt.bytes(scheduler.totalFreedAllTime)) freed in total").font(.caption).foregroundStyle(.secondary)
                }
                if !scheduler.history.isEmpty { Button("Clear") { scheduler.clearHistory() }.controlSize(.small) }
            }
            if scheduler.history.isEmpty {
                Text("No cleans yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(scheduler.history.prefix(12)) { e in
                    HStack(spacing: 10) {
                        Image(systemName: e.automatic ? "clock.arrow.circlepath" : "hand.tap")
                            .foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                            Text((e.automatic ? "Automatic" : "Manual") + " · " + e.categories.prefix(3).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if e.failureCount > 0 {
                            StatusPill(text: "\(e.failureCount) failed", color: .orange)
                        }
                        Text(Fmt.bytes(e.freed)).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .card()
    }
}
