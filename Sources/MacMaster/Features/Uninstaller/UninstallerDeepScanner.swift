import AppKit
import Foundation

// MARK: - Match keys

struct UninstallerExtraID: Sendable {
    let id: String               // lowercased; trailing "." = namespace
    let confidence: UninstallerConfidence
    let reason: String
}

struct UninstallerKeys: Sendable {
    var displayName: String
    var primaryID: String            // lowercased
    var primaryIDOriginal: String
    var ids: [String]                // primary + embedded helper ids (lowercased), high confidence
    var extra: [UninstallerExtraID]  // medium confidence ids (vendor helpers, related products)
    var nameKeys: Set<String>        // normalized names, >= 4 chars
    var nestedKeys: Set<String>      // + vendor-stripped aliases ("googlechrome" -> "chrome")
    var team: String?
    var vendorDirs: Set<String>      // normalized vendor folder names
    var vendorNorm: String?
}

// MARK: - Matcher

struct UninstallerMatcher: Sendable {
    let keys: UninstallerKeys
    /// Lowercased ids of the *other* installed apps (guards against eating a sibling's files).
    let siblingIDs: [String]
    let appPath: String
    let isApple: Bool

    private func siblingConflict(_ cand: String, _ id: String) -> Bool {
        if id.hasSuffix(".") { return false }
        return siblingIDs.contains { $0.count > id.count && $0.hasPrefix(id + ".") && (cand == $0 || cand.hasPrefix($0 + ".")) }
    }

    /// Bundle-id style matching (incl. group./TEAMID. prefixes).
    func matchBundleish(_ original: String) -> (UninstallerConfidence, String)? {
        for cand in UninstallerText.ownerCandidates(original) {
            if !isApple && (cand.hasPrefix("com.apple.") || cand.hasPrefix("group.com.apple.")) { continue }
            for id in keys.ids where UninstallerText.idMatch(cand, id) && !siblingConflict(cand, id) {
                return (.high, id == keys.primaryID ? "Bundle ID \(keys.primaryIDOriginal)" : "Embedded helper \(id)")
            }
            for e in keys.extra where UninstallerText.idMatch(cand, e.id) && !siblingConflict(cand, e.id) {
                return (e.confidence, e.reason)
            }
        }
        return nil
    }

    func matchName(_ original: String, nested: Bool, dotFolder: Bool = false) -> (UninstallerConfidence, String)? {
        var s = original
        if dotFolder, s.hasPrefix(".") { s.removeFirst() }
        let nb = UninstallerText.normalize(UninstallerText.stripKnownSuffix(s))
        guard nb.count >= 4 else { return nil }
        let pool = nested ? keys.nestedKeys : keys.nameKeys
        if pool.contains(nb) {
            let c: UninstallerConfidence = UninstallerText.reservedNames.contains(nb) ? .low : .medium
            return (c, nested ? "Name matches “\(keys.displayName)” inside a vendor folder" : "Name matches “\(keys.displayName)”")
        }
        if nested, let k = pool.first(where: { $0.count >= 5 && nb.count > $0.count && nb.hasPrefix($0)
            && nb.dropFirst($0.count).allSatisfy { $0.isNumber } }) {
            _ = k
            return (.medium, "Versioned folder of “\(keys.displayName)”")
        }
        return nil
    }

    func matchTeam(_ original: String) -> (UninstallerConfidence, String)? {
        guard let team = keys.team?.lowercased(), original.lowercased().hasPrefix(team + ".") else { return nil }
        let suffix = UninstallerText.normalize(String(original.dropFirst(team.count + 1)))
        let related = keys.nameKeys.contains { suffix.contains($0) } || (keys.vendorNorm.map { $0.count >= 4 && suffix.contains($0) } ?? false)
        if related { return (.medium, "Group container of team \(team.uppercased()); name relates to the app") }
        return (.low, "Group container shared by apps from the same developer (team \(team.uppercased()))")
    }

