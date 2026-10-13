import SwiftUI
import AppKit

// MARK: - Categories & impact

enum OptimizerCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case memory, cpu, disk, network, startup, system, visual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .cpu: "CPU"
        case .disk: "Disk"
        case .network: "Network"
        case .startup: "Startup"
        case .system: "System"
        case .visual: "Visual"
        }
    }

    var symbol: String {
        switch self {
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .disk: "internaldrive"
        case .network: "network"
        case .startup: "power"
        case .system: "gearshape.2"
        case .visual: "sparkles.tv"
        }
    }

    var colors: [Color] {
        switch self {
        case .memory: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)]
        case .cpu: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)]
        case .disk: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)]
        case .network: [Color(hex: 0x34D399), Color(hex: 0x059669)]
        case .startup: [Color(hex: 0xF472B6), Color(hex: 0xDB2777)]
        case .system: [Color(hex: 0x94A3B8), Color(hex: 0x475569)]
        case .visual: [Color(hex: 0x38BDF8), Color(hex: 0x6366F1)]
        }
    }

    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum OptimizerImpact: Int, Codable, Comparable, Hashable {
    case low = 1, medium, high
    static func < (a: OptimizerImpact, b: OptimizerImpact) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .low: "Low impact"
        case .medium: "Medium impact"
        case .high: "High impact"
        }
    }
    var color: Color {
        switch self {
        case .low: Color(hex: 0x94A3B8)
        case .medium: Color(hex: 0xF59E0B)
        case .high: Color(hex: 0xEF4444)
        }
    }
}

// MARK: - Actions & recommendations

struct OptimizerOutcome: Sendable {
    var ok: Bool
    var message: String
    var cancelled = false
}

typealias OptimizerAction = @MainActor () async -> OptimizerOutcome

/// Where an informational recommendation can send the user.
enum OptimizerLink {
    case section(String, label: String)
    case url(URL, label: String)

    var label: String {
        switch self {
        case .section(_, let l), .url(_, let l): l
        }
    }

    @MainActor
    func open() {
        switch self {
        case .section(let raw, _):
            NotificationCenter.default.post(name: Notification.Name("MacMaster.openSection"), object: raw)
        case .url(let url, _):
            NSWorkspace.shared.open(url)
        }
    }
}

/// Optional second, stronger action (e.g. Force Quit) shown next to a recommendation.
struct OptimizerForceAction {
    var label: String
    var confirm: String
    var run: OptimizerAction
}

struct OptimizerRecommendation: Identifiable {
    let id: String
    var title: String
    var detail: String
    var category: OptimizerCategory
    var impact: OptimizerImpact
    var gain: String
    var symbol: String
    var requiresAdmin = false
    var quitsApps = false
    var irreversible = false
    /// Pre-selected in the review list. Always false for admin / quit / irreversible tasks.
    var isSafe = false
    /// Non-admin work. For admin tasks `adminCommand` is run (batched) instead.
    var apply: OptimizerAction?
    /// Fixed, trusted shell fragment executed with administrator privileges.
    var adminCommand: String?
    var link: OptimizerLink?
    var force: OptimizerForceAction?
    var estimatedMemory: Int64 = 0
    var estimatedDisk: Int64 = 0

    var isActionable: Bool { apply != nil || adminCommand != nil }

    init(id: String, title: String, detail: String, category: OptimizerCategory, impact: OptimizerImpact,
         gain: String, symbol: String, requiresAdmin: Bool = false, quitsApps: Bool = false,
         irreversible: Bool = false, safe: Bool = false, apply: OptimizerAction? = nil,
         adminCommand: String? = nil, link: OptimizerLink? = nil, force: OptimizerForceAction? = nil,
         estimatedMemory: Int64 = 0, estimatedDisk: Int64 = 0) {
        self.id = id; self.title = title; self.detail = detail; self.category = category
        self.impact = impact; self.gain = gain; self.symbol = symbol
        self.requiresAdmin = requiresAdmin || adminCommand != nil
        self.quitsApps = quitsApps; self.irreversible = irreversible
        self.isSafe = safe && !(requiresAdmin || adminCommand != nil) && !quitsApps && !irreversible && apply != nil
        self.apply = apply; self.adminCommand = adminCommand; self.link = link; self.force = force
        self.estimatedMemory = estimatedMemory; self.estimatedDisk = estimatedDisk
    }
}

// MARK: - Task progress & results

enum OptimizerTaskStatus: String, Codable, Sendable {
    case pending, running, done, failed, skipped
}

struct OptimizerTaskReport: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var symbol: String
    var requiresAdmin: Bool
    var status: OptimizerTaskStatus = .pending
    var message: String = ""
}

/// Point-in-time memory/disk numbers used for before/after comparisons.
struct OptimizerMeasure: Codable, Sendable {
    var memTotal: UInt64
    var memUsed: UInt64
    var memCached: UInt64
    var memFree: UInt64
    var diskFree: Int64
    var diskTotal: Int64

    static func read() -> OptimizerMeasure {
        let m = MemoryReader.read()
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return OptimizerMeasure(memTotal: m.total, memUsed: m.used, memCached: m.cached, memFree: m.free,
                                diskFree: Int64(v?.volumeAvailableCapacity ?? 0),
                                diskTotal: Int64(v?.volumeTotalCapacity ?? 0))
    }
}

struct OptimizerResult: Identifiable, Sendable {
    let id = UUID()
    var date: Date
    var source: String
    var reports: [OptimizerTaskReport]
    var before: OptimizerMeasure
    var after: OptimizerMeasure
    var scoreBefore: Int
    var scoreAfter: Int
    var memoryFreed: Int64
    var diskFreed: Int64
    var summary: String

    var succeeded: Int { reports.filter { $0.status == .done }.count }
    var failed: Int { reports.filter { $0.status == .failed }.count }
}

struct OptimizerHistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var source: String
    var tasks: [String]
    var summary: String
    var memoryFreed: Int64?
    var diskFreed: Int64?
    var scoreBefore: Int?
    var scoreAfter: Int?
}

// MARK: - Score

struct OptimizerScoreFactor: Identifiable {
    let id: String
    var title: String
    var symbol: String
    var penalty: Int
    var note: String
    var colors: [Color]
    var isGood: Bool { penalty == 0 }
}

enum OptimizerGrade {
    static func label(_ score: Int) -> String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Good"
        case 55..<75: "Fair"
        default: "Needs attention"
        }
    }
    static func colors(_ score: Int) -> [Color] {
        switch score {
        case 85...: [Color(hex: 0x34D399), Color(hex: 0x0EA5E9)]
        case 65..<85: [Color(hex: 0xA3E635), Color(hex: 0x34D399)]
        case 45..<65: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)]
        default: [Color(hex: 0xF97316), Color(hex: 0xEF4444)]
        }
    }
}

// MARK: - Maintenance catalog entries

struct OptimizerMaintenanceTask: Identifiable {
    let id: String
    var title: String
    var detail: String
    var symbol: String
    var category: OptimizerCategory
    var impact: OptimizerImpact
    var gain: String
    var requiresAdmin: Bool
    var intervalDays: Int
    var safe: Bool
    var longRunning = false
    /// Admin shell fragment (trusted constant). Mutually exclusive with `run`.
    var adminCommand: String?
    var run: (@Sendable () async -> OptimizerOutcome)?
}
