import SwiftUI

// MARK: - Severity

enum HealthSeverity: Int, Codable, Comparable, CaseIterable {
    case info = 0, warning, critical

    static func < (a: HealthSeverity, b: HealthSeverity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .info: Color(hex: 0x60A5FA)
        case .warning: Color(hex: 0xF59E0B)
        case .critical: Color(hex: 0xEF4444)
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

// MARK: - Fix actions

enum HealthFixAction: Hashable {
    case quit(pid: Int32, name: String)
    case forceQuit(pid: Int32, name: String)
    case restartApp(pid: Int32, name: String)
    case ignoreApp(name: String)
    case showTopCPU
    case showTopMemory
    case freeRAM
    case openSection(String, label: String)
    case rebuildSpotlight
    case restartMac

    var title: String {
        switch self {
        case .quit: "Quit"
        case .forceQuit: "Force Quit"
        case .restartApp: "Restart App"
        case .ignoreApp: "Never for this app"
        case .showTopCPU: "Top CPU apps"
        case .showTopMemory: "Top memory apps"
        case .freeRAM: "Free RAM"
        case .openSection(_, let label): label
        case .rebuildSpotlight: "Rebuild Spotlight index"
        case .restartMac: "Restart Mac…"
        }
    }

    var symbol: String {
        switch self {
        case .quit: "xmark.circle"
        case .forceQuit: "bolt.slash"
        case .restartApp: "arrow.clockwise"
        case .ignoreApp: "bell.slash"
        case .showTopCPU: "cpu"
        case .showTopMemory: "memorychip"
        case .freeRAM: "sparkles"
        case .openSection: "arrow.up.forward.app"
        case .rebuildSpotlight: "magnifyingglass"
        case .restartMac: "restart"
        }
    }

    var isDestructive: Bool {
        if case .forceQuit = self { return true }
        return false
    }
}

// MARK: - Findings & issues

/// Produced by a rule on every evaluation; the monitor turns findings into tracked issues.
struct HealthFinding {
    let key: String                 // stable identity, e.g. "runaway:1234"
    let ruleID: String
    var severity: HealthSeverity
    var title: String
    var detail: String
    var actions: [HealthFixAction] = []
    var appName: String? = nil      // enables "Never for this app"
}

struct HealthIssue: Identifiable, Hashable {
    let key: String
    let ruleID: String
    var severity: HealthSeverity
    var title: String
    var detail: String
    var actions: [HealthFixAction]
    var appName: String?
    let detectedAt: Date
    var missCount = 0
    var id: String { key }
}

// MARK: - Event log

enum HealthEventKind: String, Codable, CaseIterable {
    case detected, resolved, action, info
}

struct HealthEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var kind: HealthEventKind
    var severity: HealthSeverity
    var title: String
    var detail: String
}

// MARK: - Samples

struct HealthSample: Identifiable {
    let date: Date
    let cpu: Double
    let memUsed: Double          // fraction
    let pressure: Int            // 1 normal, 2 warn, 4 critical
    let swapUsed: UInt64
    let diskAvailable: Int64
    let cpuTemp: Double?
    let thermalState: Int
    let batteryPercent: Double?  // nil without battery
    let onBattery: Bool
    var id: Date { date }
}

struct HealthScorePoint: Codable, Identifiable {
    let date: Date
    let score: Int
    var id: Date { date }
}

struct HealthTimedValue {
    let t: Date
    let v: Double
}

/// Rolling per-process history.
struct HealthProcTrack {
    let pid: Int32
    var name: String
    var bundleID: String?
    var cpu: [HealthTimedValue] = []     // 10 s cadence, ~10 min
    var mem: [HealthTimedValue] = []     // 30 s cadence, ~30 min
    var memory: UInt64 = 0
    var lastSeen = Date()
}

struct HealthHungApp {
    let pid: Int32
    let name: String
    let since: Date
}

// MARK: - Sensitivity & thresholds

enum HealthSensitivity: String, CaseIterable, Identifiable {
    case relaxed, balanced, strict
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .relaxed: "Only flag clear, long-running problems."
        case .balanced: "Sensible defaults for most Macs."
        case .strict: "Flag problems early, with shorter windows."
        }
    }
}

struct HealthThresholds {
    var runawayCPU = 0.8                 // fraction of one core
    var runawaySeconds: TimeInterval = 180
    var leakGrowthBytes = 1_073_741_824.0
    var leakRAMFraction = 0.25
    var pressureSeconds: TimeInterval = 120
    var swapBytes: UInt64 = 4 * 1_073_741_824
    var diskFreeFraction = 0.10
    var diskFreeBytes: Int64 = 15 * 1_073_741_824
    var diskCriticalBytes: Int64 = 5 * 1_073_741_824
    var tempC = 95.0
    var tempSeconds: TimeInterval = 120
    var drainPerHour = 0.25
    var drainSeconds: TimeInterval = 600
    var loginItems = 15
    var kernelTaskCPU = 150.0            // percent (ps scale, 100 = one core)
    var kernelSeconds: TimeInterval = 180
    var windowServerCPU = 60.0
    var windowServerSeconds: TimeInterval = 180
    var spotlightCPU = 50.0
    var spotlightSeconds: TimeInterval = 600
    var backgroundCPU = 40.0             // photoanalysisd, bird/cloudd
    var backgroundSeconds: TimeInterval = 600
    var crashCount = 3
    var uptimeDays = 14.0
    var uptimeSwapBytes: UInt64 = 2 * 1_073_741_824

    static func make(_ s: HealthSensitivity) -> HealthThresholds {
        var t = HealthThresholds()
        let level: Double, time: Double
        switch s {
        case .balanced: return t
        case .relaxed: level = 1.25; time = 1.5
        case .strict: level = 0.75; time = 0.67
        }
        t.runawayCPU = min(1.0, t.runawayCPU * level)
        if s == .relaxed { t.runawayCPU = 1.0 }
        t.runawaySeconds *= time
        t.leakGrowthBytes *= level
        t.leakRAMFraction *= level
        t.pressureSeconds *= time
        t.swapBytes = UInt64(Double(t.swapBytes) * level)
        t.diskFreeFraction *= (s == .relaxed ? 0.7 : 1.3)
        t.diskFreeBytes = Int64(Double(t.diskFreeBytes) * (s == .relaxed ? 0.7 : 1.3))
        t.tempC += (s == .relaxed ? 3 : -5)
        t.tempSeconds *= time
        t.drainPerHour *= level
        t.drainSeconds *= time
        t.loginItems = Int(Double(t.loginItems) * level)
        t.kernelTaskCPU *= level
        t.kernelSeconds *= time
        t.windowServerCPU *= level
        t.windowServerSeconds *= time
        t.spotlightCPU *= level
        t.spotlightSeconds *= time
        t.backgroundCPU *= level
        t.backgroundSeconds *= time
        t.crashCount = s == .relaxed ? 4 : 2
        return t
    }
}

// MARK: - Checkup

enum HealthCheckStatus: String, Codable {
    case ok, warning, info, unknown, running
}

struct HealthCheckItem: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var status: HealthCheckStatus
    var symbol: String
}

struct HealthSleepBlocker: Identifiable, Hashable {
    let pid: Int32
    let app: String
    let type: String
    let reason: String
    let seconds: Int
    var id: String { "\(pid)-\(type)-\(reason)" }
}

enum HealthTopKind: String, Identifiable {
    case cpu, memory
    var id: String { rawValue }
}
