import SwiftUI
import AppKit
import EventKit
import Combine

/// Popover content: big clock, then Calendar / World / System tabs.
struct ClockPopoverView: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 540

    private enum Tab: String, CaseIterable, Identifiable {
        case calendar = "Calendar", world = "World", system = "System"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .calendar
    @State private var settings = ClockSettings.shared
    @State private var events = ClockEventsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            switch tab {
            case .calendar: calendarTab
            case .world: ClockWorldTab()
            case .system: ClockSystemTab()
            }
        }
        .frame(width: Self.width, height: Self.height)
        // Fetch only while the popover is open: once on open, then when Calendar data changes.
        .task { events.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in events.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in events.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in events.reload() }
    }

    // The timeline only exists while the popover is open.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 2) {
                Text(ctx.date, format: .dateTime.hour(settings.use24h ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated))
                    .minute().second())
                    .font(.system(size: 38, weight: .light, design: .rounded).monospacedDigit())
                Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(TimeZone.current.identifier) \u{00B7} \(ClockZones.offsetString(.current, at: ctx.date))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 10)
        }
    }

    private var calendarTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ClockCalendarGrid(showWeekNumbers: settings.showWeekNumbers,
                                  selectedDay: events.selectedDay, eventDays: events.eventDays,
                                  onSelect: { events.select($0) }, onMonthChange: { events.monthChanged(to: $0) })
                Divider()
                ClockEventsSection(model: events)
                Divider()
                copyRow
                HStack {
                    Button("Open Calendar") {
                        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                            NSWorkspace.shared.openApplication(at: u, configuration: .init())
                        }
                        ClockMenuBar.shared.close()
                    }
                    .buttonStyle(.mmGhost)
                    Spacer()
                    Toggle("Week numbers", isOn: $settings.showWeekNumbers).toggleStyle(.switch).controlSize(.small).font(.caption)
                }
            }
            .padding(14)
        }
    }

    private var copyRow: some View {
        HStack(spacing: 8) {
            Text("Copy").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            copyButton("ISO 8601") {
                let f = ISO8601DateFormatter(); f.timeZone = .current
                f.formatOptions = [.withInternetDateTime]
                return f.string(from: Date())
            }
            copyButton("Unix") { String(Int(Date().timeIntervalSince1970)) }
            copyButton("Date") {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                return f.string(from: Date())
            }
            Spacer()
        }
    }

    private func copyButton(_ title: String, _ value: @escaping () -> String) -> some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value(), forType: .string)
        }
        .buttonStyle(.mmSecondary)
    }
}
