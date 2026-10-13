import SwiftUI
import AppKit

// MARK: - Power actions

/// Everything the Power feature can do to the machine.
enum PowerActionKind: String, CaseIterable, Identifiable, Codable {
    case sleep, displaySleep, lock, logOut, restart, shutDown, screenSaver
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: "Sleep"
        case .displaySleep: "Display Sleep"
        case .lock: "Lock Screen"
        case .logOut: "Log Out"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .screenSaver: "Screen Saver"
        }
    }

    var subtitle: String {
        switch self {
        case .sleep: "Put the Mac to sleep now"
        case .displaySleep: "Turn the screen off"
        case .lock: "Require your password"
        case .logOut: "End this session"
        case .restart: "Restart the Mac"
        case .shutDown: "Power off completely"
        case .screenSaver: "Start the screen saver"
        }
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .displaySleep: "display"
        case .lock: "lock.fill"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .restart: "arrow.clockwise"
        case .shutDown: "power"
        case .screenSaver: "sparkles.tv"
        }
    }

    var colors: [Color] {
        switch self {
        case .sleep: Theme.Palette.indigo
        case .displaySleep: Theme.Palette.blue
        case .lock: Theme.Palette.gray
        case .logOut: Theme.Palette.orange
        case .restart: Theme.Palette.yellow
        case .shutDown: Theme.Palette.red
        case .screenSaver: Theme.Palette.purple
        }
    }

    /// Needs an explicit confirmation before it may run.
    var isDestructive: Bool { self == .logOut || self == .restart || self == .shutDown }

    /// Verb phrase used in notifications and countdown labels ("Sleep", "Restart"…).
    var verb: String { title }
}

/// Actions a timer or automation may trigger (subset of `PowerActionKind`).
enum PowerTimedAction: String, CaseIterable, Identifiable, Codable {
    case sleep, restart, shutDown, logOut
    var id: String { rawValue }
    var kind: PowerActionKind {
        switch self {
        case .sleep: .sleep
        case .restart: .restart
        case .shutDown: .shutDown
        case .logOut: .logOut
        }
    }
    var title: String { kind.title }
    var symbol: String { kind.symbol }
    var colors: [Color] { kind.colors }
    /// "Sleeping", "Restarting"… used in warnings.
    var progressive: String {
        switch self {
        case .sleep: "sleep"
        case .restart: "restart"
        case .shutDown: "shut down"
        case .logOut: "log out"
        }
    }
}

// MARK: - Pending countdown (timer or automation warning)

struct PowerPending: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case timer, automation }
    var id: UUID = UUID()
    var source: Source
    var action: PowerTimedAction
    var created: Date
    var fireDate: Date
    /// Human reason, e.g. "Battery below 10%".
    var reason: String
    var warned: Bool = false

    var remaining: TimeInterval { max(0, fireDate.timeIntervalSinceNow) }
    var total: TimeInterval { max(1, fireDate.timeIntervalSince(created)) }
    var fractionRemaining: Double { min(1, max(0, remaining / total)) }
}

// MARK: - Automations

struct PowerAutomations: Codable, Equatable {
    // Sleep when battery drops below X%.
    var batteryEnabled = false
    var batteryPercent = 10
    // Sleep (or shut down) after a process quits.
    var processEnabled = false
    var processName = ""
    var processAction: PowerTimedAction = .sleep
    // Shut down when the Mac has been idle for N minutes.
    var idleEnabled = false
    var idleMinutes = 30
}

// MARK: - Energy users

struct PowerEnergyUser: Identifiable, Equatable {
    let id: String            // bundle path or command
    var name: String
    var power: Double         // summed "power" column from top
    var pids: [Int32]
    var bundlePath: String?
    var canQuit: Bool
}

// MARK: - Assertions

struct PowerAssertion: Identifiable, Equatable {
    let id: String
    var pid: Int32
    var processName: String
    var type: String
    var reason: String
    var age: TimeInterval
    var detail: String?

    /// Plain-language description of the assertion type.
    var typeTitle: String { PowerAssertionKind.title(for: type) }
    var blocksSleep: Bool { PowerAssertionKind.blocksSleep(type) }
}

enum PowerAssertionKind {
    private static let titles: [String: String] = [
        "PreventUserIdleSystemSleep": "Prevents sleep",
        "NoIdleSleepAssertion": "Prevents sleep",
        "PreventSystemSleep": "Prevents sleep (even with lid closed)",
        "PreventUserIdleDisplaySleep": "Keeps the display on",
        "NoDisplaySleepAssertion": "Keeps the display on",
        "PreventDiskIdle": "Keeps the disk spinning",
        "UserIsActive": "Counts you as active",
        "BackgroundTask": "Background task",
        "ApplePushServiceTask": "Push notification task",
        "InteractivePushServiceTask": "Push notification task",
        "NetworkClientActive": "Network in use",
        "ExternalMedia": "External media attached",
        "SoftwareUpdateTask": "Software update task",
        "MaintenanceWake": "Maintenance wake",
        "SystemIsActive": "System active",
        "EnableIdleSleep": "Allows idle sleep",
    ]
    private static let blockers: Set<String> = [
        "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep",
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "PreventDiskIdle",
    ]

    static func title(for type: String) -> String {
        if let t = titles[type] { return t }
        // "SomeCamelCaseType" -> "Some camel case type"
        var out = ""
        for (i, ch) in type.enumerated() {
            if ch.isUppercase, i > 0 { out.append(" ") }
            out.append(i == 0 ? ch : Character(ch.lowercased()))
        }
        return out.isEmpty ? "Assertion" : out
    }

