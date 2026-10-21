import Foundation

/// Where an update was found.
enum UpdateSource: String, Codable, CaseIterable, Hashable {
    case sparkle, appStore, homebrew

    var label: String {
        switch self {
        case .sparkle: "Sparkle"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        }
    }
}

/// One scanned .app bundle.
struct InstalledApp: Codable, Identifiable, Hashable {
    /// Bundle path.
    var id: String
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var feedURL: String?
    var hasReceipt: Bool
    /// How MacMaster tracks this app. nil = not tracked.
    var tracking: UpdateSource?
    var caskToken: String?

    var path: String { id }
    /// Stable key for ignore rules.
    var key: String { bundleID.isEmpty ? "path:" + id : bundleID }
}

/// An available update.
struct AppUpdate: Codable, Identifiable, Hashable {
    var id: String
    /// Ignore key: bundle id, or `cask:<token>` for casks that are not in a scanned folder.
    var key: String
    var name: String
    var bundleID: String
    /// nil for casks without a matching scanned app.
    var path: String?
    var installedVersion: String
    var newVersion: String
    var source: UpdateSource
    var notes: String?
    var notesURL: String?
    var downloadURL: String?
    var pageURL: String?
    var caskToken: String?
    var isCritical: Bool = false
    var pubDate: Date?
}

/// An app whose check failed.
struct CheckFailure: Codable, Identifiable, Hashable {
    var id: String { appKey + "|" + source.rawValue }
    var appKey: String
    var name: String
    var source: UpdateSource
    var message: String
}

struct UpdatesCache: Codable {
    var lastChecked: Date?
    var apps: [InstalledApp] = []
    var direct: [AppUpdate] = []
    var brew: [AppUpdate] = []
    var failures: [CheckFailure] = []
    var formulae: [String] = []
    var brewAvailable: Bool = false
    var brewError: String?
}

struct IgnoreRule: Codable, Identifiable, Hashable {
    var key: String
    /// nil = ignore the whole app.
    var version: String?
    var name: String
    var id: String { key + "|" + (version ?? "*") }
}

// MARK: - Version comparison

/// Numeric dotted comparison with build numbers, pre-release tags (1.2b3, 2.0-rc1) and a leading "v".
enum VersionCompare {
    enum Token: Equatable {
        case num(Int)
        /// Negative = pre-release (sorts before the plain release), positive = post-release patch.
        case tag(Int)
    }

    private static let tagRanks: [String: Int] = [
        "dev": -4, "d": -4, "nightly": -4, "snapshot": -4, "canary": -4,
        "alpha": -3, "a": -3,
        "beta": -2, "b": -2,
        "pre": -1, "preview": -1, "rc": -1, "c": -1, "candidate": -1,
        "p": 1, "patch": 1, "hotfix": 1, "hf": 1, "sp": 1, "update": 1, "r": 1, "rev": 1,
    ]

    static func tokens(_ raw: String) -> [Token] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("version ") { s.removeFirst(8) }
        if s.hasPrefix("v"), s.dropFirst().first?.isNumber == true { s.removeFirst() }
        var out: [Token] = []
        var digits = "", letters = ""
        func flushDigits() {
            if !digits.isEmpty { out.append(.num(Int(digits) ?? Int.max)); digits = "" }
        }
        func flushLetters() {
            if !letters.isEmpty {
                if let r = tagRanks[letters] { out.append(.tag(r)) }
                letters = ""
            }
        }
        for ch in s {
            if ch.isASCII, ch.isNumber { flushLetters(); digits.append(ch) }
            else if ch.isLetter { flushDigits(); letters.append(ch) }
            else { flushDigits(); flushLetters() }
        }
        flushDigits(); flushLetters()
        return out
    }

    /// -1, 0, 1.
    static func compare(_ a: String, _ b: String) -> Int {
        let ta = tokens(a), tb = tokens(b)
        for i in 0..<max(ta.count, tb.count) {
            let x: Token? = i < ta.count ? ta[i] : nil
            let y: Token? = i < tb.count ? tb[i] : nil
            let c = cmp(x, y)
            if c != 0 { return c }
        }
        return 0
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool { compare(candidate, installed) > 0 }

    private static func cmp(_ x: Token?, _ y: Token?) -> Int {
        switch (x, y) {
        case (nil, nil): return 0
        case let (.num(a)?, .num(b)?): return a == b ? 0 : (a < b ? -1 : 1)
        case let (.tag(a)?, .tag(b)?): return a == b ? 0 : (a < b ? -1 : 1)
        case let (.num?, .tag(r)?): return r < 0 ? 1 : -1   // num vs pre-release: num wins
        case let (.tag(r)?, .num?): return r < 0 ? -1 : 1
        case let (nil, .num(b)?): return b == 0 ? 0 : -1
        case let (.num(a)?, nil): return a == 0 ? 0 : 1
        case let (nil, .tag(r)?): return r < 0 ? 1 : -1      // missing = release; beats pre-release
        case let (.tag(r)?, nil): return r < 0 ? -1 : 1
        }
    }
}

// MARK: - Text helpers

enum UpdateText {
    /// Release-note HTML to plain text.
    static func plain(fromHTML html: String, limit: Int = 2500) -> String {
        var s = html
        // Drop script/style blocks.
        for tag in ["script", "style"] {
            while let r = s.range(of: "<\(tag)[^>]*>.*?</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
        }
        let rules: [(String, String)] = [
            ("<br\\s*/?>", "\n"),
            ("</(p|div|h[1-6]|ul|ol|tr)>", "\n"),
            ("<li[^>]*>", "\n• "),
            ("<[^>]+>", ""),
        ]
        for (pattern, repl) in rules {
            s = s.replacingOccurrences(of: pattern, with: repl, options: [.regularExpression, .caseInsensitive])
        }
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&#39;": "'", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&bull;": "•"]
        // Numeric entities.
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = "", last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = ns.substring(with: m.range(at: 2))
                if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { result += String(Character(u)) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // &amp; last so "&amp;lt;" is not double-decoded.
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// "4.96.0,243774" -> "4.96.0".
    static func caskDisplayVersion(_ v: String) -> String {
        v.split(separator: ",", maxSplits: 1).first.map(String.init) ?? v
    }

    /// Lowercased alphanumerics only: "Docker Desktop" and "docker-desktop" match.
    static func normalized(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
