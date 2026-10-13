import SwiftUI
import AppKit
import EventKit
import Observation

/// One calendar event, flattened so it can cross actors and be drawn without touching EventKit again.
struct ClockEvent: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let color: [Double]        // sRGB r, g, b
    let location: String?
    let joinURL: URL?

    var swiftUIColor: Color { Color(.sRGB, red: color[0], green: color[1], blue: color[2]) }
}

/// Thin EventKit wrapper. Reads only; nothing is cached on disk and nothing polls.
final class CalendarEvents: @unchecked Sendable {
    static let shared = CalendarEvents()
    private let store = EKEventStore()
    private init() {}

    /// Shows the system prompt (only while the status is undetermined).
    func requestAccess() async -> Bool {
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        if ok { store.reset() }
        return ok
    }

    /// Events overlapping [from, to), earliest first (all-day first). Empty when access is missing.
    /// EventKit's fetch is synchronous, so call this from a background context.
    func events(from: Date, to: Date) -> [ClockEvent] {
        guard Permissions.calendarsGranted else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred).compactMap { ev -> ClockEvent? in
            if ev.status == .canceled { return nil }
            if ev.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { return nil }
            let c = ev.calendar?.color?.usingColorSpace(.sRGB)
            let loc = ev.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClockEvent(
                id: (ev.eventIdentifier ?? UUID().uuidString) + "@\(Int(ev.startDate.timeIntervalSince1970))",
                title: (ev.title ?? "").isEmpty ? "Untitled" : ev.title,
                start: ev.startDate, end: ev.endDate, isAllDay: ev.isAllDay,
                calendar: ev.calendar?.title ?? "",
                color: [c?.redComponent ?? 0.35, c?.greenComponent ?? 0.5, c?.blueComponent ?? 0.9].map(Double.init),
                location: (loc?.isEmpty ?? true) ? nil : loc,
                joinURL: Self.joinURL(url: ev.url, location: ev.location, notes: ev.notes))
        }
        .sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.start < b.start
        }
    }

    // MARK: Join links

    private static let joinHosts = ["zoom.us", "zoom.com", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                    "webex.com", "whereby.com", "gotomeeting.com", "bluejeans.com"]

    /// First Zoom / Meet / Teams (etc.) link in the event URL, location or notes.
    static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        func isJoin(_ u: URL) -> Bool {
            guard let h = u.host?.lowercased(), u.scheme?.hasPrefix("http") == true else { return false }
            return joinHosts.contains { h == $0 || h.hasSuffix("." + $0) }
        }
        if let url, isJoin(url) { return url }
        if url?.scheme == "zoommtg" { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let hit = detector?.matches(in: text, range: range).compactMap(\.url).first(where: isJoin)
            if let hit { return hit }
        }
        return nil
    }
}

enum ClockEventText {
    /// "12 min", "1 h 5 min", "3 h", "2 days".
    static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        if m < 60 { return "\(m) min" }
        if m < 60 * 24 {
            let h = m / 60, r = m % 60
            return r == 0 ? "\(h) h" : "\(h) h \(r) min"
        }
        let d = m / (60 * 24)
        return d == 1 ? "1 day" : "\(d) days"
    }

    /// "in 12 min" / "now" for a timed event.
    static func relative(_ e: ClockEvent, now: Date) -> String {
        if e.start <= now { return "now" }
        return "in " + span(e.start.timeIntervalSince(now))
    }

    /// First event that has not ended yet (timed events only).
    static func next(in events: [ClockEvent], now: Date) -> ClockEvent? {
        events.filter { !$0.isAllDay && $0.end > now }.min { $0.start < $1.start }
    }
}

// MARK: - Popover model

/// State for the Calendar tab. Lives only while the popover is open; reloads on open, on month change
/// and on `EKEventStoreChanged`.
@MainActor @Observable
final class ClockEventsModel {
    private(set) var authorized = Permissions.calendarsGranted
    private(set) var canPrompt = Permissions.calendarsCanPrompt
    private(set) var loaded = false
    var selectedDay = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    private(set) var visibleMonth = ClockEventsModel.monthStart(Date())
    private(set) var monthEvents: [ClockEvent] = []
    private(set) var upcoming: [ClockEvent] = []
    @ObservationIgnored private var generation = 0

