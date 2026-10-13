import AppKit
import Foundation

// MARK: - Text helpers

enum UninstallerText {
    /// Lowercase and keep only letters/digits ("Visual Studio-Code" -> "visualstudiocode").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Generic words that must never be treated as a confident name match.
    static let reservedNames: Set<String> = [
        "mail", "notes", "music", "photos", "safari", "calendar", "contacts", "messages", "maps",
        "reminders", "preview", "books", "news", "stocks", "weather", "clock", "finder", "dock",
        "system", "library", "documents", "chat", "code", "terminal", "console", "utilities", "server",
        "cache", "caches", "logs", "preferences", "assistant", "helper", "updater", "launcher", "agent",
        "service", "support", "default", "general", "shared", "data", "user", "users", "public", "temp",
        "tmp", "test", "home", "install", "installer", "browser", "client", "desktop", "studio", "editor",
        "player", "video", "audio", "photo", "image", "files", "file", "text", "keychain", "backup",
        "update", "updates", "settings", "network", "security", "setup", "template", "templates",
    ]

    /// Last bundle-id components that carry no identity ("com.spotify.client").
    static let genericIDTails: Set<String> = [
        "browser", "client", "desktop", "helper", "main", "macos", "mac", "app", "application",
        "agent", "service", "launcher", "updater", "osx", "xos", "gui", "ui", "core",
    ]

    static let knownSuffixes = [".plist", ".savedstate", ".binarycookies", ".lockfile", ".log",
                                ".sfl2", ".sfl3", ".sfl", ".db", ".json", ".ips", ".crash"]

    static func stripKnownSuffix(_ s: String) -> String {
        var r = s
        for _ in 0..<2 {
            let l = r.lowercased()
            if let suf = knownSuffixes.first(where: { l.hasSuffix($0) }) { r = String(r.dropLast(suf.count)) }
        }
        return r
    }

    /// Reverse-DNS-looking lowercase identifier with at least three components.
    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let first = parts[0]
        guard first.count >= 2, first.count <= 10, first.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Candidate identifiers hidden inside an entry name: leading dot, `TEAMID.` and `group.` prefixes removed.
    static func ownerCandidates(_ original: String) -> [String] {
        var s = original
        if s.hasPrefix(".") { s.removeFirst() }
        var out: [String] = [s.lowercased()]
        var teamless = s
        if let dot = s.firstIndex(of: "."), s.distance(from: s.startIndex, to: dot) == 10,
           s[..<dot].allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) }) {
            teamless = String(s[s.index(after: dot)...])
            out.append(teamless.lowercased())
        }
        for base in [s.lowercased(), teamless.lowercased()] {
            for p in ["group.", "systemgroup."] where base.hasPrefix(p) {
                out.append(String(base.dropFirst(p.count)))
            }
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `id` matches `cand` exactly or as a dot-bounded prefix (prefixes ending in "." match any continuation).
    static func idMatch(_ cand: String, _ id: String) -> Bool {
        if id.hasSuffix(".") { return cand.hasPrefix(id) }
        return cand == id || cand.hasPrefix(id + ".")
    }

    static func lastComponent(_ id: String) -> String {
        id.split(separator: ".").last.map(String.init) ?? id
    }
}

// MARK: - Paths

enum UninstallerPaths {
    static let fm = FileManager.default
    static var home: URL { AppPaths.home }
    static var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