    private static let datePrefix = try? NSRegularExpression(pattern: #"^(.+?)[_\- ]+(?:\d{4}-\d{2}-\d{2}|\d{8})"#)

    func matchCrash(_ original: String) -> (UninstallerConfidence, String)? {
        if let m = matchBundleish(original) { return (m.0, "Crash/diagnostic file – \(m.1)") }
        guard let rx = Self.datePrefix else { return nil }
        let range = NSRange(original.startIndex..., in: original)
        guard let m = rx.firstMatch(in: original, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: original) else { return nil }
        let nb = UninstallerText.normalize(String(original[r]))
        for k in keys.nameKeys {
            if nb == k || (nb.hasPrefix(k) && nb.dropFirst(k.count).hasPrefix("helper")) {
                return (.medium, "Crash report for “\(keys.displayName)”")
            }
        }
        return nil
    }

    func matchContainerMetadata(_ dir: URL) -> (UninstallerConfidence, String)? {
        let meta = dir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let id = UninstallerPaths.readPlist(meta)?["MCMMetadataIdentifier"] as? String else { return nil }
        if let m = matchBundleish(id) { return (m.0, "Container metadata identifier \(id)") }
        return nil
    }

    func matchLaunchProgram(_ plist: URL) -> (UninstallerConfidence, String)? {
        guard plist.pathExtension.lowercased() == "plist" else { return nil }
        let info = UninstallerLaunch.info(for: plist)
        if let p = info.program, p.hasPrefix(appPath + "/") { return (.high, "Launches an executable inside the app") }
        if let l = info.label, let m = matchBundleish(l) { return (m.0, "launchd label \(l)") }
        return nil
    }

    func matchPackage(_ lowerID: String, kbPrefixes: [String]) -> (UninstallerConfidence, String)? {
        if !isApple && lowerID.hasPrefix("com.apple.") { return nil }
        for id in keys.ids where UninstallerText.idMatch(lowerID, id) { return (.high, "Installed by package \(lowerID)") }
        for e in keys.extra where UninstallerText.idMatch(lowerID, e.id) { return (.medium, "Installed by package \(lowerID)") }
        for p in kbPrefixes where UninstallerText.idMatch(lowerID, p.lowercased()) { return (.medium, "Installed by package \(lowerID)") }
        return nil
    }
}

// MARK: - Scanner

enum UninstallerDeepScanner {
    static func buildKeys(app: UninstallerApp, kb: UninstallerKBEntry?, team: String?, embedded: Set<String>,
                          otherIDs: Set<String>, extra: [UninstallerExtraID]) -> UninstallerKeys {
        let primary = app.bundleID.lowercased()
        let comps = primary.split(separator: ".").map(String.init)
        let vendor: String? = comps.count >= 3 ? comps[1] : nil
        let vendorNorm = vendor.map(UninstallerText.normalize)

        var nameKeys = Set(app.aliases.map(UninstallerText.normalize).filter { $0.count >= 4 })
        if comps.count >= 3, let last = comps.last {
            let nl = UninstallerText.normalize(last)
            if nl.count >= 4 && !UninstallerText.genericIDTails.contains(nl) { nameKeys.insert(nl) }
        }
        var vendorDirs = Set<String>()
        if let v = vendorNorm, v.count >= 4 { vendorDirs.insert(v) }
        for f in kb?.vendorFolders ?? [] { vendorDirs.insert(UninstallerText.normalize(f)) }
        if let kb { for n in kb.names { let nn = UninstallerText.normalize(n); if nn.count >= 4 { nameKeys.insert(nn) } } }

        var nested = nameKeys
        for v in vendorDirs {
            for k in nameKeys where k.hasPrefix(v) && k.count - v.count >= 4 { nested.insert(String(k.dropFirst(v.count))) }
        }

        // Embedded helper ids: namespace of the app = high, same developer namespace = medium.
        var ids = [primary]
        var more = extra
        let vendorPrefix = comps.count >= 3 ? comps.prefix(2).joined(separator: ".") + "." : nil
        let noisy = ["autoupdate", "updater", "licensing", "shared", "common", "sparkle", "crashpad"]
        for h in embedded.sorted() where h != primary && !h.hasPrefix("com.apple.") && !otherIDs.contains(h) {
            if h.hasPrefix(primary + ".") { ids.append(h) }
            else if let vp = vendorPrefix, h.hasPrefix(vp), !noisy.contains(where: { h.contains($0) }) {
                more.append(UninstallerExtraID(id: h, confidence: .medium, reason: "Embedded helper \(h) (same developer)"))
            }
        }
        return UninstallerKeys(displayName: app.name, primaryID: primary, primaryIDOriginal: app.bundleID, ids: ids,
                               extra: more, nameKeys: nameKeys, nestedKeys: nested, team: team,
                               vendorDirs: vendorDirs, vendorNorm: vendorNorm)
    }