    private static func monthStart(_ d: Date) -> Date {
        let cal = Calendar.autoupdatingCurrent
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    var dayEvents: [ClockEvent] {
        let cal = Calendar.autoupdatingCurrent
        let s = cal.startOfDay(for: selectedDay)
        guard let e = cal.date(byAdding: .day, value: 1, to: s) else { return [] }
        return monthEvents.filter { $0.start < e && $0.end > s || ($0.start == $0.end && $0.start >= s && $0.start < e) }
    }

    /// Start-of-day for every day in the visible month that has at least one event.
    var eventDays: Set<Date> {
        let cal = Calendar.autoupdatingCurrent
        guard let monthEnd = cal.date(byAdding: .month, value: 1, to: visibleMonth) else { return [] }
        var out = Set<Date>()
        for e in monthEvents {
            var d = max(cal.startOfDay(for: e.start), visibleMonth)
            repeat {
                out.insert(d)
                guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = n
            } while d < e.end && d < monthEnd
        }
        return out
    }

    func monthChanged(to month: Date) {
        let cal = Calendar.autoupdatingCurrent
        visibleMonth = Self.monthStart(month)
        selectedDay = cal.isDate(Date(), equalTo: visibleMonth, toGranularity: .month) ? cal.startOfDay(for: Date()) : visibleMonth
        reload()
    }

    func select(_ day: Date) { selectedDay = Calendar.autoupdatingCurrent.startOfDay(for: day) }

    func request() {
        if canPrompt {
            Task { _ = await CalendarEvents.shared.requestAccess(); reload() }
        } else {
            NSWorkspace.shared.open(Permission.calendars.settingsURL)
        }
    }

    func reload() {
        authorized = Permissions.calendarsGranted
        canPrompt = Permissions.calendarsCanPrompt
        guard authorized else { monthEvents = []; upcoming = []; loaded = true; return }
        let cal = Calendar.autoupdatingCurrent
        let from = visibleMonth
        let to = cal.date(byAdding: .month, value: 1, to: from) ?? from.addingTimeInterval(31 * 86_400)
        let now = Date()
        generation += 1
        let gen = generation
        Task {
            let (month, soon) = await Task.detached(priority: .userInitiated) {
                (CalendarEvents.shared.events(from: from, to: to),
                 CalendarEvents.shared.events(from: now, to: now.addingTimeInterval(7 * 86_400)))
            }.value
            guard gen == generation else { return }
            monthEvents = month
            upcoming = soon
            loaded = true
        }
    }
}

// MARK: - Menu bar "next event"

/// Keeps the next event for the menu bar title. Fetches on setting change, `EKEventStoreChanged`, wake and
/// day change, and when the cache is over an hour old; otherwise the minute tick just re-reads the cache.
@MainActor
final class ClockNextEvent {
    static let shared = ClockNextEvent()
    private var events: [ClockEvent] = []
    private var fetchedAt = Date.distantPast
    private var observing = false
    private var fetching = false

    private init() {}

    private var wanted: Bool { ClockSettings.shared.showNextEvent && Permissions.calendarsGranted }

    /// Starts or stops observation to match the setting. Cheap and idempotent.
    func sync() {
        let s = ClockSettings.shared.showNextEvent
        if s, !observing {
            observing = true
            let nc = NotificationCenter.default
            nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClockNextEvent.shared.fetch() }
            }
            nc.addObserver(forName: .calendarAuthorizationChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClockNextEvent.shared.fetch() }
            }
            for n in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange] {
                nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { ClockNextEvent.shared.fetch() }
                }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClockNextEvent.shared.fetch() }
            }
            fetch()
        } else if !s, observing {
            observing = false
            NotificationCenter.default.removeObserver(self)
            events = []
            fetchedAt = .distantPast
        }
    }

    /// " · Standup in 12 min" or "" (disabled, no permission, nothing within the next 90 minutes).
    func titleSuffix(now: Date) -> String {
        guard wanted else { return "" }
        if now.timeIntervalSince(fetchedAt) > 3600 { fetch() }
        guard let e = ClockEventText.next(in: events, now: now),
              e.start.timeIntervalSince(now) <= 90 * 60 else { return "" }
        var t = e.title
        if t.count > 22 { t = String(t.prefix(21)) + "\u{2026}" }
        return " \u{00B7} " + t + " " + ClockEventText.relative(e, now: now)
    }

    private func fetch() {
        guard wanted, !fetching else { return }
        fetching = true
        let now = Date()
        Task {
            let list = await Task.detached(priority: .utility) {
                CalendarEvents.shared.events(from: now, to: now.addingTimeInterval(24 * 3600))
            }.value
            events = list
            fetchedAt = Date()
            fetching = false
            ClockMenuBar.shared.titleChanged()
        }
    }
}