    static func blocksSleep(_ type: String) -> Bool { blockers.contains(type) }
}

// MARK: - Sleep / wake history

enum PowerSleepKind: String { case sleep, wake, darkWake }

struct PowerSleepEvent: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var kind: PowerSleepKind
    var reason: String
}

enum PowerTimelineState: String, CaseIterable {
    case awake = "Awake", dark = "Dark wake", asleep = "Asleep"
    var color: Color {
        switch self {
        case .awake: Color(hex: 0x30D158)
        case .dark: Color(hex: 0xFF9F0A)
        case .asleep: Color(hex: 0x8E8E93).opacity(0.45)
        }
    }
}

/// One horizontal bar on the day-by-day timeline (hours 0…24 within a single day).
struct PowerTimelinePiece: Identifiable {
    let id = UUID()
    var day: String
    var startHour: Double
    var endHour: Double
    var state: PowerTimelineState
}

struct PowerHistorySummary {
    var events: [PowerSleepEvent] = []
    var pieces: [PowerTimelinePiece] = []
    var dayLabels: [String] = []
    var wakes = 0
    var darkWakes = 0
    var sleeps = 0
    var topReasons: [(reason: String, count: Int)] = []
    var awakeSeconds: TimeInterval = 0
    var asleepSeconds: TimeInterval = 0
}

// MARK: - pmset settings

enum PowerScope: String, CaseIterable, Identifiable {
    case battery, adapter
    var id: String { rawValue }
    var title: String { self == .battery ? "Battery" : "Power Adapter" }
    var flag: String { self == .battery ? "-b" : "-c" }
    var symbol: String { self == .battery ? "battery.75percent" : "powerplug.fill" }
}

enum PowerPmsetControl {
    case minutes            // 0 = Never
    case toggle
    case picker([(value: Int, label: String)])
}

struct PowerPmsetKey: Identifiable {
    let key: String
    let title: String
    let detail: String
    let symbol: String
    let colors: [Color]
    let control: PowerPmsetControl
    var id: String { key }

    static let all: [PowerPmsetKey] = [
        .init(key: "displaysleep", title: "Turn display off after",
              detail: "Idle time before the screen turns off. 0 means never.",
              symbol: "display", colors: Theme.Palette.blue, control: .minutes),
        .init(key: "sleep", title: "Put Mac to sleep after",
              detail: "Idle time before the whole system sleeps. 0 means never.",
              symbol: "moon.fill", colors: Theme.Palette.indigo, control: .minutes),
        .init(key: "disksleep", title: "Spin down disks after",
              detail: "Idle time before storage may power down. Mostly relevant to external drives.",
              symbol: "externaldrive.fill", colors: Theme.Palette.gray, control: .minutes),
        .init(key: "powernap", title: "Power Nap",
              detail: "Let the Mac wake briefly while asleep to fetch mail, calendar and iCloud updates.",
              symbol: "bed.double.fill", colors: Theme.Palette.teal, control: .toggle),
        .init(key: "tcpkeepalive", title: "TCP keep-alive during sleep",
              detail: "Keeps network connections such as Find My and Messages alive while asleep. Turning it off saves battery.",
              symbol: "network", colors: Theme.Palette.green, control: .toggle),
        .init(key: "womp", title: "Wake for network access",
              detail: "Allow the Mac to wake when another device sends it a network request.",
              symbol: "wifi", colors: Theme.Palette.blue, control: .toggle),
        .init(key: "lowpowermode", title: "Low Power Mode",
              detail: "Reduces performance and background activity to extend battery life.",
              symbol: "leaf.fill", colors: Theme.Palette.yellow, control: .toggle),
        .init(key: "standby", title: "Standby",
              detail: "After a long sleep, save memory to disk and power it down to preserve battery.",
              symbol: "powersleep", colors: Theme.Palette.purple, control: .toggle),
        .init(key: "hibernatemode", title: "Hibernation mode",
              detail: "How memory is protected during sleep. 3 is the laptop default; 25 writes everything to disk and powers RAM off (slowest wake, safest).",
              symbol: "memorychip", colors: Theme.Palette.orange,
              control: .picker([(0, "0 · Memory stays powered"), (3, "3 · Safe sleep (default)"), (25, "25 · Full hibernate")])),
        .init(key: "ttyskeepawake", title: "Stay awake for remote sessions",
              detail: "Prevent idle sleep while a Terminal or SSH session is active.",
              symbol: "terminal.fill", colors: Theme.Palette.gray, control: .toggle),
        .init(key: "lidwake", title: "Wake when lid opens",
              detail: "Wake the Mac when you open the lid.",
              symbol: "laptopcomputer", colors: Theme.Palette.mint, control: .toggle),
        .init(key: "acwake", title: "Wake when power is connected",
              detail: "Wake the Mac when the power adapter is plugged in.",
              symbol: "bolt.fill", colors: Theme.Palette.orange, control: .toggle),
        .init(key: "proximitywake", title: "Wake for nearby devices",
              detail: "Allow an iPhone or Apple Watch nearby to wake the Mac.",
              symbol: "iphone.radiowaves.left.and.right", colors: Theme.Palette.pink, control: .toggle),
    ]
}

/// Parsed `pmset -g custom` output: scope -> key -> integer value.
struct PowerPmsetSnapshot: Equatable {
    var values: [PowerScope: [String: Int]] = [:]
    var isEmpty: Bool { values.values.allSatisfy(\.isEmpty) }
}

// MARK: - Closed-lid state

enum PowerLidState: Equatable {
    case unknown
    case off
    case on(until: Date?, floor: Int?)      // started by MacMaster
    case external                           // SleepDisabled set by something else
}
