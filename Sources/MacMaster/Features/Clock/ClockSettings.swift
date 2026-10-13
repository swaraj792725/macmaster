import SwiftUI
import Observation

/// Quick format presets. Each one just sets the individual toggles.
enum ClockPreset: String, CaseIterable, Identifiable {
    case full, weekdayTime, time12, noMeridiem, seconds24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Mon 14 Oct 9:41 AM"
        case .weekdayTime: "Mon 9:41 AM"
        case .time12: "9:41 AM"
        case .noMeridiem: "9:41"
        case .seconds24: "09:41:05"
        }
    }

    /// weekday, date, seconds, 24h, AM/PM
    var flags: (weekday: Bool, date: Bool, seconds: Bool, h24: Bool, ampm: Bool) {
        switch self {
        case .full: (true, true, false, false, true)
        case .weekdayTime: (true, false, false, false, true)
        case .time12: (false, false, false, false, true)
        case .noMeridiem: (false, false, false, false, false)
        case .seconds24: (false, false, true, true, false)
        }
    }
}

/// Persistent settings for the Clock replacement (`mm.clock.*`).
@Observable
@MainActor
final class ClockSettings {
    static let shared = ClockSettings()

    private enum K {
        static let show = "mm.clock.show", h24 = "mm.clock.h24", seconds = "mm.clock.seconds"
        static let date = "mm.clock.date", weekday = "mm.clock.weekday", ampm = "mm.clock.ampm"
        static let customOn = "mm.clock.customOn", custom = "mm.clock.custom"
        static let secondOn = "mm.clock.secondOn", secondID = "mm.clock.secondZone", secondLabel = "mm.clock.secondLabel"
        static let world = "mm.clock.world", weeks = "mm.clock.weekNumbers", nextEvent = "mm.clock.nextEvent"
        static let worldMap = "mm.clock.worldMap"
    }

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: key)
        ClockMenuBar.shared.settingsChanged()
    }

    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: K.show); ClockMenuBar.shared.update() }
    }
    var use24h: Bool { didSet { save(use24h, K.h24) } }
    var showSeconds: Bool { didSet { save(showSeconds, K.seconds) } }
    var showDate: Bool { didSet { save(showDate, K.date) } }
    var showWeekday: Bool { didSet { save(showWeekday, K.weekday) } }
    var showAMPM: Bool { didSet { save(showAMPM, K.ampm) } }
    var useCustomPattern: Bool { didSet { save(useCustomPattern, K.customOn) } }
    var customPattern: String { didSet { save(customPattern, K.custom) } }
    var showSecondZone: Bool { didSet { save(showSecondZone, K.secondOn) } }
    var secondZoneID: String { didSet { save(secondZoneID, K.secondID) } }
    var secondZoneLabel: String { didSet { save(secondZoneLabel, K.secondLabel) } }
    var worldClocks: [String] { didSet { UserDefaults.standard.set(worldClocks, forKey: K.world) } }
    var showWeekNumbers: Bool { didSet { UserDefaults.standard.set(showWeekNumbers, forKey: K.weeks) } }
    /// Dotted day/night world map above the world clocks.
    var showWorldMap: Bool { didSet { UserDefaults.standard.set(showWorldMap, forKey: K.worldMap) } }
    /// Appends "· Standup in 12 min" to the menu bar title (needs Calendars access; off by default).
    var showNextEvent: Bool {
        didSet {
            save(showNextEvent, K.nextEvent)
            if showNextEvent, Permissions.calendarsCanPrompt { Permissions.request(.calendars) }
        }
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        showInMenuBar = d.bool(forKey: K.show)   // off until the user opts in
        use24h = bool(K.h24, false)
        showSeconds = bool(K.seconds, false)
        showDate = bool(K.date, true)
        showWeekday = bool(K.weekday, true)
        showAMPM = bool(K.ampm, true)
        useCustomPattern = bool(K.customOn, false)
        customPattern = d.string(forKey: K.custom) ?? "EEE d MMM HH:mm"
        showSecondZone = bool(K.secondOn, false)
        secondZoneID = d.string(forKey: K.secondID) ?? "America/New_York"
        secondZoneLabel = d.string(forKey: K.secondLabel) ?? ""
        worldClocks = (d.stringArray(forKey: K.world) ?? []).filter { TimeZone(identifier: $0) != nil }
        showWeekNumbers = bool(K.weeks, false)
        showWorldMap = bool(K.worldMap, true)
        showNextEvent = bool(K.nextEvent, false)
    }

    var currentPreset: ClockPreset? {
        ClockPreset.allCases.first {
            let f = $0.flags
            return !useCustomPattern && f.weekday == showWeekday && f.date == showDate
                && f.seconds == showSeconds && f.h24 == use24h && (use24h || f.ampm == showAMPM)
        }
    }

    func apply(_ p: ClockPreset) {
        let f = p.flags
        useCustomPattern = false
        showWeekday = f.weekday; showDate = f.date; showSeconds = f.seconds
        use24h = f.h24; showAMPM = f.ampm
    }

    func addWorldClock(_ id: String) {
        guard TimeZone(identifier: id) != nil, !worldClocks.contains(id) else { return }
        worldClocks.append(id)
    }

    func removeWorldClock(_ id: String) { worldClocks.removeAll { $0 == id } }
}
