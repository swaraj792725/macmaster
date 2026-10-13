import AppKit
import Foundation

// MARK: - Result

struct UninstallerHunterResult: Sendable {
    var groups: [UninstallerGroup]
    var brokenItems: [UninstallerItem]
    var installedAppCount: Int
    var scannedEntries: Int
}

// MARK: - Installed-software context

struct UninstallerHunterContext: Sendable {
    var ids: Set<String> = []          // installed bundle ids incl. embedded helpers (lowercased)
    var names: Set<String> = []        // normalized names of installed apps
    var cli: Set<String> = []          // normalized names of installed CLI tools / formulae / casks
    var vendors: Set<String> = []      // normalized vendor tokens (2nd bundle id component)
    var idPrefixes: Set<String> = []   // all >= 3 component prefixes of installed ids

    mutating func add(id raw: String) {
        let id = raw.lowercased()
        ids.insert(id)
        let comps = id.split(separator: ".").map(String.init)
        if comps.count >= 3 {
            vendors.insert(UninstallerText.normalize(comps[1]))
            for n in 3..<max(comps.count, 3) { idPrefixes.insert(comps.prefix(n).joined(separator: ".")) }
            let last = UninstallerText.normalize(comps[comps.count - 1])
            if last.count >= 4 && !UninstallerText.genericIDTails.contains(last) { names.insert(last) }
        }
    }

    mutating func add(alias: String) {
        let n = UninstallerText.normalize(alias)
        if !n.isEmpty { names.insert(n) }
    }

    func isInstalled(owner: String) -> Bool {
        let comps = owner.split(separator: ".").map(String.init)
        if comps.count >= 3 {
            for n in stride(from: comps.count, through: 3, by: -1) where ids.contains(comps.prefix(n).joined(separator: ".")) {
                return true
            }
        } else if ids.contains(owner) { return true }
        if idPrefixes.contains(owner) { return true }
        if let l = comps.last {
            let last = UninstallerText.normalize(l)
            if last.count >= 5 && (names.contains(last) || cli.contains(last)) { return true }
        }
        return false
    }

    private static let helperSuffixes: Set<String> = [
        "helper", "helpers", "updater", "autoupdate", "update", "agent", "daemon", "service", "launcher", "shipit",
        "crashpad", "crashreporter", "installer", "cache", "caches", "logs", "log",
    ]

    func isInstalledName(_ nb: String) -> Bool {
        if names.contains(nb) || cli.contains(nb) || vendors.contains(nb) { return true }
        for a in names where a.count >= 5 {
            if nb.hasPrefix(a) {
                let rest = String(nb.dropFirst(a.count))
                if Self.helperSuffixes.contains(rest) || rest.allSatisfy({ $0.isNumber }) { return true }
            }
            if nb.count >= 5 && a.hasPrefix(nb) { return true }
        }
        return false
    }
}

// MARK: - Hunter