    /// Deep-scans every known location for files belonging to `app`.
    static func scan(app: UninstallerApp, installed: [UninstallerApp], includeSystem: Bool,
                     progress: @escaping @Sendable (String) -> Void) async -> [UninstallerItem] {
        progress("Reading code signature…")
        let team = UninstallerAppCatalog.teamID(of: app.url)
        let embedded = UninstallerAppCatalog.embeddedIDs(of: app.url)
        if Task.isCancelled { return [] }

        let others = installed.filter { $0.id != app.id }
        let otherIDs = Set(others.map { $0.bundleID.lowercased() })
        let otherNames = Set(others.flatMap(\.aliases).map(UninstallerText.normalize))

        let kb = UninstallerKB.bestEntry(forApp: app.bundleID, aliases: app.aliases)
        let familyOthersInstalled = kb?.isInstalled(ids: otherIDs, names: otherNames) ?? false

        // Extra ids from the knowledge base (own namespace + related products).
        var extra: [UninstallerExtraID] = []
        var kbSources: [(UninstallerKBEntry, UninstallerConfidence?)] = []
        func ownsPrefix(_ p: String) -> Bool { otherIDs.contains { UninstallerText.idMatch($0, p.lowercased()) } }
        if let kb {
            kbSources.append((kb, nil))
            if !familyOthersInstalled && !(kb.vendorWide && kb.idPrefixes.contains(where: ownsPrefix)) {
                for p in kb.idPrefixes where p.lowercased() != app.bundleID.lowercased() && !ownsPrefix(p) {
                    extra.append(UninstallerExtraID(id: p.lowercased(), confidence: kb.vendorWide ? .medium : .high,
                                                    reason: "\(kb.name) namespace \(p)"))
                }
            }
            for rel in kb.related {
                guard let e = UninstallerKB.entry(id: rel.id), !e.isInstalled(ids: otherIDs, names: otherNames) else { continue }
                kbSources.append((e, rel.cap))
                for p in e.idPrefixes where !ownsPrefix(p) {
                    extra.append(UninstallerExtraID(id: p.lowercased(), confidence: min(rel.cap ?? .medium, .medium),
                                                    reason: "Related: \(e.name)"))
                }
            }
        }

        let keys = buildKeys(app: app, kb: kb, team: team, embedded: embedded, otherIDs: otherIDs, extra: extra)
        let matcher = UninstallerMatcher(keys: keys, siblingIDs: Array(otherIDs), appPath: app.url.path,
                                         isApple: app.bundleID.lowercased().hasPrefix("com.apple."))

        var items: [UninstallerItem] = []

        // 1. The application bundle itself.
        items.append(UninstallerItems.make(url: app.url, category: .application, confidence: .high, reason: "The application"))

        // 2. Library locations.
        let locations = UninstallerLocations.all(includeSystem: includeSystem)
        let locationPaths = Set(locations.map { $0.url.standardizedFileURL.path })
        let nestingRoots = Set(locations.filter(\.vendorNesting).map { $0.url.standardizedFileURL.path })
        for loc in locations {
            if Task.isCancelled { return [] }
            progress(loc.title)
            scanLocation(loc, matcher: matcher, keys: keys, into: &items)
        }

        // 3. Dotfolders in home.
        progress("Home folder")
        scanHome(matcher: matcher, into: &items)

        // 4. Knowledge base.
        progress("Vendor knowledge base")
        for (entry, cap) in kbSources {
            let skipShared = familyOthersInstalled || entry.sharedWithPrefixes.contains { p in ownsPrefix(p) }
            for kp in entry.paths {
                if kp.shared && skipShared { continue }
                for url in UninstallerPaths.expand(kp.path) {
                    var c = kp.confidence
                    if let cap { c = min(c, cap) }
                    let reason = kp.note.isEmpty ? "Known \(entry.name) location" : "\(entry.name): \(kp.note)"
                    items.append(UninstallerItems.make(url: url, confidence: c, reason: reason, allowApple: entry.allowApple))
                }
            }
        }

        // 5. Package receipts.
        if Task.isCancelled { return [] }
        progress("Package receipts")
        var kbPkgPrefixes: [String] = []
        for (e, _) in kbSources { kbPkgPrefixes += e.pkgPrefixes }
        items += scanReceipts(matcher: matcher, keys: keys, kbPrefixes: kbPkgPrefixes)

        // 6. Post-process.
        items = UninstallerItems.dedupe(items)
        items = items.filter { item in
            if item.isReceipt { return true }
            if UninstallerPaths.isProtected(item.url) { return false }
            if !matcher.isApple && !item.allowApple && item.url.lastPathComponent.lowercased().hasPrefix("com.apple.") { return false }
            return true
        }
        items = collapseVendorFolders(items, nestingRoots: nestingRoots, locationPaths: locationPaths)
        items = UninstallerItems.pruneNested(items)
        if Task.isCancelled { return [] }

        progress("Measuring sizes…")
        items = await UninstallerItems.measure(items)
        return sortItems(items)
    }

