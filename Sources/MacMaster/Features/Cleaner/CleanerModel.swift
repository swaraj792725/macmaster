import SwiftUI

// MARK: - Safety

enum CleanerSafety: String, Codable, Sendable {
    case safe, review

    var title: String { self == .safe ? "Safe" : "Review" }
    var color: Color { self == .safe ? Color(hex: 0x22C55E) : Color(hex: 0xF59E0B) }
}

// MARK: - Categories

enum CleanerCategoryID: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case userCaches, browserCaches, logs, crashReports, devDerivedData, devCaches
    case systemCaches, systemLogs, trash, devReview, browserPrivacy, mail, messages
    case oldDownloads, installers, snapshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: "User caches"
        case .systemCaches: "System caches"
        case .logs: "User logs"
        case .crashReports: "Crash & diagnostic reports"
        case .systemLogs: "System logs & reports"
        case .trash: "Trash"
        case .browserCaches: "Browser caches"
        case .browserPrivacy: "Browser privacy data"
        case .devDerivedData: "Xcode DerivedData"
        case .devCaches: "Developer caches"
        case .devReview: "Developer leftovers"
        case .mail: "Mail downloads"
        case .messages: "Messages attachments"
        case .oldDownloads: "Old Downloads"
        case .installers: "Installer leftovers"
        case .snapshots: "Time Machine local snapshots"
        }
    }

    var summary: String {
        switch self {
        case .userCaches: "Regenerable app caches in ~/Library/Caches. Apps that are running are skipped."
        case .systemCaches: "Caches in /Library/Caches. Regenerable, but removal needs administrator access."
        case .logs: "Application logs in ~/Library/Logs older than 7 days."
        case .crashReports: "Crash and diagnostic reports from apps and the system."
        case .systemLogs: "Logs in /Library/Logs and /var/log older than 7 days. Needs administrator access."
        case .trash: "Items already in your Trash. Emptying it is permanent."
        case .browserCaches: "Cached web content for Safari, Chrome, Edge, Brave, Arc, Firefox and more. History and cookies are not touched."
        case .browserPrivacy: "Browsing history and cookies. Quit the browser first. Moved to Trash."
        case .devDerivedData: "Xcode build products and indexes. Rebuilt automatically on the next build."
        case .devCaches: "Package manager and toolchain caches: SwiftPM, npm, pip, Gradle, Homebrew, Cargo, Go and more."
        case .devReview: "Xcode archives, iOS device support files, unavailable simulators and Docker data."
        case .mail: "Attachments Mail downloaded for viewing. Originals stay on the mail server."
        case .messages: "Attachments stored by Messages. Shown for information; open the folder to manage."
        case .oldDownloads: "Files in Downloads you have not touched for over 90 days."
        case .installers: "Leftover .dmg, .pkg, .xip and .zip files in Downloads and Desktop."
        case .snapshots: "Local Time Machine snapshots that take space until macOS purges them."
        }
    }

    var symbol: String {
        switch self {
        case .userCaches: "internaldrive"
        case .systemCaches: "gearshape.2"
        case .logs: "doc.text"
        case .crashReports: "exclamationmark.triangle"
        case .systemLogs: "doc.text.magnifyingglass"
        case .trash: "trash"
        case .browserCaches: "safari"
        case .browserPrivacy: "hand.raised"
        case .devDerivedData: "hammer"
        case .devCaches: "shippingbox"
        case .devReview: "terminal"
        case .mail: "envelope"
        case .messages: "message"
        case .oldDownloads: "arrow.down.circle"
        case .installers: "opticaldiscdrive"
        case .snapshots: "clock.arrow.circlepath"
        }
    }

    var colors: [Color] {
        switch self {
        case .userCaches: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)]
        case .systemCaches: [Color(hex: 0x94A3B8), Color(hex: 0x475569)]
        case .logs: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)]
        case .crashReports: [Color(hex: 0xFB923C), Color(hex: 0xEA580C)]
        case .systemLogs: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)]
        case .trash: [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
        case .browserCaches: [Color(hex: 0x38BDF8), Color(hex: 0x0284C7)]
        case .browserPrivacy: [Color(hex: 0xF472B6), Color(hex: 0xDB2777)]
        case .devDerivedData: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)]
        case .devCaches: [Color(hex: 0x34D399), Color(hex: 0x059669)]
        case .devReview: [Color(hex: 0x2DD4BF), Color(hex: 0x0F766E)]
        case .mail: [Color(hex: 0x60A5FA), Color(hex: 0x4F46E5)]
        case .messages: [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)]
        case .oldDownloads: [Color(hex: 0xFACC15), Color(hex: 0xCA8A04)]
        case .installers: [Color(hex: 0xC084FC), Color(hex: 0x9333EA)]
        case .snapshots: [Color(hex: 0x22D3EE), Color(hex: 0x0E7490)]
        }
    }

    var safety: CleanerSafety {
        switch self {
        case .userCaches, .browserCaches, .logs, .crashReports, .devDerivedData, .devCaches: .safe
        default: .review
        }
    }

    /// Categories that can run unattended. Only "safe" ones, plus Trash via a separate explicit opt-in.
    var autoCleanEligible: Bool { safety == .safe }

    var warning: String? {
        switch self {
        case .trash: "Permanent. Items cannot be recovered."
        case .browserPrivacy: "Quit the browser first. Signs you out of sites."
        case .systemCaches, .systemLogs, .snapshots: "Needs administrator password."
        default: nil
        }
    }
}