enum UninstallerHunter {
    /// Normalized names of Apple / system / tooling folders that are never app leftovers.
    private static let systemNames: Set<String> = [
        "crashreporter", "addressbook", "clouddocs", "cloudkit", "knowledge", "mobilesync", "icloud", "callhistorydb",
        "callhistorytransactions", "dock", "fileprovider", "animoji", "appstore", "facetime", "syncservices",
        "differentialprivacy", "siri", "stickers", "gamekit", "networkserviceproxy", "mobiledocuments", "quicklook",
        "safari", "spotlight", "tcc", "wallpaper", "accounts", "assistant", "audio", "biome", "coreparsec", "diagnostics",
        "diskimages", "familycircle", "geoservices", "homebrew", "identityservices", "metadata", "mobileme",
        "notificationcenter", "passes", "photos", "privatecloudcompute", "sharedfilelist", "suggestions",
        "systemextensions", "trial", "universalaccess", "voicememos", "wallet", "xprotect", "temporaryitems",
        "cloudstorage", "mail", "calendars", "contacts", "messages", "reminders", "music", "news", "stocks", "books",
        "maps", "weather", "shortcuts", "freeform", "journal", "typescript", "cocoapods", "swiftpm", "carthage",
        "pipenv", "pypoetry", "poetry", "ccache", "sccache", "yarn", "npm", "pnpm", "node", "python", "gradle",
        "maven", "composer", "pip", "applepay", "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains",
        "logs", "diagnosticreports", "launchservices", "com", "default", "shared", "keychains", "preferences",
        "containers", "caches", "applicationsupport", "sandbox", "audiounits", "components", "fonts", "colorsync",
        "webkit", "cookies", "httpstorages", "savedapplicationstate", "internetplugins", "preferencepanes",
        "privilegedhelpertools", "extensions", "frameworks", "printers", "screensavers", "sounds", "filevault",
        // Apple apps, daemons and frameworks that keep plain-named folders.
        "logic", "logicpro", "proapps", "motion", "finalcutpro", "garageband", "mainstage", "compressor", "imovie", "ilifemediabrowser",
        "scripteditor", "btserver", "sirientitycache", "passkit", "sharedimagecache", "askpermissiond",
        "amsdatamigratortool", "audiounitcache", "sesstorage", "icdd", "campouiinternal", "jetpackcache",
        "installertelemetry", "minilauncher", "appanalytics", "sync", "commerce", "storeassets", "coreduet",
        "ckpersistentstore", "familysettings", "screentime", "homekit", "airplay", "bluetooth", "corespotlight",
        "translation", "rapport", "osanalytics", "networkextension", "dmd", "fsck", "managedclient", "ubiquity",
        "callservices", "telephonyutilities", "nanoregistry", "remotemanagement", "speech", "dictation",
        "voicetrigger", "corerecents", "corefollowup", "akd", "cloudphotos", "assetsd", "mediaanalysisd",
        // Developer tool caches: owned by CLIs, handled by the Cleaner instead.
        "gobuild", "nodegyp", "turborepo", "prisma", "electron", "electronbuilder", "segment", "sentrycrash",
        "caddy", "deno", "bun", "rustup", "cargo", "pnpmstore", "playwrightgo", "msbuild", "nuget", "dotnet",
    ]

    /// Analytics / crash SDK identifiers embedded in many apps — never evidence of a specific uninstalled app.
    private static let sdkOwnerPrefixes = [
        "com.segment.", "io.sentry", "com.datadoghq", "dev.sigstore", "com.crashlytics", "io.fabric.",
        "com.bugsnag.", "com.amplitude.", "com.mixpanel.", "org.sparkle-project.", "com.google.firebase",
        "com.getsentry.", "com.newrelic.", "com.appcenter.", "com.microsoft.appcenter",
    ]

    private static let skipOwnerPrefixes = [
        "com.apple.", "group.com.apple.", "systemgroup.com.apple.", "org.cups.", "com.openssh.", "org.openbsd.",
        "org.swift.", "homebrew.", "com.github.homebrew", "org.macports.", "org.nixos.", "com.vmware.fusion.",
    ]

    private static let electronMarkers = ["GPUCache", "Code Cache", "Local Storage", "blob_storage", "Session Storage",
                                          "Crashpad", "DawnCache", "Network Persistent State"]

    // MARK: Context

    static func buildContext(apps: [UninstallerApp], runningIDs: Set<String>,
                             progress: @escaping @Sendable (String) -> Void) -> UninstallerHunterContext {
        var ctx = UninstallerHunterContext()
        progress("Reading installed apps…")
        for (i, app) in apps.enumerated() {
            if Task.isCancelled { return ctx }
            ctx.add(id: app.bundleID)
            for a in app.aliases { ctx.add(alias: a) }
            for h in UninstallerAppCatalog.embeddedIDs(of: app.url) { ctx.add(id: h) }
            if i % 25 == 0 { progress("Reading installed apps… \(i)/\(apps.count)") }
        }
        progress("Asking Spotlight for other apps…")
        for sp in UninstallerAppCatalog.spotlightApps() {
            ctx.add(id: sp.id)
            for a in sp.aliases { ctx.add(alias: a) }
        }
        for id in runningIDs { ctx.add(id: id) }

        progress("Detecting command-line tools…")
        let h = UninstallerPaths.home
        let dirs = ["/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/Cellar", "/usr/local/Caskroom",
                    "/opt/homebrew/bin", "/usr/local/bin", h.appendingPathComponent(".cargo/bin").path,
                    h.appendingPathComponent(".local/bin").path]
        for d in dirs {
            for c in UninstallerPaths.children(URL(fileURLWithPath: d)) where UninstallerPaths.fm.fileExists(atPath: c.path) {
                ctx.cli.insert(UninstallerText.normalize(c.lastPathComponent))
            }
        }
        return ctx
    }