    static func sortItems(_ items: [UninstallerItem]) -> [UninstallerItem] {
        let order = UninstallerCategory.allCases
        return items.sorted {
            let a = order.firstIndex(of: $0.category) ?? 0, b = order.firstIndex(of: $1.category) ?? 0
            if a != b { return a < b }
            return $0.size > $1.size
        }
    }

    // MARK: Location scan

    private static func scanLocation(_ loc: UninstallerLocation, matcher: UninstallerMatcher, keys: UninstallerKeys,
                                     into items: inout [UninstallerItem]) {
        guard UninstallerPaths.isDirectory(loc.url) else { return }
        for child in UninstallerPaths.children(loc.url) {
            if Task.isCancelled { return }
            let name = child.lastPathComponent
            if UninstallerPaths.ignorable(name) { continue }
            var found: (UninstallerConfidence, String)?
            switch loc.kind {
            case .root: found = nil
            case .crash: found = matcher.matchCrash(name)
            case .containers: found = matcher.matchBundleish(name) ?? matcher.matchContainerMetadata(child)
            case .groupContainers: found = matcher.matchBundleish(name) ?? matcher.matchTeam(name)
            case .launch: found = matcher.matchBundleish(name) ?? matcher.matchLaunchProgram(child)
            case .helperTools, .temp: found = matcher.matchBundleish(name)
            case .preferences, .general: found = matcher.matchBundleish(name) ?? matcher.matchName(name, nested: false)
            }
            if let f = found {
                items.append(UninstallerItems.make(url: child, category: loc.category, confidence: f.0, reason: f.1))
            } else if loc.vendorNesting, UninstallerPaths.isDirectory(child),
                      keys.vendorDirs.contains(UninstallerText.normalize(name)) {
                for sub in UninstallerPaths.children(child) {
                    let sn = sub.lastPathComponent
                    if UninstallerPaths.ignorable(sn) { continue }
                    if let f = matcher.matchBundleish(sn) ?? matcher.matchName(sn, nested: true) {
                        items.append(UninstallerItems.make(url: sub, category: loc.category, confidence: f.0,
                                                           reason: "\(f.1) (in “\(name)”)"))
                    }
                }
            }
        }
    }

    private static func scanHome(matcher: UninstallerMatcher, into items: inout [UninstallerItem]) {
        let home = UninstallerPaths.home
        for child in UninstallerPaths.children(home) where child.lastPathComponent.hasPrefix(".") {
            let n = child.lastPathComponent
            if let f = matcher.matchName(n, nested: false, dotFolder: true) {
                items.append(UninstallerItems.make(url: child, category: .support, confidence: f.0, reason: "Dot-folder – \(f.1)"))
            }
        }
        for sub in [".config", ".cache", ".local/share", ".local/state"] {
            let dir = home.appendingPathComponent(sub)
            for child in UninstallerPaths.children(dir) {
                if let f = matcher.matchName(child.lastPathComponent, nested: false) {
                    items.append(UninstallerItems.make(url: child, category: .support, confidence: f.0,
                                                       reason: "~/\(sub) – \(f.1)"))
                }
            }
        }
    }

    // MARK: Receipts

    private static let sharedDirs: Set<String> = [
        "/", "/Library", "/Library/Application Support", "/Library/LaunchDaemons", "/Library/LaunchAgents",
        "/Library/PrivilegedHelperTools", "/Library/Preferences", "/Library/Internet Plug-Ins", "/Library/Frameworks",
        "/Library/Extensions", "/Library/PreferencePanes", "/Library/Logs", "/Library/Caches", "/Library/Audio",
        "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3", "/Library/Fonts", "/Library/Receipts", "/Applications", "/usr", "/usr/local",
        "/usr/local/bin", "/usr/local/lib", "/usr/local/share", "/usr/local/etc", "/usr/local/include", "/opt",
        "/private", "/private/etc", "/etc", "/Library/Documentation", "/Library/Scripts",
    ]

