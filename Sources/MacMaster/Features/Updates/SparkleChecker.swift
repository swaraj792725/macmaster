import Foundation

/// Shared network session: 15 s timeout, no cache, no waiting for connectivity.
enum UpdateNet {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "MacMaster-Updates/1.0"]
        return URLSession(configuration: c)
    }()

    static func fetch(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        return data
    }

    /// True for "no internet" style failures.
    static func isOffline(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                .cannotFindHost, .dnsLookupFailed].contains(e.code)
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .http(let c): "Server answered HTTP \(c)"
        case .parse(let m): m
        }
    }
}

// MARK: - Appcast model

struct AppcastItem {
    var title: String?
    var build: String?          // sparkle:version
    var shortVersion: String?   // sparkle:shortVersionString
    var minSystem: String?
    var maxSystem: String?
    var channel: String?
    var os: String?
    var downloadURL: String?
    var notesLink: String?
    var descriptionHTML: String?
    var pubDate: Date?
    var critical = false

    /// What to show as the version number.
    var displayVersion: String? { shortVersion ?? build }
}

/// Parses a Sparkle appcast (RSS) into items. Foundation only.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var stack: [String] = []
    private var deltaDepth = 0

    static func parse(_ data: Data) throws -> [AppcastItem] {
        let p = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        guard xml.parse() || !p.items.isEmpty else {
            throw UpdateError.parse(xml.parserError?.localizedDescription ?? "Not a valid appcast")
        }
        return p.items
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        stack.append(name)
        text = ""
        let (ns, local) = Self.split(name)
        if ns == nil, name == "item" { current = AppcastItem(); return }
        guard current != nil else { return }
        if local == "deltas" { deltaDepth += 1 }
        if name == "enclosure", deltaDepth == 0 {
            var attr: [String: String] = [:]
            for (k, v) in a { attr[Self.split(k).1] = v }
            if current?.downloadURL == nil { current?.downloadURL = attr["url"] }
            if current?.build == nil { current?.build = attr["version"] }
            if current?.shortVersion == nil { current?.shortVersion = attr["shortVersionString"] }
            if current?.os == nil { current?.os = attr["os"] }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = stack.popLast(); text = "" }
        let (ns, local) = Self.split(name)
        if ns == nil, name == "item" {
            if let item = current { items.append(item) }
            current = nil
            deltaDepth = 0
            return
        }
        guard current != nil else { return }
        if local == "deltas" { deltaDepth = max(0, deltaDepth - 1); return }
        // Ignore anything inside <sparkle:deltas>.
        guard deltaDepth == 0 else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if ns == nil {
            switch name {
            case "title": current?.title = value
            case "description": current?.descriptionHTML = value
            case "pubDate": current?.pubDate = Self.dateFormatter.date(from: value)
            default: break
            }
        } else {
            switch local {
            case "version": if current?.build == nil { current?.build = value }
            case "shortVersionString": if current?.shortVersion == nil { current?.shortVersion = value }
            case "minimumSystemVersion": current?.minSystem = value
            case "maximumSystemVersion": current?.maxSystem = value
            case "channel": current?.channel = value
            case "releaseNotesLink": if current?.notesLink == nil { current?.notesLink = value }
            case "fullReleaseNotesLink": if current?.notesLink == nil { current?.notesLink = value }
            case "criticalUpdate": current?.critical = true
            default: break
            }
        }
    }

    /// "sparkle:version" -> ("sparkle", "version"); "item" -> (nil, "item").
    private static func split(_ name: String) -> (String?, String) {
        guard let i = name.lastIndex(of: ":") else { return (nil, name) }
        return (String(name[..<i]), String(name[name.index(after: i)...]))
    }
}

// MARK: - Checker

enum SparkleChecker {
    struct Options {
        var includeBeta: Bool
        var osVersion: String
    }

    /// Newest eligible item that is newer than the installed app, or nil.
    static func pickUpdate(items: [AppcastItem], installedShort: String, installedBuild: String,
                           options: Options) -> AppcastItem? {
        let eligible = items.filter { item in
            if let os = item.os, os.lowercased() != "macos" { return false }
            if let ch = item.channel, !ch.isEmpty, !options.includeBeta { return false }
            if let min = item.minSystem, VersionCompare.compare(min, options.osVersion) > 0 { return false }
            if let max = item.maxSystem, VersionCompare.compare(max, options.osVersion) < 0 { return false }
            return item.build != nil || item.shortVersion != nil
        }
        // Newest by build number (Sparkle's own rule), falling back to the short version.
        func newer(_ a: AppcastItem, _ b: AppcastItem) -> Bool {
            if let x = a.build, let y = b.build, VersionCompare.compare(x, y) != 0 { return VersionCompare.compare(x, y) > 0 }
            if let x = a.shortVersion, let y = b.shortVersion { return VersionCompare.compare(x, y) > 0 }
            return false
        }
        var best: AppcastItem?
        for item in eligible where best == nil || newer(item, best!) { best = item }
        guard let best else { return nil }
        return isUpdate(best, installedShort: installedShort, installedBuild: installedBuild) ? best : nil
    }

    static func isUpdate(_ item: AppcastItem, installedShort: String, installedBuild: String) -> Bool {
        if let b = item.build, !installedBuild.isEmpty {
            // Build numbers are authoritative unless the app reuses the short version as its build.
            let c = VersionCompare.compare(b, installedBuild)
            if c != 0 { return c > 0 }
            // Same build: a differing short version with a higher number still counts.
            if let s = item.shortVersion, !installedShort.isEmpty { return VersionCompare.isNewer(s, than: installedShort) }
            return false
        }
        if let s = item.shortVersion, !installedShort.isEmpty { return VersionCompare.isNewer(s, than: installedShort) }
        if let b = item.build, !installedShort.isEmpty { return VersionCompare.isNewer(b, than: installedShort) }
        return false
    }

    /// Fetches and evaluates an app's appcast. Returns nil when up to date.
    static func check(_ app: InstalledApp, options: Options) async throws -> AppUpdate? {
        guard let feed = app.feedURL, let url = URL(string: feed.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            throw UpdateError.parse("Invalid feed address")
        }
        let data = try await UpdateNet.fetch(url)
        let items = try AppcastParser.parse(data)
        guard let item = pickUpdate(items: items, installedShort: app.version, installedBuild: app.build, options: options)
        else { return nil }
        let newVersion: String = {
            let shown = item.displayVersion ?? "?"
            // Same short version, newer build: show the build too.
            if item.shortVersion == app.version, let b = item.build, b != shown { return "\(shown) (\(b))" }
            return shown
        }()
        var notes: String?
        if let html = item.descriptionHTML {
            let t = UpdateText.plain(fromHTML: html)
            if !t.isEmpty { notes = t }
        }
        return AppUpdate(
            id: app.id, key: app.key, name: app.name, bundleID: app.bundleID, path: app.path,
            installedVersion: app.version.isEmpty ? app.build : app.version,
            newVersion: newVersion, source: .sparkle, notes: notes,
            notesURL: item.notesLink, downloadURL: item.downloadURL, pageURL: nil, caskToken: nil,
            isCritical: item.critical, pubDate: item.pubDate)
    }
}
