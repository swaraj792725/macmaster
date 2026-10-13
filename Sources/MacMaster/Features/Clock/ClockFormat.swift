import Foundation

/// Time-zone helpers shared by the popover and settings.
enum ClockZones {
    struct Entry: Identifiable, Sendable {
        let id: String
        let city: String
        let region: String
        let key: String   // lowercased search text
    }

    static func city(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    static func region(_ id: String) -> String {
        let parts = id.split(separator: "/")
        return parts.count > 1 ? parts[0].replacingOccurrences(of: "_", with: " ") : ""
    }

    /// "New York" -> "NY", "Tokyo" -> "TOK".
    static func shortLabel(_ id: String) -> String {
        let words = city(id).split(separator: " ")
        if words.count > 1 { return words.compactMap(\.first).map { String($0) }.joined().uppercased() }
        return String(city(id).prefix(3)).uppercased()
    }

    /// Abbreviation like "EDT", or a short city label when macOS only has "GMT-4".
    static func abbreviation(_ tz: TimeZone, at date: Date) -> String {
        let a = tz.abbreviation(for: date) ?? ""
        return a.isEmpty || a.hasPrefix("GMT") || a.hasPrefix("UTC") && a.count > 3 ? shortLabel(tz.identifier) : a
    }

    /// "GMT+5:30".
    static func offsetString(_ tz: TimeZone, at date: Date) -> String {
        let s = tz.secondsFromGMT(for: date)
        if s == 0 { return "GMT" }
        let a = abs(s)
        let m = (a % 3600) / 60
        return "GMT\(s < 0 ? "-" : "+")\(a / 3600)" + (m == 0 ? "" : ":" + String(format: "%02d", m))
    }

    /// "Same time", "3h ahead", "5h 30m behind" relative to this Mac's zone.
    static func relative(_ tz: TimeZone, at date: Date) -> String {
        let diff = tz.secondsFromGMT(for: date) - TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
        if diff == 0 { return "Same time" }
        let a = abs(diff), h = a / 3600, m = (a % 3600) / 60
        let span = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
        return "\(span) \(diff > 0 ? "ahead" : "behind")"
    }

    /// "Today", "Tomorrow" or "Yesterday" relative to the local calendar day.
    static func dayLabel(_ tz: TimeZone, at date: Date) -> String {
        let t = date.timeIntervalSince1970
        func day(_ z: TimeZone) -> Int { Int(((t + Double(z.secondsFromGMT(for: date))) / 86_400).rounded(.down)) }
        switch day(tz) - day(.autoupdatingCurrent) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let n: return n > 0 ? "+\(n) days" : "\(n) days"
        }
    }

    static func isDay(_ tz: TimeZone, at date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let h = cal.component(.hour, from: date)
        return h >= 6 && h < 18
    }

    /// Searchable list, built once on first use (localized names make it a few ms).
    static let index: [Entry] = {
        let now = Date()
        return TimeZone.knownTimeZoneIdentifiers
            .filter { !$0.hasPrefix("Etc/") && !$0.hasPrefix("SystemV/") }
            .compactMap { id -> Entry? in
                guard let tz = TimeZone(identifier: id) else { return nil }
                let long = tz.localizedName(for: .generic, locale: .current) ?? ""
                let key = [id.replacingOccurrences(of: "_", with: " "), long, tz.abbreviation(for: now) ?? ""]
                    .joined(separator: " ").lowercased()
                return Entry(id: id, city: city(id), region: region(id), key: key)
            }
            .sorted { $0.city < $1.city }
    }()
}

/// Builds the menu bar string. DateFormatters are reused and only rebuilt when the pattern changes.
@MainActor
final class ClockFormatter {
    static let shared = ClockFormatter()

    private let main = DateFormatter()
    private let second = DateFormatter()
    private var mainPattern = "", secondPattern = "", secondZone = ""

    private init() {
        for f in [main, second] { f.locale = .autoupdatingCurrent; f.timeZone = .autoupdatingCurrent }
    }

    /// Pattern for the time part only.
    static func timePattern(_ s: ClockSettings, seconds: Bool) -> String {
        if s.use24h { return seconds ? "HH:mm:ss" : "HH:mm" }
        let base = seconds ? "h:mm:ss" : "h:mm"
        return s.showAMPM ? base + " a" : base
    }

    static func pattern(_ s: ClockSettings) -> String {
        if s.useCustomPattern, !s.customPattern.isEmpty { return s.customPattern }
        var parts: [String] = []
        if s.showWeekday { parts.append("EEE") }
        if s.showDate { parts.append("d MMM") }
        parts.append(timePattern(s, seconds: s.showSeconds))
        return parts.joined(separator: " ")
    }

    /// True when the pattern has an (unquoted) seconds field, so the timer must tick every second.
    static func patternShowsSeconds(_ p: String) -> Bool {
        var inQuote = false
        for ch in p {
            if ch == "'" { inQuote.toggle() } else if !inQuote, ch == "s" || ch == "S" { return true }
        }
        return false
    }

    func string(for date: Date, settings s: ClockSettings) -> String {
        let p = Self.pattern(s)
        if p != mainPattern { main.dateFormat = p; mainPattern = p }
        var out = main.string(from: date)
        if s.showSecondZone, let tz = TimeZone(identifier: s.secondZoneID) {
            let sp = Self.timePattern(s, seconds: false)
            if sp != secondPattern { second.dateFormat = sp; secondPattern = sp }
            if secondZone != s.secondZoneID { second.timeZone = tz; secondZone = s.secondZoneID }
            let label = s.secondZoneLabel.trimmingCharacters(in: .whitespaces)
            out += " \u{00B7} " + (label.isEmpty ? ClockZones.abbreviation(tz, at: date) : label) + " " + second.string(from: date)
        }
        return out
    }
}
