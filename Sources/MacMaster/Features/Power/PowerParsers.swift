import Foundation
import AppKit

/// Pure parsing of command output. Every function ignores lines it does not understand,
/// so format changes in future macOS releases degrade to "fewer rows", never a crash.
enum PowerParsers {

    // MARK: top -o power

    /// Parses `top -l 2 ... -stats pid,command,power`. Uses the LAST sample (the first sample's
    /// power column is cumulative-since-boot and not meaningful).
    static func parseTop(_ output: String) -> [(pid: Int32, command: String, power: Double)] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Header line of each sample looks like "PID    COMMAND          POWER".
        var headerIndexes: [Int] = []
        for (i, l) in lines.enumerated() {
            let t = l.split(whereSeparator: \.isWhitespace)
            if t.first == "PID", t.last == "POWER" { headerIndexes.append(i) }
        }
        guard let start = headerIndexes.last else { return [] }
        var rows: [(Int32, String, Double)] = []
        for l in lines[(start + 1)...] {
            let t = l.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.count >= 3, let pid = Int32(t[0]), let power = Double(t[t.count - 1]) else { continue }
            let command = t[1..<(t.count - 1)].joined(separator: " ")
            rows.append((pid, command, power))
        }
        return rows
    }

    // MARK: pmset -g assertions

    static func parseAssertions(_ output: String) -> [PowerAssertion] {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*pid\s+(\d+)\((.+?)\):\s+\[(0x[0-9a-fA-F]+)\]\s+(\d+:\d+:\d+)\s+(\S+)\s+named:\s+"(.*)""#) else { return [] }
        var result: [PowerAssertion] = []
        var inList = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("Listed by owning process") { inList = true; continue }
            if !inList { continue }
            if line.hasPrefix("\t") || line.hasPrefix("    \t") {
                // Continuation (e.g. "Timeout will fire in 57 secs ..."): attach to previous row.
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, var last = result.popLast() {
                    last.detail = last.detail.map { $0 + " · " + t } ?? t
                    result.append(last)
                }
                continue
            }
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 7 else { continue }
            func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
            guard let pid = Int32(g(1)) else { continue }
            result.append(PowerAssertion(id: g(3) + "-" + g(1), pid: pid, processName: g(2), type: g(5),
                                         reason: g(6), age: parseClock(g(4)), detail: nil))
        }
        return result
    }

    /// "00:21:16" -> seconds.
    static func parseClock(_ s: String) -> TimeInterval {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 3 else { return 0 }
        return p[0] * 3600 + p[1] * 60 + p[2]
    }

    // MARK: pmset -g log

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// Parses Sleep / Wake / DarkWake lines. `since` bounds the work.
    static func parseSleepLog(_ output: String, since: Date, maxLines: Int = 6000) -> [PowerSleepEvent] {
        var events: [PowerSleepEvent] = []
        var seen = 0
        for raw in output.split(separator: "\n") {
            seen += 1
            if seen > maxLines { break }
            // "2026-10-12 18:01:18 +0530 DarkWake            DarkWake from Deep Idle ..."
            guard raw.count > 26, raw.first?.isNumber == true else { continue }
            let head = String(raw.prefix(25))
            guard let date = logDateFormatter.date(from: head), date >= since else { continue }
            // The tag column is padded and tab-terminated; multi-word tags ("Wake Requests") must not match "Wake".
            let rest = raw.dropFirst(26)
            let parts = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tag = parts[0].trimmingCharacters(in: .whitespaces)
            let kind: PowerSleepKind
            switch tag {
            case "Sleep": kind = .sleep
            case "Wake": kind = .wake
            case "DarkWake": kind = .darkWake
            default: continue
            }
            let body = String(parts[1]).trimmingCharacters(in: .whitespaces)
            events.append(PowerSleepEvent(date: date, kind: kind,
                                          reason: kind == .sleep ? sleepReason(body) : wakeReason(body)))
        }
        return events.sorted { $0.date < $1.date }
    }

    /// "Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt ..." -> "Idle Sleep"
    static func sleepReason(_ body: String) -> String {
        if let a = body.firstIndex(of: "'"), let b = body[body.index(after: a)...].firstIndex(of: "'") {
            let r = String(body[body.index(after: a)..<b])
            if !r.isEmpty { return r }
        }
        if let r = body.range(of: "due to ") {
            return trimReason(String(body[r.upperBound...]))
        }
        return "Sleep"
    }

    /// "DarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 ... rtc/Maintenance Using BATT (Charge:54%) 7 secs"
    static func wakeReason(_ body: String) -> String {
        guard let r = body.range(of: "due to ") else { return "Unknown" }
        return trimReason(String(body[r.upperBound...]))
    }

    private static func trimReason(_ s: String) -> String {
        var t = s
        for marker in [" Using ", " using "] {
            if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t"))
        if let slash = t.lastIndex(of: "/") {
            let tail = String(t[t.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { t = tail }
        }
        return t.isEmpty ? "Unknown" : t
    }

    /// Friendly wording for common wake reasons; unknown reasons are returned as-is.
    static func friendlyReason(_ r: String) -> String {
        let l = r.lowercased()
        if l.contains("useractivity") { return "You used the Mac" }
        if l.contains("lid") && l.contains("open") { return "Lid opened" }
        if l.contains("power button") || l.contains("powerbutton") { return "Power button" }
        if l.contains("maintenance") { return "Maintenance (Power Nap)" }
        if l.contains("sleepservice") || l.contains("sleep service") { return "Background sleep service" }
        if l.contains("ac attach") || l.contains("acattach") { return "Power adapter connected" }
        if l.contains("wifi") || l.contains("wlan") { return "Wi-Fi activity" }
        if l.contains("bluetooth") || l.contains("btle") { return "Bluetooth device" }
        if l.contains("hid") || l.contains("keyboard") { return "Keyboard or trackpad" }
        if l.contains("rtc") || l.contains("alarm") { return "Scheduled alarm" }
        if l.contains("idle sleep") { return "Idle timeout" }
        if l.contains("clamshell") { return "Lid closed" }
        if l.contains("software sleep") { return "Software request" }
        if l.contains("low battery") { return "Low battery" }
        return r
    }

    /// Builds the summary and day-by-day timeline from events.
    static func summarize(_ events: [PowerSleepEvent], now: Date = Date(), days: Int = 3) -> PowerHistorySummary {
        var s = PowerHistorySummary()
        s.events = events
        var reasons: [String: Int] = [:]
        for e in events {
            switch e.kind {
            case .sleep: s.sleeps += 1
            case .wake: s.wakes += 1; reasons[friendlyReason(e.reason), default: 0] += 1
            case .darkWake: s.darkWakes += 1; reasons[friendlyReason(e.reason), default: 0] += 1
            }
        }
        s.topReasons = reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(6).map { ($0.key, $0.value) }

        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: now) ?? now)

        // Day labels, oldest first.
        let labelFmt = DateFormatter()
        labelFmt.dateFormat = "EEE d MMM"
        var labels: [Date: String] = [:]
        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: i, to: windowStart) else { continue }
            let isToday = cal.isDateInToday(d), isYesterday = cal.isDateInYesterday(d)
            labels[d] = isToday ? "Today" : (isYesterday ? "Yesterday" : labelFmt.string(from: d))
            s.dayLabels.append(labels[d] ?? "")
        }

        // Turn events into state segments.
        struct Seg { var start: Date; var end: Date; var state: PowerTimelineState }
        var segs: [Seg] = []
        for (i, e) in events.enumerated() {
            let state: PowerTimelineState = e.kind == .sleep ? .asleep : (e.kind == .darkWake ? .dark : .awake)
            var end = i + 1 < events.count ? events[i + 1].date : now
            // The app is running now, so the machine is awake: never extend a final sleep to now.
            if i + 1 >= events.count, state == .asleep { end = e.date.addingTimeInterval(1) }
            if end > e.date { segs.append(Seg(start: e.date, end: end, state: state)) }
        }
        if let last = events.last, last.kind == .sleep, now > last.date.addingTimeInterval(1) {
            segs.append(Seg(start: last.date.addingTimeInterval(1), end: now, state: .awake))
        }

        // Split on midnight boundaries into hour-of-day pieces.
        for seg in segs {
            var start = max(seg.start, windowStart)
            let end = min(seg.end, now)
            guard end > start else { continue }
            let dur = end.timeIntervalSince(start)
            switch seg.state {
            case .asleep: s.asleepSeconds += dur
            default: s.awakeSeconds += dur
            }
            while start < end {
                let dayStart = cal.startOfDay(for: start)
                guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }
                let pieceEnd = min(end, nextDay)
                if let label = labels[dayStart] {
                    s.pieces.append(PowerTimelinePiece(
                        day: label,
                        startHour: start.timeIntervalSince(dayStart) / 3600,
                        endHour: pieceEnd.timeIntervalSince(dayStart) / 3600,
                        state: seg.state))
                }
                start = pieceEnd
            }
        }
        return s
    }

    // MARK: pmset -g custom

    static func parseCustom(_ output: String) -> PowerPmsetSnapshot {
        var snap = PowerPmsetSnapshot()
        var scope: PowerScope?
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":"), !line.hasPrefix(" ") {
                let l = trimmed.lowercased()
                if l.hasPrefix("battery") { scope = .battery }
                else if l.hasPrefix("ac") { scope = .adapter }
                else { scope = nil }
                continue
            }
            guard let scope else { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            // Keys with spaces ("Sleep On Power Button") have a non-numeric tail only on the last token.
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            snap.values[scope, default: [:]][parts[0]] = v
        }
        return snap
    }

    /// `pmset -g` reports "SleepDisabled 1" when closed-lid mode / disablesleep is on.
    static func parseSleepDisabled(_ output: String) -> Bool? {
        for raw in output.split(separator: "\n") {
            let parts = raw.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }

    // MARK: pmset -g sched

    /// Meaningful lines of `pmset -g sched`, trimmed; section headers are kept.
    static func parseSchedule(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