    static func tilde(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    static func expandTilde(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }

    static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func ignorable(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name == ".com.apple.containermanagerd.metadata.plist"
    }

    /// Expands `~` and a glob (`*`, `?`, `[...]`) in the last path component.
    static func expand(_ pattern: String) -> [URL] {
        let full = expandTilde(pattern)
        let url = URL(fileURLWithPath: full)
        let last = url.lastPathComponent
        if last.contains("*") || last.contains("?") || last.contains("[") {
            let parent = url.deletingLastPathComponent()
            return children(parent).filter { fnmatch(last, $0.lastPathComponent, FNM_CASEFOLD) == 0 }
                .sorted { $0.path < $1.path }
        }
        return exists(url) ? [url] : []
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func darwinDir(_ name: String) -> URL? {
        let r = Shell.run("/usr/bin/getconf", [name], timeout: 5)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    /// Hard stop: paths that must never be removed by this feature.
    static func isProtected(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if p.isEmpty || p == "/" { return true }
        let denied = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
                      "/dev", "/cores", "/private/var/db", "/private/etc", "/etc", "/var/db",
                      "/Library/Developer/CommandLineTools", "/Library/Apple", "/Library/Frameworks/Python.framework"]
        for d in denied where p == d || p.hasPrefix(d + "/") { return true }
        if p == "/usr" || p == "/usr/local" { return true }
        if p.hasPrefix("/usr/") && !p.hasPrefix("/usr/local/") { return true }
        let h = home.path
        let exact: Set<String> = [
            "/Applications", "/Library", "/Users", "/Volumes", "/opt", "/private", "/var", "/tmp", h,
            h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", h + "/Movies",
            h + "/Music", h + "/Public", h + "/.config", h + "/.cache", h + "/.local", h + "/.ssh", h + "/.Trash",
            h + "/Applications", h + "/Library/Application Support", h + "/Library/Caches", h + "/Library/Preferences",
            h + "/Library/Containers", h + "/Library/Group Containers", h + "/Library/Logs",
            h + "/Library/LaunchAgents", h + "/Library/Mobile Documents", h + "/Library/Keychains",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents",
            "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs",
        ]
        return exact.contains(p)
    }

    /// Category inferred from where a path lives.
    static func category(for url: URL) -> UninstallerCategory {
        let p = url.path
        if p.hasSuffix(".app") && (p.hasPrefix("/Applications/") || p.contains("/Applications/")) { return .application }
        if p.contains("/LaunchAgents/") || p.contains("/LaunchDaemons/") || p.contains("/PrivilegedHelperTools/") { return .launch }
        if p.contains("/DiagnosticReports/") || p.contains("/Library/Logs") { return .logs }
        if p.contains("/Library/Group Containers/") || p.contains("/Library/Containers/") { return .containers }
        if p.contains("/Library/Preferences") { return .preferences }
        if p.contains("/Library/Caches") || p.contains("/.cache/") || p.contains("/Library/HTTPStorages")
            || p.contains("/Library/WebKit") || p.contains("/Library/Cookies") { return .caches }
        if p.contains("/Library/Application Support") || p.contains("/Saved Application State")
            || p.contains("/Library/Application Scripts") || url.lastPathComponent.hasPrefix(".") { return .support }
        return .other
    }
}

// MARK: - Locations

struct UninstallerLocation: Sendable {
    enum Kind: Sendable { case general, preferences, groupContainers, containers, crash, launch, helperTools, temp, root }

    let url: URL
    let title: String
    let category: UninstallerCategory
    var kind: Kind = .general
    var isSystem: Bool = false
    /// Vendor-named subfolders ("Google/Chrome") are inspected one level deeper.
    var vendorNesting: Bool = false
}

enum UninstallerLocations {
    static func all(includeSystem: Bool) -> [UninstallerLocation] {
        let lib = UninstallerPaths.library
        func u(_ sub: String, _ title: String, _ cat: UninstallerCategory,
               _ kind: UninstallerLocation.Kind = .general, nest: Bool = false) -> UninstallerLocation {
            UninstallerLocation(url: lib.appendingPathComponent(sub, isDirectory: true), title: title, category: cat,
                                kind: kind, isSystem: false, vendorNesting: nest)
        }
        var r: [UninstallerLocation] = [
            u("Application Support", "Application Support", .support, nest: true),
            u("Caches", "Caches", .caches, nest: true),
            u("Preferences", "Preferences", .preferences, .preferences),
            u("Preferences/ByHost", "Preferences (ByHost)", .preferences, .preferences),
            u("Containers", "Containers", .containers, .containers),
            u("Group Containers", "Group Containers", .containers, .groupContainers),
            u("Saved Application State", "Saved Application State", .support),
            u("Logs", "Logs", .logs, nest: true),
            u("Logs/DiagnosticReports", "Crash reports", .logs, .crash),
            u("Logs/DiagnosticReports/Retired", "Retired crash reports", .logs, .crash),
            u("Application Support/CrashReporter", "Crash reporter data", .logs, .crash),
            u("HTTPStorages", "HTTP Storages", .caches),
            u("WebKit", "WebKit data", .caches),
            u("Cookies", "Cookies", .caches),
            u("LaunchAgents", "Launch Agents", .launch, .launch),
            u("Application Scripts", "Application Scripts", .support),
            u("Internet Plug-Ins", "Internet Plug-Ins", .other),
            u("PreferencePanes", "Preference Panes", .other),
            u("Services", "Services", .other),
            u("QuickLook", "QuickLook plug-ins", .other),
            u("Spotlight", "Spotlight importers", .other),
            u("Extensions", "Extensions", .other),
            u("Frameworks", "Frameworks", .other),
            u("Autosave Information", "Autosave Information", .support),
            UninstallerLocation(url: lib, title: "Library", category: .other, kind: .root, isSystem: false, vendorNesting: true),
        ]
        if includeSystem {
            let sys = URL(fileURLWithPath: "/Library", isDirectory: true)
            func s(_ sub: String, _ title: String, _ cat: UninstallerCategory,
                   _ kind: UninstallerLocation.Kind = .general, nest: Bool = false) -> UninstallerLocation {
                UninstallerLocation(url: sys.appendingPathComponent(sub, isDirectory: true), title: "/Library \(title)",
                                    category: cat, kind: kind, isSystem: true, vendorNesting: nest)
            }
            r += [
                s("Application Support", "Application Support", .support, nest: true),
                s("Caches", "Caches", .caches, nest: true),
                s("Preferences", "Preferences", .preferences, .preferences),
                s("LaunchAgents", "Launch Agents", .launch, .launch),
                s("LaunchDaemons", "Launch Daemons", .launch, .launch),
                s("PrivilegedHelperTools", "Privileged Helper Tools", .launch, .helperTools),
                s("Internet Plug-Ins", "Internet Plug-Ins", .other),
                s("PreferencePanes", "Preference Panes", .other),
                s("QuickLook", "QuickLook plug-ins", .other),
                s("Spotlight", "Spotlight importers", .other),
                s("Extensions", "Extensions", .other),
                s("Frameworks", "Frameworks", .other),
                s("Logs", "Logs", .logs, nest: true),
                s("Logs/DiagnosticReports", "Crash reports", .logs, .crash),
                s("Application Support/CrashReporter", "Crash reporter data", .logs, .crash),
                UninstallerLocation(url: sys, title: "/Library", category: .other, kind: .root, isSystem: true, vendorNesting: true),
            ]
        }
        if let c = UninstallerPaths.darwinDir("DARWIN_USER_CACHE_DIR") {
            r.append(UninstallerLocation(url: c, title: "Per-user cache folder", category: .caches, kind: .temp, isSystem: false))
        }
        if let t = UninstallerPaths.darwinDir("DARWIN_USER_TEMP_DIR") {
            r.append(UninstallerLocation(url: t, title: "Per-user temp folder", category: .other, kind: .temp, isSystem: false))
        }
        return r
    }
}

// MARK: - launchd plist helpers

struct UninstallerLaunchInfo: Sendable {
    var label: String?
    var program: String?
    var usesBundleProgram: Bool
}

enum UninstallerLaunch {
    static func info(for url: URL) -> UninstallerLaunchInfo {
        guard let plist = UninstallerPaths.readPlist(url) else {
            return UninstallerLaunchInfo(label: nil, program: nil, usesBundleProgram: false)
        }
        let label = plist["Label"] as? String
        var program = plist["Program"] as? String
        if program == nil, let args = plist["ProgramArguments"] as? [String], let first = args.first { program = first }
        return UninstallerLaunchInfo(label: label, program: program, usesBundleProgram: plist["BundleProgram"] != nil)
    }

    static func isSystemDomain(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("/Library/LaunchDaemons") || p.hasPrefix("/Library/PrivilegedHelperTools")
    }
}

// MARK: - Item factory & sizing

enum UninstallerItems {
    static func make(url: URL, category: UninstallerCategory? = nil, confidence: UninstallerConfidence,
                     reason: String, allowApple: Bool = false) -> UninstallerItem {
        let cat = category ?? UninstallerPaths.category(for: url)
        var item = UninstallerItem(id: url.path, url: url, category: cat, confidence: confidence, reason: reason)
        item.modified = UninstallerPaths.modified(url)
        item.allowApple = allowApple
        item.isUserDomain = url.path.hasPrefix(UninstallerPaths.home.path + "/")
        item.requiresAdmin = !UninstallerPaths.fm.isDeletableFile(atPath: url.path)
        if cat == .launch {
            let ext = url.pathExtension.lowercased()
            if ext == "plist" {
                let info = UninstallerLaunch.info(for: url)
                item.launchLabel = info.label ?? url.deletingPathExtension().lastPathComponent
            } else {
                item.launchLabel = url.lastPathComponent
            }
            item.launchSystemDomain = UninstallerLaunch.isSystemDomain(url)
        }
        return item
    }

    static func receipt(id: String, confidence: UninstallerConfidence, reason: String) -> UninstallerItem {
        let url = URL(fileURLWithPath: "/private/var/db/receipts/\(id).plist")
        var item = UninstallerItem(id: "pkg:\(id)", url: url, kind: .receipt(id), category: .receipts,
                                   confidence: confidence, reason: reason)
        item.requiresAdmin = true
        item.isUserDomain = false
        item.modified = UninstallerPaths.modified(url)
        return item
    }

    /// Drops items that live inside another item of the list (removing the parent covers them).
    static func pruneNested(_ items: [UninstallerItem]) -> [UninstallerItem] {
        let files = items.filter { !$0.isReceipt }
        let paths = Set(files.map { $0.url.standardizedFileURL.path })
        var out: [UninstallerItem] = []
        for item in items {
            if item.isReceipt { out.append(item); continue }
            var parent = item.url.standardizedFileURL.deletingLastPathComponent().path
            var nested = false
            while parent.count > 1 {
                if paths.contains(parent) { nested = true; break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            if !nested { out.append(item) }
        }
        return out
    }

    /// Merges duplicates (same id): keeps the highest confidence and its reason.
    static func dedupe(_ items: [UninstallerItem]) -> [UninstallerItem] {
        var order: [String] = []
        var byID: [String: UninstallerItem] = [:]
        for item in items {
            if let existing = byID[item.id] {
                if item.confidence > existing.confidence {
                    var merged = item
                    merged.isBroken = merged.isBroken || existing.isBroken
                    byID[item.id] = merged
                } else if item.isBroken && !existing.isBroken {
                    var merged = existing; merged.isBroken = true; byID[item.id] = merged
                }
            } else {
                byID[item.id] = item
                order.append(item.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Fills `size` for every item using a bounded number of concurrent workers.
    static func measure(_ items: [UninstallerItem], progress: (@Sendable (String) -> Void)? = nil) async -> [UninstallerItem] {
        var result = items
        let indexed = Array(items.enumerated())
        await withTaskGroup(of: (Int, Int64).self) { group in
            var iterator = indexed.makeIterator()
            var running = 0
            let limit = 6
            func addNext(_ group: inout TaskGroup<(Int, Int64)>) -> Bool {
                guard let (i, item) = iterator.next() else { return false }
                let url = item.url
                let isReceipt = item.isReceipt
                group.addTask {
                    if Task.isCancelled || isReceipt { return (i, 0) }
                    return (i, AppPaths.allocatedSize(of: url))
                }
                return true
            }
            while running < limit, addNext(&group) { running += 1 }
            while let (i, size) = await group.next() {
                result[i].size = size
                if Task.isCancelled { group.cancelAll() }
                else { _ = addNext(&group) }
            }
        }
        return result
    }
}
