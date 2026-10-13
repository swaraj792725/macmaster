import Foundation

struct CleanerScanContext: Sendable {
    var runningBundleIDs: Set<String>
    var logMinAge: TimeInterval = 7 * 86_400
    var downloadsMinAge: TimeInterval = 90 * 86_400
}

/// Stateless scanners. Every function is nonisolated so it runs off the main thread.
enum CleanerScanner {
    private static var fm: FileManager { .default }
    private static var home: URL { AppPaths.home }

    // MARK: Entry

    static func scan(_ id: CleanerCategoryID, ctx: CleanerScanContext) async -> [CleanerItem] {
        let items: [CleanerItem]
        switch id {
        case .userCaches: items = await userCaches(ctx)
        case .systemCaches: items = await systemCaches()
        case .logs: items = await userLogs(ctx)
        case .crashReports: items = await crashReports()
        case .systemLogs: items = await systemLogs(ctx)
        case .trash: items = await trash()
        case .browserCaches: items = await browserCaches()
        case .browserPrivacy: items = await browserPrivacy(ctx)
        case .devDerivedData: items = await derivedData()
        case .devCaches: items = await devCaches()
        case .devReview: items = await devReview()
        case .mail: items = await mail()
        case .messages: items = await messages()
        case .oldDownloads: items = await oldDownloads(ctx)
        case .installers: items = await installers()
        case .snapshots: items = await snapshots()
        }
        return items.sorted { $0.size > $1.size }
    }

    // MARK: Helpers

