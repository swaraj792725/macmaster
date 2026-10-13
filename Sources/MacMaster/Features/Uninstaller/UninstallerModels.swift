import SwiftUI

// MARK: - Confidence

enum UninstallerConfidence: Int, Comparable, Sendable, CaseIterable {
    case low = 0, medium = 1, high = 2

    static func < (l: UninstallerConfidence, r: UninstallerConfidence) -> Bool { l.rawValue < r.rawValue }

    var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var color: Color {
        switch self {
        case .high: return Color(hex: 0x22C55E)
        case .medium: return Color(hex: 0xF59E0B)
        case .low: return Color(hex: 0x94A3B8)
        }
    }

    /// Only high + medium matches are ticked automatically.
    var isPreselected: Bool { self != .low }
}

// MARK: - Category

enum UninstallerCategory: String, CaseIterable, Identifiable, Sendable {
    case application, preferences, caches, containers, support, launch, logs, receipts, developer, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Application"
        case .preferences: return "Preferences"
        case .caches: return "Caches"
        case .containers: return "Containers"
        case .support: return "Support files"
        case .launch: return "Launch agents & daemons"
        case .logs: return "Logs & crash reports"
        case .receipts: return "Receipts"
        case .developer: return "Developer files"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .application: return "app.fill"
        case .preferences: return "slider.horizontal.3"
        case .caches: return "internaldrive"
        case .containers: return "shippingbox.fill"
        case .support: return "folder.fill"
        case .launch: return "bolt.fill"
        case .logs: return "doc.text.fill"
        case .receipts: return "checkmark.seal.fill"
        case .developer: return "hammer.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// Whether the category holds per-user data that "Reset app" may remove.
    var isResettable: Bool {
        switch self {
        case .preferences, .caches, .containers, .support, .logs: return true
        default: return false
        }
    }

    /// Strong signs that a GUI app once existed (used to raise orphan confidence).
    var isGUIEvidence: Bool { self == .containers }
}

// MARK: - Item

enum UninstallerItemKind: Hashable, Sendable {
    case file
    case receipt(String)
}

struct UninstallerItem: Identifiable, Hashable, Sendable {
    var id: String
    var url: URL
    var kind: UninstallerItemKind = .file
    var category: UninstallerCategory
    var confidence: UninstallerConfidence
    var reason: String
    var size: Int64 = 0
    var modified: Date? = nil
    var requiresAdmin: Bool = false
    /// launchd label for agents/daemons/helper tools.
    var launchLabel: String? = nil
    /// True when the job lives in the system launchd domain (daemons, privileged helpers).
    var launchSystemDomain: Bool = false
    /// launchd plist whose executable no longer exists.
    var isBroken: Bool = false
    /// Allows removing `com.apple.*` named items (developer caches the user explicitly picked).
    var allowApple: Bool = false
    /// True for items under the user's home (eligible for "Reset app").
    var isUserDomain: Bool = true
    var groupID: String? = nil

    var name: String { url.lastPathComponent }
    var displayPath: String { UninstallerPaths.tilde(url.path) }
    var isReceipt: Bool { if case .receipt = kind { return true } else { return false } }
}

// MARK: - App

struct UninstallerApp: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    var name: String
    var bundleID: String
    var version: String
    var executable: String
    var aliases: [String]
    var isSystem: Bool
    var source: String
    var size: Int64? = nil
    var lastUsed: Date? = nil

    var daysSinceUsed: Int? {
        guard let d = lastUsed else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }
}

// MARK: - Hunter group

struct UninstallerGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var symbol: String
    var isDeveloper: Bool
    var items: [UninstallerItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var maxConfidence: UninstallerConfidence { items.map(\.confidence).max() ?? .low }
    var lastModified: Date? { items.compactMap(\.modified).max() }

    func visibleItems(includeLow: Bool) -> [UninstallerItem] {
        includeLow ? items : items.filter { $0.confidence != .low }
    }
}

// MARK: - Removal

struct UninstallerRemovalFailure: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let reason: String
}

struct UninstallerRemovalSummary: Sendable {
    var removedCount = 0
    var freed: Int64 = 0
    var removedIDs: Set<String> = []
    var failures: [UninstallerRemovalFailure] = []
    var notes: [String] = []
    var usedAdmin = false
    var permanent = false
}

struct UninstallerRemovalPlan: Identifiable {
    enum Source { case app, reset, hunter }
    let id = UUID()
    var source: Source
    var title: String
    var items: [UninstallerItem]
    var app: UninstallerApp?
    var appIsRunning: Bool
    var deleteImmediately: Bool

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var adminCount: Int { items.filter { $0.requiresAdmin || $0.isReceipt || $0.launchSystemDomain }.count }
}

// MARK: - Settings

enum UninstallerSettings {
    static let deleteKey = "mm.uninstaller.deleteImmediately"
    static let includeLowKey = "mm.uninstaller.includeLow"
    static let scanSystemKey = "mm.uninstaller.scanSystem"
    static let watchDeletionsKey = "mm.uninstaller.watchDeletions"

    static var deleteImmediately: Bool { UserDefaults.standard.bool(forKey: deleteKey) }
    static var includeLow: Bool { UserDefaults.standard.bool(forKey: includeLowKey) }
    static var scanSystem: Bool { (UserDefaults.standard.object(forKey: scanSystemKey) as? Bool) ?? true }
    static var watchDeletions: Bool { (UserDefaults.standard.object(forKey: watchDeletionsKey) as? Bool) ?? true }
}