    private static func scanReceipts(matcher: UninstallerMatcher, keys: UninstallerKeys, kbPrefixes: [String]) -> [UninstallerItem] {
        let r = Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 30)
        guard r.ok else { return [] }
        var out: [UninstallerItem] = []
        var inspected = 0
        for line in r.stdout.split(separator: "\n") {
            let id = String(line).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, let m = matcher.matchPackage(id.lowercased(), kbPrefixes: kbPrefixes) else { continue }
            out.append(UninstallerItems.receipt(id: id, confidence: m.0, reason: m.1))
            guard inspected < 6 else { continue }
            inspected += 1
            for root in packageRoots(id) {
                if UninstallerPaths.isProtected(root) { continue }
                let nb = UninstallerText.normalize(root.deletingPathExtension().lastPathComponent)
                let matches = keys.nameKeys.contains(nb) || matcher.matchBundleish(root.lastPathComponent) != nil
                out.append(UninstallerItems.make(url: root, confidence: matches ? .medium : .low,
                                                 reason: "Installed by package \(id)"))
            }
        }
        return out
    }

    /// App-specific top-level paths created by a package (shared system folders are excluded).
    static func packageRoots(_ id: String) -> [URL] {
        let info = Shell.run("/usr/sbin/pkgutil", ["--pkg-info", id], timeout: 15)
        var location = ""
        var volume = "/"
        for line in info.stdout.split(separator: "\n") {
            if line.hasPrefix("location: ") { location = String(line.dropFirst("location: ".count)) }
            if line.hasPrefix("volume: ") { volume = String(line.dropFirst("volume: ".count)) }
        }
        guard info.ok, volume == "/" else { return [] }
        let files = Shell.run("/usr/sbin/pkgutil", ["--files", id], timeout: 30)
        guard files.ok else { return [] }
        var loc = location.trimmingCharacters(in: CharacterSet(charactersIn: "./ "))
        if loc.isEmpty { loc = "" }
        let base = loc.isEmpty ? "/" : "/" + loc
        var paths = Set<String>()
        for (i, rel) in files.stdout.split(separator: "\n").enumerated() {
            if i > 60_000 { break }
            let p = (base as NSString).appendingPathComponent(String(rel))
            paths.insert((p as NSString).standardizingPath)
        }
        let allowed = ["/Library/", "/Applications/", "/usr/local/", "/opt/"]
        var roots: [URL] = []
        for p in paths {
            guard !sharedDirs.contains(p), allowed.contains(where: { p.hasPrefix($0) }) else { continue }
            let parent = (p as NSString).deletingLastPathComponent
            guard sharedDirs.contains(parent) else { continue }
            let url = URL(fileURLWithPath: p)
            if UninstallerPaths.exists(url) { roots.append(url) }
        }
        return roots.sorted { $0.path < $1.path }
    }

    // MARK: Vendor folders

    /// If every child of a vendor folder ("Google") is already matched, suggest the folder itself instead.
    static func collapseVendorFolders(_ items: [UninstallerItem], nestingRoots: Set<String>, locationPaths: Set<String>) -> [UninstallerItem] {
        var byParent: [String: [UninstallerItem]] = [:]
        for it in items where !it.isReceipt {
            let parent = it.url.deletingLastPathComponent()
            let grand = parent.deletingLastPathComponent().standardizedFileURL.path
            if nestingRoots.contains(grand) { byParent[parent.standardizedFileURL.path, default: []].append(it) }
        }
        var result = items
        for (parentPath, group) in byParent {
            if locationPaths.contains(parentPath) { continue }
            let parent = URL(fileURLWithPath: parentPath)
            if UninstallerPaths.isProtected(parent) { continue }
            let actual = UninstallerPaths.children(parent).filter { !UninstallerPaths.ignorable($0.lastPathComponent) }
            let matched = Set(group.map { $0.url.standardizedFileURL.path })
            guard !actual.isEmpty, actual.allSatisfy({ matched.contains($0.standardizedFileURL.path) }) else { continue }
            let ids = Set(group.map(\.id))
            result.removeAll { ids.contains($0.id) }
            let conf = group.map(\.confidence).min() ?? .medium
            var folder = UninstallerItems.make(url: parent, confidence: conf,
                                               reason: "Vendor folder “\(parent.lastPathComponent)” would be empty after removal")
            folder.allowApple = group.contains { $0.allowApple }
            result.append(folder)
        }
        return result
    }
}