    private static func kids(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [])) ?? []
    }

    private static func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Sizes URLs with bounded concurrency.
    private static func measure(_ urls: [URL]) async -> [URL: Int64] {
        await withTaskGroup(of: (URL, Int64).self) { group in
            var it = urls.makeIterator()
            var out: [URL: Int64] = [:]
            for _ in 0..<8 {
                if let u = it.next() { group.addTask { (u, AppPaths.allocatedSize(of: u)) } }
            }
            while let r = await group.next() {
                out[r.0] = r.1
                if let u = it.next() { group.addTask { (u, AppPaths.allocatedSize(of: u)) } }
            }
            return out
        }
    }

    private static func build(_ urls: [URL], _ cat: CleanerCategoryID, action: CleanerAction,
                              detail: ((URL) -> String?)? = nil,
                              name: ((URL) -> String)? = nil,
                              keepEmpty: Bool = false) async -> [CleanerItem] {
        let sizes = await measure(urls)
        return urls.compactMap { u in
            let s = sizes[u] ?? 0
            if s == 0 && !keepEmpty { return nil }
            return CleanerItem(category: cat, name: name?(u) ?? u.lastPathComponent,
                               detail: detail?(u), urls: [u], size: s, action: action)
        }
    }

    // MARK: Caches

    /// Needed by the system or iCloud — never offered.
    private static let skipExact: Set<String> = [
        "CloudKit", "FamilyCircle", "com.apple.bird", "com.apple.akd", "com.apple.nsurlsessiond",
        "com.apple.cloudd", "com.apple.iCloudHelper", "com.apple.accountsd", "com.apple.homed",
        "com.apple.HomeKit", "com.apple.appstoreagent", "com.apple.commerce", "com.apple.parsecd",
        "com.apple.assistantd", "com.apple.ap.adprivacyd", "com.apple.Maps", "com.apple.findmy",
        "com.apple.security", "com.apple.keychainaccess", "com.apple.tccd", "com.apple.trustd",
        "com.apple.ProgressReporting", "com.apple.proactive.PersonalizationPortrait",
    ]
    private static let skipPrefixes = [
        "com.apple.bird", "com.apple.CloudKit", "com.apple.iCloud", "com.apple.accounts",
        "com.apple.nsurlsession", "com.apple.akd", "com.apple.cloudd", "com.apple.HomeKit",
        "com.apple.Safari", "com.apple.AddressBook", "com.apple.photoanalysisd", "com.apple.Photos",
    ]
    /// Owned by the Browser / Developer categories.
    private static let ownedElsewhere: Set<String> = [
        "Google", "Microsoft Edge", "BraveSoftware", "company.thebrowser.Browser", "Firefox",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "Chromium",
        "org.swift.swiftpm", "CocoaPods", "org.carthage.CarthageKit", "Yarn", "pip", "Homebrew",
        "go-build", "deno", "com.apple.dt.Xcode",
    ]

    private static func shouldSkipCache(_ name: String, ctx: CleanerScanContext) -> Bool {
        if name.hasPrefix(".") { return true }
        if skipExact.contains(name) || ownedElsewhere.contains(name) { return true }
        if skipPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if name.localizedCaseInsensitiveContains("keychain") { return true }
        if ctx.runningBundleIDs.contains(name) { return true }
        if let me = Bundle.main.bundleIdentifier, name == me { return true }
        return false
    }

    private static func userCaches(_ ctx: CleanerScanContext) async -> [CleanerItem] {
        let root = home.appendingPathComponent("Library/Caches")
        let urls = kids(root).filter { !shouldSkipCache($0.lastPathComponent, ctx: ctx) }
        return await build(urls, .userCaches, action: .delete)
    }

    private static func systemCaches() async -> [CleanerItem] {
        let root = URL(fileURLWithPath: "/Library/Caches")
        let ctx = CleanerScanContext(runningBundleIDs: [])
        let urls = kids(root).filter { !shouldSkipCache($0.lastPathComponent, ctx: ctx) && fm.isReadableFile(atPath: $0.path) }
        return await build(urls, .systemCaches, action: .adminDelete, detail: { _ in "Needs administrator" })
    }

    // MARK: Logs & reports

    private static func userLogs(_ ctx: CleanerScanContext) async -> [CleanerItem] {
        let root = home.appendingPathComponent("Library/Logs")
        let cutoff = Date().addingTimeInterval(-ctx.logMinAge)
        let urls = kids(root).filter {
            $0.lastPathComponent != "DiagnosticReports" && !$0.lastPathComponent.hasPrefix(".")
                && (modDate($0) ?? .distantFuture) < cutoff
        }
        return await build(urls, .logs, action: .delete,
                           detail: { "Modified " + CleanerFormat.relative(modDate($0)) })
    }

    private static func crashReports() async -> [CleanerItem] {
        let roots = [home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                     home.appendingPathComponent("Library/Application Support/CrashReporter")]
        let urls = roots.flatMap { kids($0) }.filter { !$0.lastPathComponent.hasPrefix(".") }
        return await build(urls, .crashReports, action: .delete,
                           detail: { "Modified " + CleanerFormat.relative(modDate($0)) })
    }

    private static func systemLogs(_ ctx: CleanerScanContext) async -> [CleanerItem] {
        let cutoff = Date().addingTimeInterval(-ctx.logMinAge)
        var urls: [URL] = []
        for dir in ["/Library/Logs", "/Library/Logs/DiagnosticReports"] {
            for u in kids(URL(fileURLWithPath: dir)) where !u.lastPathComponent.hasPrefix(".")
                && u.lastPathComponent != "DiagnosticReports"
                && (modDate(u) ?? .distantFuture) < cutoff && fm.isReadableFile(atPath: u.path) {
                urls.append(u)
            }
        }
        // /var/log: only rotated or stale regular files, never directories.
        for u in kids(URL(fileURLWithPath: "/private/var/log")) where !isDir(u) && !isSymlink(u)
            && (modDate(u) ?? .distantFuture) < cutoff && fm.isReadableFile(atPath: u.path) {
            urls.append(u)
        }
        return await build(urls, .systemLogs, action: .adminDelete,
                           detail: { "\(CleanerFormat.abbreviatedPath($0.deletingLastPathComponent())) · needs administrator" })
    }

    // MARK: Trash

    private static func trash() async -> [CleanerItem] {
        var urls = kids(home.appendingPathComponent(".Trash"))
        let uid = getuid()
        for vol in kids(URL(fileURLWithPath: "/Volumes")) {
            urls += kids(vol.appendingPathComponent(".Trashes/\(uid)"))
        }
        urls = urls.filter { $0.lastPathComponent != ".DS_Store" }
        return await build(urls, .trash, action: .delete,
                           detail: { CleanerFormat.abbreviatedPath($0.deletingLastPathComponent()) })
    }

    // MARK: Browsers

    struct Browser {
        let name: String
        let bundleID: String
        let cacheDirs: [String]              // relative to home
        let chromiumBase: String?            // relative to home; profiles live inside
        let chromiumCacheSubdirs: [String]
        let historyFiles: [String]           // relative to home, or per-profile if chromiumBase set
        let cookieFiles: [String]
    }

    private static let chromiumCacheSubs = ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage", "DawnCache"]
    private static let chromiumHistory = ["History", "History-journal", "Top Sites", "Visited Links"]
    private static let chromiumCookies = ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]

    static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari",
                cacheDirs: ["Library/Caches/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Caches"],
                chromiumBase: nil, chromiumCacheSubdirs: [],
                historyFiles: ["Library/Safari/History.db", "Library/Safari/History.db-wal", "Library/Safari/History.db-shm",
                               "Library/Safari/LastSession.plist", "Library/Safari/TopSites.plist"],
                cookieFiles: ["Library/Cookies/Cookies.binarycookies",
                              "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"]),
        Browser(name: "Chrome", bundleID: "com.google.Chrome", cacheDirs: ["Library/Caches/Google/Chrome"],
                chromiumBase: "Library/Application Support/Google/Chrome", chromiumCacheSubdirs: chromiumCacheSubs,
                historyFiles: chromiumHistory, cookieFiles: chromiumCookies),
        Browser(name: "Edge", bundleID: "com.microsoft.edgemac", cacheDirs: ["Library/Caches/Microsoft Edge"],
                chromiumBase: "Library/Application Support/Microsoft Edge", chromiumCacheSubdirs: chromiumCacheSubs,
                historyFiles: chromiumHistory, cookieFiles: chromiumCookies),
        Browser(name: "Brave", bundleID: "com.brave.Browser", cacheDirs: ["Library/Caches/BraveSoftware"],
                chromiumBase: "Library/Application Support/BraveSoftware/Brave-Browser", chromiumCacheSubdirs: chromiumCacheSubs,
                historyFiles: chromiumHistory, cookieFiles: chromiumCookies),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", cacheDirs: ["Library/Caches/company.thebrowser.Browser"],
                chromiumBase: "Library/Application Support/Arc/User Data", chromiumCacheSubdirs: chromiumCacheSubs,
                historyFiles: chromiumHistory, cookieFiles: chromiumCookies),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", cacheDirs: ["Library/Caches/com.vivaldi.Vivaldi"],
                chromiumBase: "Library/Application Support/Vivaldi", chromiumCacheSubdirs: chromiumCacheSubs,
                historyFiles: chromiumHistory, cookieFiles: chromiumCookies),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera", cacheDirs: ["Library/Caches/com.operasoftware.Opera"],
                chromiumBase: nil, chromiumCacheSubdirs: [], historyFiles: [], cookieFiles: []),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox",
                cacheDirs: ["Library/Caches/Firefox", "Library/Caches/org.mozilla.firefox"],
                chromiumBase: nil, chromiumCacheSubdirs: [],
                historyFiles: [],   // history shares places.sqlite with bookmarks — never touched
                cookieFiles: []),   // handled through profile glob below
    ]

    private static func chromiumProfiles(_ base: URL) -> [URL] {
        kids(base).filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
    }

    private static func firefoxProfiles() -> [URL] {
        kids(home.appendingPathComponent("Library/Application Support/Firefox/Profiles"))
    }

    private static func cachePaths(_ b: Browser) -> [URL] {
        var out = b.cacheDirs.map { home.appendingPathComponent($0) }
        if let base = b.chromiumBase {
            for p in chromiumProfiles(home.appendingPathComponent(base)) {
                out += b.chromiumCacheSubdirs.map { p.appendingPathComponent($0) }
            }
        }
        return out.filter { exists($0) && !isSymlink($0) }
    }

    private static func browserCaches() async -> [CleanerItem] {
        var out: [CleanerItem] = []
        for b in browsers {
            let paths = cachePaths(b)
            if paths.isEmpty { continue }
            let sizes = await measure(paths)
            let total = sizes.values.reduce(0, +)
            guard total > 0 else { continue }
            out.append(CleanerItem(category: .browserCaches, name: "\(b.name) cache",
                                   detail: "\(paths.count) location\(paths.count == 1 ? "" : "s")",
                                   urls: paths, size: total, action: .delete))
        }
        return out
    }

    private static func privacyPaths(_ b: Browser, cookies: Bool) -> [URL] {
        var out: [URL] = []
        let files = cookies ? b.cookieFiles : b.historyFiles
        if let base = b.chromiumBase {
            for p in chromiumProfiles(home.appendingPathComponent(base)) {
                out += files.map { p.appendingPathComponent($0) }
            }
        } else {
            out += files.map { home.appendingPathComponent($0) }
        }
        if cookies && b.bundleID == "org.mozilla.firefox" {
            for p in firefoxProfiles() {
                for f in ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"] { out.append(p.appendingPathComponent(f)) }
            }
        }
        return out.filter { exists($0) && !isSymlink($0) }
    }

    private static func browserPrivacy(_ ctx: CleanerScanContext) async -> [CleanerItem] {
        var out: [CleanerItem] = []
        for b in browsers {
            let running = ctx.runningBundleIDs.contains(b.bundleID)
            for (label, cookies) in [("history", false), ("cookies & site data", true)] {
                let paths = privacyPaths(b, cookies: cookies)
                if paths.isEmpty { continue }
                let sizes = await measure(paths)
                let total = sizes.values.reduce(0, +)
                guard total > 0 else { continue }
                var item = CleanerItem(category: .browserPrivacy, name: "\(b.name) \(label)",
                                       detail: cookies ? "Signs you out of websites" : "Browsing history",
                                       urls: paths, size: total, action: .trash)
                if running { item.blockedReason = "Quit \(b.name) first" }
                out.append(item)
            }
        }
        return out
    }

    // MARK: Developer

    private static func derivedData() async -> [CleanerItem] {
        let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let urls = kids(root).filter { !$0.lastPathComponent.hasPrefix(".") }
        return await build(urls, .devDerivedData, action: .delete, detail: { "Modified " + CleanerFormat.relative(modDate($0)) },
                           name: { u in
            let n = u.lastPathComponent
            if let i = n.lastIndex(of: "-"), n.distance(from: i, to: n.endIndex) > 20 { return String(n[..<i]) }
            return n
        })
    }

    private static let devCacheSpecs: [(title: String, rel: String)] = [
        ("Xcode caches", "Library/Caches/com.apple.dt.Xcode"),
        ("CoreSimulator caches", "Library/Developer/CoreSimulator/Caches"),
        ("Swift Package Manager cache", "Library/Caches/org.swift.swiftpm"),
        ("CocoaPods cache", "Library/Caches/CocoaPods"),
        ("Carthage cache", "Library/Caches/org.carthage.CarthageKit"),
        ("Gradle caches", ".gradle/caches"),
        ("npm cache", ".npm/_cacache"),
        ("Yarn cache", "Library/Caches/Yarn"),
        ("pnpm store", "Library/pnpm/store"),
        ("pnpm store", ".local/share/pnpm/store"),
        ("pip cache", "Library/Caches/pip"),
        ("Go build cache", "Library/Caches/go-build"),
        ("Cargo registry cache", ".cargo/registry/cache"),
        ("Bun cache", ".bun/install/cache"),
        ("Deno cache", "Library/Caches/deno"),
    ]

    private static func devCaches() async -> [CleanerItem] {
        let specs = devCacheSpecs.map { ($0.title, home.appendingPathComponent($0.rel)) }
            .filter { isDir($0.1) && !isSymlink($0.1) }
        let sizes = await measure(specs.map { $0.1 })
        var out: [CleanerItem] = specs.compactMap { title, url in
            let s = sizes[url] ?? 0
            guard s > 0 else { return nil }
            let note = title == "pnpm store" ? " · shared with projects through hard links, so real savings may be lower" : ""
            return CleanerItem(category: .devCaches, name: title, detail: CleanerFormat.abbreviatedPath(url) + note,
                               urls: [url], size: s, action: .delete)
        }
        // Homebrew: the official cleanup removes old versions and stale downloads.
        let brewCache = home.appendingPathComponent("Library/Caches/Homebrew")
        if let brew = CleanerTool.find("brew"), isDir(brewCache) {
            let s = AppPaths.allocatedSize(of: brewCache)
            if s > 0 {
                out.append(CleanerItem(category: .devCaches, name: "Homebrew cache",
                                       detail: "brew cleanup -s", urls: [brewCache], size: s,
                                       action: .command(CleanerCommand(executable: brew, args: ["cleanup", "-s"], admin: false,
                                                                      label: "brew cleanup"))))
            }
        }
        return out
    }

    private static func devReview() async -> [CleanerItem] {
        var out: [CleanerItem] = []
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        out += await build(kids(xcode.appendingPathComponent("Archives")).filter { isDir($0) }, .devReview, action: .trash,
                           detail: { _ in "Xcode Archives" }, name: { "Archives · " + $0.lastPathComponent })
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let dir = xcode.appendingPathComponent("\(platform) DeviceSupport")
            out += await build(kids(dir).filter { isDir($0) }, .devReview, action: .trash,
                               detail: { _ in "\(platform) device support — re-downloaded when a device connects" },
                               name: { "\(platform) DeviceSupport · " + $0.lastPathComponent })
        }
        if let xcrun = CleanerTool.find("xcrun") {
            let r = await Shell.runAsync(xcrun, ["simctl", "list", "devices", "unavailable"], timeout: 20)
            let count = r.stdout.split(separator: "\n").filter { $0.contains("(") && $0.contains("-") && !$0.hasPrefix("==") }.count
            if r.ok && count > 0 {
                out.append(CleanerItem(category: .devReview, name: "Unavailable simulators",
                                       detail: "\(count) simulator\(count == 1 ? "" : "s") for removed runtimes",
                                       urls: [], size: 0,
                                       action: .command(CleanerCommand(executable: xcrun, args: ["simctl", "delete", "unavailable"],
                                                                      admin: false, label: "simctl delete unavailable"))))
            }
        }
        if let docker = CleanerTool.find("docker") {
            let data = home.appendingPathComponent("Library/Containers/com.docker.docker/Data")
            if isDir(data) {
                let s = AppPaths.allocatedSize(of: data)
                out.append(CleanerItem(category: .devReview, name: "Docker unused data",
                                       detail: "Docker uses \(Fmt.bytes(s)) in total. Runs `docker system prune -f` (stopped containers, dangling images). Docker must be running.",
                                       urls: [data], size: 0,
                                       action: .command(CleanerCommand(executable: docker, args: ["system", "prune", "-f"],
                                                                      admin: false, label: "docker system prune"))))
            }
        }
        return out
    }

    // MARK: Personal files

    private static func mail() async -> [CleanerItem] {
        let dir = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        return await build(kids(dir), .mail, action: .trash, detail: { "Modified " + CleanerFormat.relative(modDate($0)) })
    }

    private static func messages() async -> [CleanerItem] {
        let dir = home.appendingPathComponent("Library/Messages/Attachments")
        guard isDir(dir) else { return [] }
        let readable = (try? fm.contentsOfDirectory(atPath: dir.path)) != nil
        let size = readable ? AppPaths.allocatedSize(of: dir) : 0
        return [CleanerItem(category: .messages, name: "Messages attachments",
                            detail: readable ? "Deleting these removes attachments from your conversations. Open the folder to review."
                                             : "Grant Full Disk Access to see the size.",
                            urls: [dir], size: size, action: .info)]
    }

    private static let installerExts: Set<String> = ["dmg", "pkg", "xip", "zip"]

    private static func oldDownloads(_ ctx: CleanerScanContext) async -> [CleanerItem] {
        let cutoff = Date().addingTimeInterval(-ctx.downloadsMinAge)
        let urls = kids(home.appendingPathComponent("Downloads")).filter {
            !$0.lastPathComponent.hasPrefix(".") && !installerExts.contains($0.pathExtension.lowercased())
                && (modDate($0) ?? .distantFuture) < cutoff
        }
        return await build(urls, .oldDownloads, action: .trash, detail: { "Modified " + CleanerFormat.relative(modDate($0)) })
    }

    private static func installers() async -> [CleanerItem] {
        let urls = ["Downloads", "Desktop"].flatMap { kids(home.appendingPathComponent($0)) }
            .filter { installerExts.contains($0.pathExtension.lowercased()) && !isDir($0) }
        return await build(urls, .installers, action: .trash,
                           detail: { "\($0.deletingLastPathComponent().lastPathComponent) · " + CleanerFormat.relative(modDate($0)) })
    }

    // MARK: Time Machine

    private static func snapshots() async -> [CleanerItem] {
        guard let tmutil = CleanerTool.find("tmutil") else { return [] }
        let r = await Shell.runAsync(tmutil, ["listlocalsnapshots", "/"], timeout: 20)
        guard r.ok else { return [] }
        var out: [CleanerItem] = []
        for line in r.stdout.split(separator: "\n") {
            let s = String(line)
            guard let range = s.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { continue }
            let stamp = String(s[range])
            out.append(CleanerItem(category: .snapshots, name: "Snapshot " + prettyStamp(stamp),
                                   detail: "Local APFS snapshot · size not reported by macOS",
                                   urls: [], size: 0,
                                   action: .command(CleanerCommand(executable: tmutil, args: ["deletelocalsnapshots", stamp],
                                                                  admin: true, label: "tmutil deletelocalsnapshots"))))
        }
        return out
    }

    private static func prettyStamp(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
