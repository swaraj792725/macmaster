import Foundation
import AppKit
import Observation
import os

// MARK: - Preferences

/// UserDefaults keys and defaults for Timer & Stopwatch (the view uses the same keys through `@AppStorage`).
enum TimerPrefs {
    static let menuBar = "mm.timer.menuBar"
    static let sound = "mm.timer.sound"
    static let notify = "mm.timer.notify"
    static let banner = "mm.timer.banner"
    static let pomoWork = "mm.timer.pomo.work"
    static let pomoShort = "mm.timer.pomo.short"
    static let pomoLong = "mm.timer.pomo.long"
    static let pomoCycles = "mm.timer.pomo.cycles"
    static let pomoAuto = "mm.timer.pomo.auto"
    static let state = "mm.timer.state"

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func int(_ key: String, _ fallback: Int) -> Int {
        let v = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return v
    }
    static var soundName: String { UserDefaults.standard.string(forKey: sound) ?? "Glass" }
}

// MARK: - Models

enum PomodoroPhase: String, Codable {
    case work, shortBreak, longBreak
    var title: String {
        switch self {
        case .work: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}

struct CountdownTimer: Identifiable, Codable, Equatable {
    enum Status { case running, paused, finished }

    var id = UUID()
    var label: String
    var duration: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?
    var finishedAt: Date?
    var pomodoro: PomodoroPhase?
    /// 1-based focus session number this timer belongs to (Pomodoro only).
    var pomoIndex: Int = 1

    var status: Status {
        if finishedAt != nil { return .finished }
        return endDate != nil ? .running : .paused
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        switch status {
        case .running: return max(0, (endDate ?? now).timeIntervalSince(now))
        case .paused: return max(0, pausedRemaining ?? duration)
        case .finished: return 0
        }
    }

    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        if status == .finished { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }
}

struct StopwatchLap: Identifiable, Equatable {
    let id: Int
    let split: TimeInterval
    let total: TimeInterval
}

struct TimerAlert: Identifiable, Equatable {
    let id: UUID          // timer id
    let label: String
    let snoozable: Bool
    let detail: String?
}

// MARK: - Formatting and parsing

enum TimerFormat {
    /// "4:32" or "1:04:32". Rounds up so a running timer shows 0:01 until it really finishes.
    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds).rounded(.up))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Stopwatch style: "01:23.45" or "1:01:23.45".
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let cs = Int((total * 100).rounded(.down))
        let h = cs / 360_000, m = (cs / 6000) % 60, s = (cs / 100) % 60, c = cs % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%02d:%02d.%02d", m, s, c)
    }

    static func minutesLabel(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m >= 60 && m % 60 == 0 { return "\(m / 60) h" }
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        return "\(m) min"
    }
}

enum TimerParse {
    private static let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*([a-z]*)"#)

    /// Natural durations: "25m", "1h30", "1h 30m", "90s", "1.5h", "25" (minutes), "1:30" (m:ss), "1:02:03" (h:m:s).
    static func seconds(from raw: String) -> TimeInterval? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40 else { return nil }

        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parts.contains(where: { $0 == nil }), parts.count == 2 || parts.count == 3 else { return nil }
            let v = parts.compactMap { $0 }
            let total = v.count == 2 ? v[0] * 60 + v[1] : v[0] * 3600 + v[1] * 60 + v[2]
            return valid(TimeInterval(total))
        }

        guard let regex else { return nil }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        // Anything left over once the matches are removed must be filler.
        var rest = s
        for m in matches.reversed() { rest = (rest as NSString).replacingCharacters(in: m.range, with: " ") }
        let filler = rest.replacingOccurrences(of: "and", with: "").replacingOccurrences(of: ",", with: "")
        guard filler.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var total: TimeInterval = 0
        var previousUnit: Character?
        for (i, m) in matches.enumerated() {
            let numText = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            let unitText = ns.substring(with: m.range(at: 2))
            guard let n = Double(numText) else { return nil }
            var unit: Character?
            if !unitText.isEmpty {
                switch unitText {
                case "h", "hr", "hrs", "hour", "hours": unit = "h"
                case "m", "min", "mins", "minute", "minutes": unit = "m"
                case "s", "sec", "secs", "second", "seconds": unit = "s"
                default: return nil
                }
            } else if i == matches.count - 1 {
                // Trailing bare number: "25" = minutes, "1h30" = minutes, "1m30" = seconds.
                switch previousUnit {
                case nil: unit = "m"
                case "h": unit = "m"
                case "m": unit = "s"
                default: return nil
                }
            } else {
                return nil
            }
            guard let u = unit else { return nil }
            // Units must go in descending order.
            if let p = previousUnit, rank(u) >= rank(p) { return nil }
            total += n * (u == "h" ? 3600 : u == "m" ? 60 : 1)
            previousUnit = u
        }
        return valid(total.rounded())
    }

    private static func rank(_ c: Character) -> Int { c == "h" ? 3 : c == "m" ? 2 : 1 }

    private static func valid(_ t: TimeInterval) -> TimeInterval? {
        (t >= 1 && t <= 99 * 3600) ? t : nil
    }
}