    // MARK: Accumulation

    private struct Acc {
        var id: String
        var name: String
        var subtitle: String
        var symbol: String
        var isDeveloper: Bool
        var nameKeys: Set<String>
    }

    private struct Placed {
        var key: String
        var item: UninstallerItem
        var generic: Bool
    }

    private static func isGUIEvidence(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/Containers/") || p.contains("/Library/Group Containers/")
            || p.contains("/Saved Application State/") || p.contains("/Library/HTTPStorages/")
            || p.contains("/Library/WebKit/") || p.contains("/Application Scripts/")
    }

    private static func prettyName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    // MARK: Scan

    static func scan(apps: [UninstallerApp], runningIDs: Set<String>, includeSystem: Bool,
                     progress: @escaping @Sendable (String) -> Void) async -> UninstallerHunterResult {
        let ctx = buildContext(apps: apps, runningIDs: runningIDs, progress: progress)
        if Task.isCancelled { return UninstallerHunterResult(groups: [], brokenItems: [], installedAppCount: 0, scannedEntries: 0) }

        var accs: [String: Acc] = [:]
        var placed: [Placed] = []
        var nameOnly: [(item: UninstallerItem, nb: String, raw: String, electron: Bool)] = []
        var broken: [String: UninstallerItem] = [:]
        var scanned = 0

        let vendorFolderNames: Set<String> = Set(UninstallerKB.entries.flatMap(\.vendorFolders).map(UninstallerText.normalize))

        func kbAcc(_ e: UninstallerKBEntry) -> String {
            let key = "kb:" + e.id
            if accs[key] == nil {
                var keysSet = Set(e.names.map(UninstallerText.normalize))
                for n in e.names { keysSet.insert(UninstallerText.normalize(n)) }
                accs[key] = Acc(id: key, name: e.name, subtitle: e.isDeveloper ? "Developer tooling" : "Known app",
                                symbol: e.symbol, isDeveloper: e.isDeveloper, nameKeys: keysSet)
            }
            return key
        }
        func genericAcc(_ owner: String) -> String {
            let comps = owner.split(separator: ".").map(String.init)
            let keyComps = comps.prefix(3).joined(separator: ".")
            let key = "id:" + keyComps
            if accs[key] == nil {
                var last = comps.prefix(3).last ?? owner
                if comps.count >= 3, UninstallerText.genericIDTails.contains(UninstallerText.normalize(last)) { last = comps[1] }
                accs[key] = Acc(id: key, name: prettyName(last), subtitle: keyComps, symbol: "app.dashed",
                                isDeveloper: false, nameKeys: [UninstallerText.normalize(last)])
            }
            return key
        }

        let locations = UninstallerLocations.all(includeSystem: includeSystem)
        let locationPaths = Set(locations.map { $0.url.standardizedFileURL.path })
        let nestingRoots = Set(locations.filter(\.vendorNesting).map { $0.url.standardizedFileURL.path })

        // 1. Library locations.
        for loc in locations where loc.kind != .root {
            if Task.isCancelled { break }
            progress(loc.title)
            guard UninstallerPaths.isDirectory(loc.url) else { continue }
            for child in UninstallerPaths.children(loc.url) {
                if Task.isCancelled { break }
                let name = child.lastPathComponent
                if UninstallerPaths.ignorable(name) { continue }
                scanned += 1
                let stripped = UninstallerText.stripKnownSuffix(name)
                var owner = UninstallerText.ownerCandidates(stripped).last(where: UninstallerText.looksLikeBundleID)
                if owner == nil && loc.kind == .containers {
                    let meta = child.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                    if let id = UninstallerPaths.readPlist(meta)?["MCMMetadataIdentifier"] as? String {
                        owner = UninstallerText.ownerCandidates(id).last(where: UninstallerText.looksLikeBundleID)
                    }
                }

                // Broken launch plists are reported independently of ownership.
                var brokenInfo: String?
                if loc.kind == .launch, child.pathExtension.lowercased() == "plist", !name.lowercased().hasPrefix("com.apple.") {
                    let info = UninstallerLaunch.info(for: child)
                    if !info.usesBundleProgram, let prog = info.program, prog.hasPrefix("/"),
                       !prog.hasPrefix("/System/"), !prog.hasPrefix("/usr/"), !prog.hasPrefix("/bin/"), !prog.hasPrefix("/sbin/"),
                       !UninstallerPaths.fm.fileExists(atPath: prog) {
                        let appish = prog.hasPrefix("/Applications/") || prog.hasPrefix("/Library/") || prog.hasPrefix(UninstallerPaths.home.path + "/")
                        let conf: UninstallerConfidence = prog.hasPrefix("/Volumes/") ? .low : (appish ? .high : .medium)
                        var item = UninstallerItems.make(url: child, category: .launch, confidence: conf,
                                                         reason: "Its executable is missing: \(UninstallerPaths.tilde(prog))")
                        item.isBroken = true
                        broken[item.id] = item
                        brokenInfo = item.reason
                    }
                }

                // A launch plist whose program still exists is a live service (e.g. a CLI daemon), not an orphan.
                var liveLaunch = false
                if loc.kind == .launch, brokenInfo == nil, child.pathExtension.lowercased() == "plist" {
                    let info = UninstallerLaunch.info(for: child)
                    if !info.usesBundleProgram, let prog = info.program {
                        liveLaunch = !prog.hasPrefix("/") || UninstallerPaths.fm.fileExists(atPath: prog)
                    }
                }

                if let owner {
                    let lowOwner = owner.lowercased()
                    if skipOwnerPrefixes.contains(where: { lowOwner.hasPrefix($0) }) { continue }
                    if sdkOwnerPrefixes.contains(where: { lowOwner.hasPrefix($0) }) { continue }
                    if lowOwner.contains("com.apple.") || lowOwner.hasPrefix("is.workflow.") || lowOwner.hasPrefix("group.is.workflow.")
                        || lowOwner.contains("tvappservices") || lowOwner.hasPrefix("systemgroup.") { continue }
                    var key: String
                    var reason: String
                    if let e = UninstallerKB.bestEntry(forID: owner) {
                        if e.isInstalled(ids: ctx.ids, names: ctx.names) { continue }
                        key = kbAcc(e)
                        reason = "\(e.name) is not installed (id \(owner))"
                    } else {
                        if ctx.isInstalled(owner: owner) { continue }
                        key = genericAcc(owner)
                        reason = "No installed app uses \(owner)"
                    }
                    if let b = brokenInfo { reason += " · " + b }
                    let ownerComps = lowOwner.split(separator: ".").map(String.init).filter { $0 != "group" && $0 != "groups" }
                    let vendor = ownerComps.count >= 3 ? UninstallerText.normalize(ownerComps[1]) : ""
                    let vendorInstalled = !key.hasPrefix("kb:") && vendor.count >= 3 && ctx.vendors.contains(vendor)
                    if vendorInstalled && !liveLaunch {
                        // Same vendor still has software installed: likely a shared component, never pre-select.
                        reason += " · other \(vendor) software is installed, so this may be shared"
                        let item = UninstallerItems.make(url: child, category: loc.category, confidence: .low, reason: reason)
                        placed.append(Placed(key: key, item: item, generic: false))
                        continue
                    }
                    if liveLaunch && !key.hasPrefix("kb:") {
                        // Unknown vendor + running program: show it, but never pre-select.
                        reason += " · its program still exists, so it may still be in use"
                        let item = UninstallerItems.make(url: child, category: loc.category, confidence: .low, reason: reason)
                        placed.append(Placed(key: key, item: item, generic: false))
                        continue
                    }
                    var item = UninstallerItems.make(url: child, category: loc.category, confidence: .medium, reason: reason)
                    item.isBroken = brokenInfo != nil
                    placed.append(Placed(key: key, item: item, generic: true))
                } else if loc.vendorNesting && loc.kind == .general && UninstallerPaths.isDirectory(child) {
                    let nb = UninstallerText.normalize(stripped)
                    guard nb.count >= 4, !systemNames.contains(nb), !vendorFolderNames.contains(nb),
                          !nb.hasSuffix("nodejs"), !name.lowercased().hasPrefix("com.apple") else { continue }
                    if let e = UninstallerKB.entry(forNormalizedName: nb), !e.isDeveloper {
                        if e.isInstalled(ids: ctx.ids, names: ctx.names) { continue }
                        let item = UninstallerItems.make(url: child, category: loc.category, confidence: .medium,
                                                         reason: "Folder of \(e.name), which is not installed")
                        placed.append(Placed(key: kbAcc(e), item: item, generic: false))
                        continue
                    }
                    if ctx.isInstalledName(nb) { continue }
                    let electron = electronMarkers.contains { UninstallerPaths.exists(child.appendingPathComponent($0)) }
                    let item = UninstallerItems.make(url: child, category: loc.category, confidence: .low,
                                                     reason: electron ? "Looks like data of an Electron app that is no longer installed"
                                                                      : "Folder name matches no installed app")
                    nameOnly.append((item, nb, name, electron))
                }
            }
        }

        // 2. Knowledge-base driven locations (vendor extras, developer leftovers).
        if !Task.isCancelled {
            progress("Vendor knowledge base")
            for e in UninstallerKB.entries {
                if e.isInstalled(ids: ctx.ids, names: ctx.names) { continue }
                let shared = e.sharedWithPrefixes.contains { p in
                    let lp = p.lowercased()
                    return ctx.ids.contains { $0.hasPrefix(lp) }
                }
                for kp in e.paths {
                    if kp.shared && shared { continue }
                    for url in UninstallerPaths.expand(kp.path) {
                        if UninstallerPaths.isProtected(url) { continue }
                        let reason = kp.note.isEmpty ? "Known \(e.name) location" : "\(e.name): \(kp.note)"
                        let item = UninstallerItems.make(url: url, category: e.isDeveloper ? .developer : nil,
                                                         confidence: kp.confidence, reason: reason, allowApple: e.allowApple)
                        placed.append(Placed(key: kbAcc(e), item: item, generic: false))
                        if item.category == .launch, url.pathExtension.lowercased() == "plist" {
                            let info = UninstallerLaunch.info(for: url)
                            if !info.usesBundleProgram, let prog = info.program, prog.hasPrefix("/"),
                               !UninstallerPaths.fm.fileExists(atPath: prog) {
                                var b = item
                                b.isBroken = true
                                b.reason = "Its executable is missing: \(UninstallerPaths.tilde(prog))"
                                if broken[b.id] == nil { broken[b.id] = b }
                            }
                        }
                    }
                }
            }
        }

        // 3. Name-only folders: merge into a known group, else keep as own low-confidence group.
        for n in nameOnly {
            if let (key, _) = accs.first(where: { !$0.key.hasPrefix("name:") && $0.value.nameKeys.contains(n.nb) && !$0.value.isDeveloper }) {
                var item = n.item
                item.confidence = .medium
                item.reason = "Folder name matches \(accs[key]?.name ?? "a leftover app")"
                placed.append(Placed(key: key, item: item, generic: false))
            } else {
                let key = "name:" + n.nb
                if accs[key] == nil {
                    accs[key] = Acc(id: key, name: n.raw, subtitle: n.electron ? "Electron app data" : "Unrecognised folder",
                                    symbol: n.electron ? "atom" : "questionmark.folder", isDeveloper: false, nameKeys: [n.nb])
                }
                var item = n.item
                item.confidence = n.electron ? .medium : .low
                placed.append(Placed(key: key, item: item, generic: false))
            }
        }

        if Task.isCancelled { return UninstallerHunterResult(groups: [], brokenItems: [], installedAppCount: apps.count, scannedEntries: scanned) }

        // 4. Dedupe by item id (highest confidence wins; ties prefer knowledge-base groups).
        var best: [String: Placed] = [:]
        var order: [String] = []
        for p in placed {
            if let cur = best[p.item.id] {
                if p.item.confidence > cur.item.confidence || (p.item.confidence == cur.item.confidence && p.key.hasPrefix("kb:") && !cur.key.hasPrefix("kb:")) {
                    var np = p
                    np.item.isBroken = p.item.isBroken || cur.item.isBroken
                    best[p.item.id] = np
                }
            } else { best[p.item.id] = p; order.append(p.item.id) }
        }
        var byGroup: [String: [Placed]] = [:]
        for id in order { if let p = best[id] { byGroup[p.key, default: []].append(p) } }

        // 5. Confidence tuning, vendor folders, nesting.
        var finalItems: [String: [UninstallerItem]] = [:]
        for (key, list) in byGroup {
            let evidence = list.contains { isGUIEvidence($0.item.url) }
            var items: [UninstallerItem] = list.map { p in
                var it = p.item
                if p.generic {
                    var c: UninstallerConfidence = evidence ? .high : .medium
                    let comps = (it.url.lastPathComponent.lowercased()).split(separator: ".")
                    if comps.count >= 3, ctx.vendors.contains(UninstallerText.normalize(String(comps[1]))) { c = min(c, .medium) }
                    it.confidence = c
                }
                it.groupID = key
                return it
            }
            items = collapseVendor(items, nestingRoots: nestingRoots, locationPaths: locationPaths)
            items = UninstallerItems.pruneNested(items)
            finalItems[key] = items
        }

        // 6. Sizes.
        progress("Measuring sizes…")
        let flatKeys = finalItems.keys.sorted()
        var flat: [UninstallerItem] = []
        for k in flatKeys { flat += finalItems[k] ?? [] }
        let measured = await UninstallerItems.measure(flat)
        var cursor = 0
        var groups: [UninstallerGroup] = []
        for k in flatKeys {
            let count = finalItems[k]?.count ?? 0
            let slice = Array(measured[cursor..<(cursor + count)])
            cursor += count
            guard let acc = accs[k], !slice.isEmpty else { continue }
            let sorted = slice.sorted { $0.size > $1.size }
            groups.append(UninstallerGroup(id: acc.id, name: acc.name, subtitle: acc.subtitle, symbol: acc.symbol,
                                           isDeveloper: acc.isDeveloper, items: sorted))
        }
        groups.sort { $0.totalSize > $1.totalSize }

        // Broken launch items (sizes are tiny; reuse measured sizes where the item also sits in a group).
        var sizeByID: [String: Int64] = [:]
        for it in measured { sizeByID[it.id] = it.size }
        var brokenList = broken.values.map { b -> UninstallerItem in
            var x = b
            x.size = sizeByID[b.id] ?? AppPaths.allocatedSize(of: b.url)
            return x
        }
        brokenList.sort { $0.url.path < $1.url.path }
        return UninstallerHunterResult(groups: groups, brokenItems: brokenList, installedAppCount: apps.count, scannedEntries: scanned)
    }

    private static func collapseVendor(_ items: [UninstallerItem], nestingRoots: Set<String>, locationPaths: Set<String>) -> [UninstallerItem] {
        UninstallerDeepScanner.collapseVendorFolders(items, nestingRoots: nestingRoots, locationPaths: locationPaths)
    }
}
