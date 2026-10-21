import SwiftUI
import AppKit

// MARK: - Preferences

enum CommandBarPrefs {
    static let enabledKey = "mm.commandBar.enabled"
    static let hotKeyKey = "mm.commandBar.hotkey"
    static let hotKeySeededKey = "mm.commandBar.hotkeySeeded"
    static let webEngineKey = "mm.commandBar.webEngine"
    static let usageKey = "mm.commandBar.usage"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

enum CBWebEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo
    var id: String { rawValue }
    var title: String { self == .google ? "Google" : "DuckDuckGo" }
    var other: CBWebEngine { self == .google ? .duckduckgo : .google }
    var host: String { self == .google ? "www.google.com" : "duckduckgo.com" }
    var path: String { self == .google ? "/search" : "/" }

    static var current: CBWebEngine {
        CBWebEngine(rawValue: UserDefaults.standard.string(forKey: CommandBarPrefs.webEngineKey) ?? "") ?? .google
    }

    func searchURL(_ text: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.path = path
        c.queryItems = [URLQueryItem(name: "q", value: text)]
        return c.url
    }
}

// MARK: - Provider kinds

enum CBKind: String, CaseIterable, Identifiable {
    case apps, pages, actions, calc, clipboard, snippets, web, systemSettings, files
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Applications"
        case .pages: "MacMaster pages and settings"
        case .actions: "Quick actions and toggles"
        case .calc: "Calculator and unit conversion"
        case .clipboard: "Clipboard history"
        case .snippets: "Text snippets"
        case .web: "Web search and URLs"
        case .systemSettings: "System Settings panes"
        case .files: "Files (Spotlight)"
        }
    }

    var detail: String {
        switch self {
        case .apps: "Launch anything in /Applications, /System/Applications and ~/Applications."
        case .pages: "Jump to any MacMaster page or individual setting."
        case .actions: "Keep Awake, dark mode, Empty Trash, restart Dock, free memory and more."
        case .calc: "Type 2^10 or 10 km in mi. Press Return to copy the answer."
        case .clipboard: "Type clip then a few letters to paste from your recent copies."
        case .snippets: "Insert your Keyboard snippets into the front app."
        case .web: "Search the web or open a typed address."
        case .systemSettings: "Open a System Settings pane directly."
        case .files: "Find files by name (3+ letters). Uses the Spotlight index, off by default."
        }
    }

    var symbol: String {
        switch self {
        case .apps: "app.badge"
        case .pages: "square.grid.2x2"
        case .actions: "bolt.fill"
        case .calc: "equal.square.fill"
        case .clipboard: "doc.on.clipboard"
        case .snippets: "text.badge.plus"
        case .web: "globe"
        case .systemSettings: "gearshape.fill"
        case .files: "doc.text.magnifyingglass"
        }
    }

    var colors: [Color] {
        switch self {
        case .apps: Theme.Palette.blue
        case .pages: Theme.Palette.gray
        case .actions: Theme.Palette.orange
        case .calc: Theme.Palette.green
        case .clipboard: Theme.Palette.teal
        case .snippets: Theme.Palette.indigo
        case .web: Theme.Palette.blue
        case .systemSettings: Theme.Palette.gray
        case .files: Theme.Palette.yellow
        }
    }

    /// Short label shown at the end of a result row.
    var badge: String {
        switch self {
        case .apps: "App"
        case .pages: "MacMaster"
        case .actions: "Action"
        case .calc: "Calculate"
        case .clipboard: "Clipboard"
        case .snippets: "Snippet"
        case .web: "Web"
        case .systemSettings: "Settings"
        case .files: "File"
        }
    }

    var defaultOn: Bool { self != .files }
    var defaultsKey: String { "mm.commandBar.provider.\(rawValue)" }
    var isOn: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultOn }
}

// MARK: - Result

struct CBResult: Identifiable {
    let id: String
    let kind: CBKind
    var title: String
    var subtitle: String
    var symbol: String
    var colors: [Color]
    /// When set, the Finder icon of this file or app is shown instead of the symbol tile.
    var iconPath: String? = nil
    var score: Int = 0
    /// Label for the Return key, e.g. "Open", "Copy".
    var hint: String = "Open"
    /// Label for Command-Return; nil = no alternate action.
    var altHint: String? = nil
    var perform: @MainActor () -> Void = {}
    var alt: (@MainActor () -> Void)? = nil
}

// MARK: - Usage ranking

/// Remembers what you pick so frequent and recent items float up. Stored locally as small JSON.
@MainActor
final class CommandBarUsage {
    static let shared = CommandBarUsage()

    private struct Entry: Codable { var n: Int; var t: TimeInterval }
    private struct Saved: Codable { var ids: [String: Entry]; var pairs: [String: Entry] }

    private var ids: [String: Entry] = [:]
    private var pairs: [String: Entry] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: CommandBarPrefs.usageKey),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            ids = s.ids; pairs = s.pairs
        }
    }

    var trackedCount: Int { ids.count }

    private func weight(_ e: Entry?, now: TimeInterval) -> Double {
        guard let e else { return 0 }
        let ageDays = max(0, now - e.t) / 86_400
        return Double(min(e.n, 12)) * pow(0.5, ageDays / 14)
    }

    private func pairKey(_ id: String, _ query: String) -> String {
        String(CommandBarFuzzy.fold(query).trimmingCharacters(in: .whitespaces).prefix(14)) + "|" + id
    }

    /// Extra score: up to 90 from overall use, up to 70 more when you picked it for this exact query before.
    func boost(id: String, query: String) -> Int {
        let now = Date().timeIntervalSince1970
        var b = min(90.0, weight(ids[id], now: now) * 12)
        if !query.isEmpty { b += min(70.0, weight(pairs[pairKey(id, query)], now: now) * 24) }
        return Int(b)
    }

    func record(id: String, query: String) {
        let now = Date().timeIntervalSince1970
        func bump(_ d: inout [String: Entry], _ k: String) {
            var e = d[k] ?? Entry(n: 0, t: now)
            e.n = min(e.n + 1, 50); e.t = now
            d[k] = e
        }
        bump(&ids, id)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { bump(&pairs, pairKey(id, q)) }
        prune()
        save()
    }

    /// Ids ordered by how much they are used right now (for the empty-query list).
    func topIDs(limit: Int) -> [String] {
        let now = Date().timeIntervalSince1970
        return ids.map { ($0.key, weight($0.value, now: now)) }
            .filter { $0.1 > 0.3 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    func reset() {
        ids = [:]; pairs = [:]
        UserDefaults.standard.removeObject(forKey: CommandBarPrefs.usageKey)
    }

    private func prune() {
        func trim(_ d: inout [String: Entry], _ cap: Int) {
            guard d.count > cap else { return }
            let keep = d.sorted { $0.value.t > $1.value.t }.prefix(cap * 3 / 4)
            d = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        trim(&ids, 400); trim(&pairs, 600)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(ids: ids, pairs: pairs)) {
            UserDefaults.standard.set(d, forKey: CommandBarPrefs.usageKey)
        }
    }
}

// MARK: - Icon cache

@MainActor
enum CBIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 160
        return c
    }()

    static func icon(forFile path: String) -> NSImage {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 32, height: 32)
        cache.setObject(img, forKey: key)
        return img
    }

    static func flush() { cache.removeAllObjects() }
}