enum TimerSounds {
    /// Names of the system sounds (Glass, Ping, ...), empty if the folder can't be read.
    static let systemNames: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()
}

// MARK: - Engine

/// Countdown timers, Pomodoro and a stopwatch. Remaining time is always derived from the end date, and the
/// only timer that exists is a one-shot aimed at the next whole second (or the finish), and only while a timer runs.
@MainActor @Observable
final class TimerEngine {
    static let shared = TimerEngine()
    private static let log = Logger(subsystem: "com.macmaster.app", category: "timer")

    private(set) var timers: [CountdownTimer] = []
    private(set) var alerts: [TimerAlert] = []

    // Stopwatch
    private(set) var swStartedAt: Date?
    private(set) var swAccumulated: TimeInterval = 0
    private(set) var swLaps: [StopwatchLap] = []
    private(set) var swLastLapTotal: TimeInterval = 0

    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sound: NSSound?
    @ObservationIgnored private var soundTask: Task<Void, Never>?

    private init() {}

    var hasActiveTimers: Bool { timers.contains { $0.status != .finished } }
    var hasRunning: Bool { timers.contains { $0.status == .running } }
    var pomodoroTimer: CountdownTimer? { timers.first { $0.pomodoro != nil } }
    var swRunning: Bool { swStartedAt != nil }
    var swHasTime: Bool { swStartedAt != nil || swAccumulated > 0 }
    func swElapsed(at now: Date = Date()) -> TimeInterval {
        swAccumulated + (swStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// The running timer that finishes first (or the first paused one when nothing runs).
    func soonest() -> CountdownTimer? {
        let running = timers.filter { $0.status == .running }.sorted { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
        return running.first ?? timers.first { $0.status == .paused }
    }

    // MARK: Lifecycle

    /// Restores timers saved before the last quit. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        load()
        let now = Date()
        for id in timers.filter({ $0.status == .running && ($0.endDate ?? now) <= now }).map(\.id) {
            guard let i = index(id), let end = timers[i].endDate else { continue }
            // Finished while MacMaster was closed: only announce it if it just happened.
            finish(index: i, announce: now.timeIntervalSince(end) < 300, at: end)
        }
        changed()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TimerEngine.shared.tick() }
        }
    }

    // MARK: Timer actions

    @discardableResult
    func startTimer(duration: TimeInterval, label: String? = nil) -> UUID {
        let name = (label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? TimerFormat.minutesLabel(duration)
        var t = CountdownTimer(label: name, duration: duration)
        t.endDate = Date().addingTimeInterval(duration)
        timers.append(t)
        changed()
        return t.id
    }

    func pause(_ id: UUID) {
        guard let i = index(id), timers[i].status == .running else { return }
        timers[i].pausedRemaining = timers[i].remaining()
        timers[i].endDate = nil
        changed()
    }

    func resume(_ id: UUID) {
        guard let i = index(id), timers[i].status == .paused else { return }
        timers[i].endDate = Date().addingTimeInterval(timers[i].pausedRemaining ?? timers[i].duration)
        timers[i].pausedRemaining = nil
        changed()
    }

    func addMinute(_ id: UUID) {
        guard let i = index(id) else { return }
        switch timers[i].status {
        case .running:
            timers[i].endDate = timers[i].endDate?.addingTimeInterval(60)
            timers[i].duration += 60
        case .paused:
            timers[i].pausedRemaining = (timers[i].pausedRemaining ?? timers[i].duration) + 60
            timers[i].duration += 60
        case .finished:
            return
        }
        changed()
    }

    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        alerts.removeAll { $0.id == id }
        changed()
    }

    func restart(_ id: UUID) {
        guard let i = index(id) else { return }
        timers[i].finishedAt = nil
        timers[i].pausedRemaining = nil
        timers[i].endDate = Date().addingTimeInterval(timers[i].duration)
        alerts.removeAll { $0.id == id }
        changed()
    }

