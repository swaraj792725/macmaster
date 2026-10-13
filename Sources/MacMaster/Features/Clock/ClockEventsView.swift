import SwiftUI
import AppKit
import EventKit

/// Events under the month grid: next-event line, the selected day's events, or a grant button.
struct ClockEventsSection: View {
    let model: ClockEventsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.authorized {
                permissionCard
            } else {
                if let next = ClockEventText.next(in: model.upcoming, now: Date()) { nextLine(next) }
                dayHeader
                let list = model.dayEvents
                if list.isEmpty {
                    Text(model.loaded ? "No events" : "Loading\u{2026}").font(.callout).foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 2) { ForEach(list) { ClockEventRow(event: $0) } }
                }
            }
        }
    }

    private var permissionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("See your events here").font(.callout.weight(.medium))
                Text(model.canPrompt ? "Allow calendar access to show today's events and join links."
                                     : "Calendar access is off. Turn it on in System Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(model.canPrompt ? "Grant" : "Open Settings") { model.request() }.buttonStyle(.mmSecondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func nextLine(_ e: ClockEvent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.fill").font(.caption2).foregroundStyle(Color.accentColor)
            Text("Next: \(e.title) \(ClockEventText.relative(e, now: Date()))")
                .font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    private var dayHeader: some View {
        let cal = Calendar.autoupdatingCurrent
        let title = cal.isDateInToday(model.selectedDay) ? "Today"
            : cal.isDateInTomorrow(model.selectedDay) ? "Tomorrow"
            : model.selectedDay.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct ClockEventRow: View {
    let event: ClockEvent
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.swiftUIColor).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let loc = event.location, event.joinURL == nil || !loc.lowercased().hasPrefix("http") {
                    Label(loc, systemImage: "mappin").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 6)
            if let url = event.joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                    ClockMenuBar.shared.close()
                } label: { Label("Join", systemImage: "video.fill") }
                .buttonStyle(.mmSecondary)
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .help(event.calendar)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.start.formatted(f)) \u{2013} \(event.end.formatted(f))"
    }
}