// MARK: - Items

struct CleanerCommand: Hashable, Sendable {
    let executable: String
    let args: [String]
    let admin: Bool
    let label: String
}

enum CleanerAction: Hashable, Sendable {
    case delete        // permanent; used only for regenerable data (caches, logs) and Trash
    case trash         // reversible
    case adminDelete   // root-owned; rm -rf via one admin prompt
    case command(CleanerCommand)
    case info          // display only
}

struct CleanerItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    var category: CleanerCategoryID
    var name: String
    var detail: String?
    var urls: [URL]
    var size: Int64
    var action: CleanerAction
    var blockedReason: String? = nil

    var primaryURL: URL? { urls.first }
    var isSelectable: Bool { action != .info && blockedReason == nil }

    var needsAdmin: Bool {
        switch action {
        case .adminDelete: true
        case .command(let c): c.admin
        default: false
        }
    }

    var isPermanent: Bool {
        switch action {
        case .delete, .adminDelete: true
        case .command: true
        default: false
        }
    }

    var actionLabel: String {
        switch action {
        case .delete: category == .trash ? "Deleted permanently" : "Deleted"
        case .trash: "Moved to Trash"
        case .adminDelete: "Deleted (admin)"
        case .command(let c): c.label
        case .info: "Info only"
        }
    }
}

struct CleanerFailure: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var name: String
    var reason: String
}

struct CleanerSummary: Sendable {
    var freed: Int64
    var removedCount: Int
    var failures: [CleanerFailure]
    var perCategory: [CleanerCategoryID: Int64]
    var date = Date()
}

// MARK: - History

struct CleanerHistoryEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var freed: Int64
    var itemCount: Int
    var failureCount: Int
    var automatic: Bool
    var categories: [String]
    var note: String? = nil
}

// MARK: - Helpers

enum CleanerFormat {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func abbreviatedPath(_ url: URL) -> String {
        let p = url.path
        let h = AppPaths.home.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }
}

enum CleanerTool {
    /// Absolute path of a CLI tool if installed (GUI apps get a minimal PATH, so search known dirs).
    static func find(_ name: String) -> String? {
        let dirs = ["/usr/bin", "/usr/sbin", "/bin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin",
                    AppPaths.home.appendingPathComponent(".cargo/bin").path,
                    "/Applications/Docker.app/Contents/Resources/bin"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