    /// Runs a finished timer again for `seconds` (the alert banner's Snooze).
    func snooze(_ id: UUID, seconds: TimeInterval = 300) {
        guard let i = index(id), timers[i].pomodoro == nil else { dismissAlert(id); return }
        timers[i].finishedAt = nil
        timers[i].endDate = Date().addingTimeInterval(seconds)
        alerts.removeAll { $0.id == id }
        changed()
    }

    /// Acknowledges an alert. A normal timer is removed from the list; Pomodoro phases already moved on.
    func dismissAlert(_ id: UUID) {
        alerts.removeAll { $0.id == id }
        if let i = index(id), timers[i].status == .finished { timers.remove(at: i) }
        changed()
    }

    func dismissAllAlerts() {
        for a in alerts { if let i = index(a.id), timers[i].status == .finished { timers.remove(at: i) } }
        alerts.removeAll()
        changed()
    }

    func clearFinished() {
        timers.removeAll { $0.status == .finished }
        changed()
    }

    // MARK: Pomodoro

    var pomoWorkMinutes: Int { max(1, TimerPrefs.int(TimerPrefs.pomoWork, 25)) }
    var pomoShortMinutes: Int { max(1, TimerPrefs.int(TimerPrefs.pomoShort, 5)) }
    var pomoLongMinutes: Int { max(1, TimerPrefs.int(TimerPrefs.pomoLong, 15)) }
    var pomoCycles: Int { max(1, TimerPrefs.int(TimerPrefs.pomoCycles, 4)) }
    var pomoAutoStart: Bool { TimerPrefs.bool(TimerPrefs.pomoAuto, true) }

    func startPomodoro() {
        stopPomodoro()
        addPomodoro(.work, index: 1, running: true)
        changed()
    }

    func stopPomodoro() {
        let ids = timers.filter { $0.pomodoro != nil }.map(\.id)
        timers.removeAll { $0.pomodoro != nil }
        alerts.removeAll { ids.contains($0.id) }
        changed()
    }

    private func addPomodoro(_ phase: PomodoroPhase, index: Int, running: Bool) {
        let minutes: Int
        switch phase {
        case .work: minutes = pomoWorkMinutes
        case .shortBreak: minutes = pomoShortMinutes
        case .longBreak: minutes = pomoLongMinutes
        }
        let session = ((index - 1) % pomoCycles) + 1
        let label = phase == .work ? "Focus \(session) of \(pomoCycles)" : phase.title
        var t = CountdownTimer(label: label, duration: TimeInterval(minutes * 60))
        t.pomodoro = phase
        t.pomoIndex = index
        if running { t.endDate = Date().addingTimeInterval(t.duration) } else { t.pausedRemaining = t.duration }
        timers.append(t)
    }

    // MARK: Stopwatch

    func swStartStop() {
        if let s = swStartedAt {
            swAccumulated += max(0, Date().timeIntervalSince(s))
            swStartedAt = nil
        } else {
            swStartedAt = Date()
        }
        TimerMenuBar.shared.update()
    }

    func swLap() {
        guard swRunning else { return }
        let total = swElapsed()
        swLaps.append(StopwatchLap(id: swLaps.count + 1, split: total - swLastLapTotal, total: total))
        swLastLapTotal = total
    }

    func swReset() {
        swStartedAt = nil
        swAccumulated = 0
        swLaps = []
        swLastLapTotal = 0
        TimerMenuBar.shared.update()
    }

    func swLapsText() -> String {
        guard !swLaps.isEmpty else { return "" }
        var lines = ["Lap\tSplit\tTotal"]
        for l in swLaps { lines.append("\(l.id)\t\(TimerFormat.stopwatch(l.split))\t\(TimerFormat.stopwatch(l.total))") }
        lines.append("Total\t\t\(TimerFormat.stopwatch(swElapsed()))")
        return lines.joined(separator: "\n")
    }

    // MARK: Ticking

    private func index(_ id: UUID) -> Int? { timers.firstIndex { $0.id == id } }

    /// Call after any change to `timers`: saves, re-aims the tick and refreshes the menu bar.
    private func changed() {
        save()
        schedule()
        TimerMenuBar.shared.update()
        TimerAlertController.shared.refresh()
    }

    private func schedule() {
        tickTimer?.invalidate(); tickTimer = nil
        guard let end = timers.filter({ $0.status == .running }).compactMap(\.endDate).min() else { return }
        let r = end.timeIntervalSinceNow
        // Aim at the moment the displayed second changes (or the finish, whichever comes first).
        let whole = r.rounded(.up)
        let fire = whole - 1 >= 0 ? end.addingTimeInterval(-(whole - 1)) : end
        let at = max(fire, Date().addingTimeInterval(0.05)).addingTimeInterval(0.01)
        let t = Timer(fire: at, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { TimerEngine.shared.tick() }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        let now = Date().addingTimeInterval(0.05)
        var any = false
        for id in timers.filter({ $0.status == .running && ($0.endDate ?? now) <= now }).map(\.id) {
            guard let i = index(id), let end = timers[i].endDate else { continue }
            finish(index: i, announce: true, at: end)
            any = true
        }
        if any {
            changed()
        } else {
            schedule()
            TimerMenuBar.shared.update()
        }
    }

    /// Marks the timer at `i` finished and runs its alert. May append (next Pomodoro phase) or remove (Pomodoro) timers.
    private func finish(index i: Int, announce: Bool, at: Date) {
        guard timers.indices.contains(i) else { return }
        var t = timers[i]
        t.finishedAt = at
        t.endDate = nil
        t.pausedRemaining = nil

        if let phase = t.pomodoro {
            // Phase done: queue the next one, remove this one, and tell the user.
            timers.remove(at: i)
            let next: (PomodoroPhase, Int)
            switch phase {
            case .work: next = (t.pomoIndex % pomoCycles == 0 ? .longBreak : .shortBreak, t.pomoIndex)
            case .shortBreak, .longBreak: next = (.work, t.pomoIndex + 1)
            }
            addPomodoro(next.0, index: next.1, running: pomoAutoStart)
            if announce {
                let detail = pomoAutoStart ? "\(next.0.title) started." : "\(next.0.title) is ready."
                raise(TimerAlert(id: t.id, label: "\(t.label) complete", snoozable: false, detail: detail), title: "\(t.label) complete", body: detail)
            }
            return
        }

        timers[i] = t
        if announce {
            raise(TimerAlert(id: t.id, label: t.label, snoozable: true, detail: nil), title: t.label, body: "Time's up")
        }
    }

    private func raise(_ alert: TimerAlert, title: String, body: String) {
        alerts.removeAll { $0.id == alert.id }
        alerts.append(alert)
        if TimerPrefs.bool(TimerPrefs.notify, true) { Notifier.post(title: title, body: body, id: "timer-\(alert.id.uuidString)", sound: false) }
        playAlertSound()
    }

    // MARK: Sound

    func playAlertSound(name: String? = nil) {
        let n = name ?? TimerPrefs.soundName
        guard !n.isEmpty, n != "None", let s = NSSound(named: NSSound.Name(n)) else { return }
        sound?.stop()
        sound = s
        s.play()
        guard name == nil else { return }
        // Gentle reminder while the banner is still up.
        soundTask?.cancel()
        soundTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self, !self.alerts.isEmpty else { return }
                self.sound?.stop(); self.sound?.play()
            }
        }
    }

    func stopAlertSound() {
        soundTask?.cancel(); soundTask = nil
        sound?.stop()
    }

    // MARK: Persistence

    private func save() {
        let keep = timers.filter { $0.status != .finished }
        if keep.isEmpty { UserDefaults.standard.removeObject(forKey: TimerPrefs.state); return }
        if let data = try? JSONEncoder().encode(keep) { UserDefaults.standard.set(data, forKey: TimerPrefs.state) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: TimerPrefs.state) else { return }
        do { timers = try JSONDecoder().decode([CountdownTimer].self, from: data) }
        catch { Self.log.error("Could not restore timers: \(error.localizedDescription)") }
    }
}

extension AppSearchIndex {
    /// Timer & Stopwatch settings, added to the global search.
    static let timerEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Timer", "Countdown timers", "timer countdown minutes alarm preset 25m 5 min", tab: "timer"),
        SearchEntry(.tools, crumb: "Timer", "Pomodoro", "pomodoro focus break work session productivity", tab: "timer"),
        SearchEntry(.tools, crumb: "Timer", "Stopwatch and laps", "stopwatch lap split time", tab: "timer"),
        SearchEntry(.tools, crumb: "Timer", "Timer in menu bar", "timer menu bar remaining countdown status item", tab: "timer"),
        SearchEntry(.tools, crumb: "Timer", "Timer alert sound", "timer sound alarm chime notification banner flash snooze", tab: "timer"),
    ]
}
