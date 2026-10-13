import Foundation

// MARK: - Vendor knowledge base
//
// Maps well-known apps to their extra / non-obvious leftover locations.
// To add an app: append an `UninstallerKBEntry` to `UninstallerKB.entries`.
//
//  - bundleIDs        exact bundle ids of the app itself (also used to decide "is it installed")
//  - idPrefixes       reverse-DNS namespaces owned by the app (dot-bounded; a trailing "." means "anything under")
//  - names            display names (used for installed check + name-only folders such as "Application Support/Firefox")
//  - vendorFolders    vendor folders under Library locations (e.g. "Google") that may be removed if left empty
//  - installedPrefixes id prefixes whose presence means the entry is still in use (shared updaters etc.)
//  - sharedWithPrefixes paths flagged `shared` are skipped if another installed app has such an id prefix
//  - pkgPrefixes      package receipt id prefixes
//  - vendorWide       idPrefixes cover a whole vendor namespace (only applied when no other app shares it)
//  - related          other entries that are cleaned up together with this one (leftover variants, updaters, dev tooling)
//  - paths            known paths; `~` and a glob in the last component are supported

struct UninstallerKBPath: Sendable {
    let path: String
    let confidence: UninstallerConfidence
    let note: String
    let shared: Bool
}

struct UninstallerKBRelation: Sendable {
    let id: String
    var cap: UninstallerConfidence? = nil
}

struct UninstallerKBEntry: Sendable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    var bundleIDs: [String] = []
    var idPrefixes: [String] = []
    var names: [String] = []
    var vendorFolders: [String] = []
    var installedPrefixes: [String] = []
    var sharedWithPrefixes: [String] = []
    var pkgPrefixes: [String] = []
    var vendorWide = false
    var isDeveloper = false
    var allowApple = false
    var related: [UninstallerKBRelation] = []
    var paths: [UninstallerKBPath] = []

    /// Is the thing this entry describes still present on the Mac?
    func isInstalled(ids: Set<String>, names installedNames: Set<String>) -> Bool {
        for b in bundleIDs where ids.contains(b.lowercased()) { return true }
        for p in installedPrefixes {
            let lp = p.lowercased()
            if ids.contains(where: { $0.hasPrefix(lp) }) { return true }
        }
        for n in names where installedNames.contains(UninstallerText.normalize(n)) { return true }
        return false
    }
}

enum UninstallerKB {
    // MARK: Lookup

    static func entry(id: String) -> UninstallerKBEntry? { entries.first { $0.id == id } }

    /// Best entry for a lowercase bundle id (longest matching namespace wins, so Canary beats Chrome).
    static func bestEntry(forID lower: String) -> UninstallerKBEntry? {
        var best: (UninstallerKBEntry, Int)?
        for e in entries {
            var score = 0
            for b in e.bundleIDs where lower == b.lowercased() { score = max(score, 10_000 + b.count) }
            for p in e.idPrefixes {
                let lp = p.lowercased()
                if UninstallerText.idMatch(lower, lp) { score = max(score, lp.count) }
            }
            if score > 0, score > (best?.1 ?? 0) { best = (e, score) }
        }
        return best?.0
    }

    /// Best entry for an app: by bundle id first, then by normalized name.
    static func bestEntry(forApp id: String, aliases: [String]) -> UninstallerKBEntry? {
        if let e = bestEntry(forID: id.lowercased()) { return e }
        let normalized = Set(aliases.map(UninstallerText.normalize))
        return entries.first { e in !e.isDeveloper && e.names.contains { normalized.contains(UninstallerText.normalize($0)) } }
    }

    static func entry(forNormalizedName n: String) -> UninstallerKBEntry? {
        entries.first { e in e.names.contains { UninstallerText.normalize($0) == n } }
    }

    // MARK: Path helpers

    private static func P(_ path: String, _ c: UninstallerConfidence = .medium, _ note: String = "",
                          shared: Bool = false) -> UninstallerKBPath {
        UninstallerKBPath(path: path, confidence: c, note: note, shared: shared)
    }

    /// Standard per-user footprint for an app with a single bundle id and a support-folder name.
    private static func std(_ id: String, support: [String] = [], extra: [UninstallerKBPath] = []) -> [UninstallerKBPath] {
        var r: [UninstallerKBPath] = [
            P("~/Library/Preferences/\(id).plist", .high),
            P("~/Library/Caches/\(id)", .high),
            P("~/Library/Saved Application State/\(id).savedState", .high),
            P("~/Library/Application Support/\(id)", .high),
            P("~/Library/HTTPStorages/\(id)", .high),
            P("~/Library/WebKit/\(id)", .high),
            P("~/Library/Containers/\(id)", .high),
        ]
        for s in support {
            r.append(P("~/Library/Application Support/\(s)", .high))
            r.append(P("~/Library/Caches/\(s)", .high))
            r.append(P("~/Library/Logs/\(s)", .high))
        }
        return r + extra
    }

    // MARK: Entries

    static let entries: [UninstallerKBEntry] = browsers + productivity + devTools + developerLeftovers + jetBrains

    // MARK: Browsers

    private static let browsers: [UninstallerKBEntry] = [
        UninstallerKBEntry(
            id: "chrome", name: "Google Chrome", symbol: "globe",
            bundleIDs: ["com.google.Chrome"], idPrefixes: ["com.google.Chrome"],
            names: ["Google Chrome"], vendorFolders: ["Google"],
            related: [
                UninstallerKBRelation(id: "chrome-for-testing"),
                UninstallerKBRelation(id: "chrome-canary"),
                UninstallerKBRelation(id: "chrome-beta"),
                UninstallerKBRelation(id: "chrome-dev"),
                UninstallerKBRelation(id: "chromium"),
                UninstallerKBRelation(id: "google-updater"),
                UninstallerKBRelation(id: "puppeteer", cap: .low),
                UninstallerKBRelation(id: "playwright", cap: .low),
                UninstallerKBRelation(id: "selenium", cap: .low),
            ],
            paths: [
                P("~/Library/Application Support/Google/Chrome", .high, "Chrome profiles, extensions and history"),
                P("~/Library/Caches/Google/Chrome", .high, "Chrome disk cache"),
                P("~/Library/Caches/com.google.Chrome", .high),
                P("~/Library/Google/Google Chrome Brand.plist", .high, "Chrome install brand marker"),
                P("~/Library/Preferences/com.google.Chrome.plist", .high),
                P("~/Library/Saved Application State/com.google.Chrome.savedState", .high),
                P("~/Library/Application Support/Google/Chrome Crashpad", .medium),
                P("/Library/Google/Chrome", .medium, "System-wide Chrome files (native messaging hosts)"),
                P("/Library/Application Support/Google/Chrome", .medium, "System-wide Chrome policies"),
                P("/Library/Google/Google Chrome Brand.plist", .medium),
                P("/Library/Managed Preferences/com.google.Chrome.plist", .low, "Managed policy"),
            ]),
        UninstallerKBEntry(
            id: "chrome-canary", name: "Google Chrome Canary", symbol: "globe",
            bundleIDs: ["com.google.Chrome.canary"], idPrefixes: ["com.google.Chrome.canary"],
            names: ["Google Chrome Canary"], vendorFolders: ["Google"],
            paths: [
                P("~/Library/Application Support/Google/Chrome Canary", .high, "Chrome Canary profile"),
                P("~/Library/Caches/Google/Chrome Canary", .high),
                P("~/Library/Caches/com.google.Chrome.canary", .high),
                P("~/Library/Preferences/com.google.Chrome.canary.plist", .high),
                P("~/Library/Saved Application State/com.google.Chrome.canary.savedState", .high),
                P("~/Library/Google/Google Chrome Canary Brand.plist", .high),
            ]),
        UninstallerKBEntry(
            id: "chrome-beta", name: "Google Chrome Beta", symbol: "globe",
            bundleIDs: ["com.google.Chrome.beta"], idPrefixes: ["com.google.Chrome.beta"],
            names: ["Google Chrome Beta"], vendorFolders: ["Google"],
            paths: [
                P("~/Library/Application Support/Google/Chrome Beta", .high, "Chrome Beta profile"),
                P("~/Library/Caches/Google/Chrome Beta", .high),
                P("~/Library/Caches/com.google.Chrome.beta", .high),
                P("~/Library/Preferences/com.google.Chrome.beta.plist", .high),
                P("~/Library/Saved Application State/com.google.Chrome.beta.savedState", .high),
            ]),
        UninstallerKBEntry(
            id: "chrome-dev", name: "Google Chrome Dev", symbol: "globe",
            bundleIDs: ["com.google.Chrome.dev"], idPrefixes: ["com.google.Chrome.dev"],
            names: ["Google Chrome Dev"], vendorFolders: ["Google"],
            paths: [
                P("~/Library/Application Support/Google/Chrome Dev", .high, "Chrome Dev profile"),
                P("~/Library/Caches/Google/Chrome Dev", .high),
                P("~/Library/Caches/com.google.Chrome.dev", .high),
                P("~/Library/Preferences/com.google.Chrome.dev.plist", .high),
                P("~/Library/Saved Application State/com.google.Chrome.dev.savedState", .high),
            ]),
        UninstallerKBEntry(
            id: "chrome-for-testing", name: "Chrome for Testing", symbol: "testtube.2",
            bundleIDs: ["com.google.chrome.for.testing"], idPrefixes: ["com.google.chrome.for.testing"],
            names: ["Google Chrome for Testing"], vendorFolders: ["Google"],
            paths: [
                P("~/Library/Application Support/Google/Chrome for Testing", .high, "Chrome for Testing profile"),
                P("~/Library/Caches/Google/Chrome for Testing", .high),
                P("~/Library/Caches/com.google.chrome.for.testing", .high),
                P("~/Library/Preferences/com.google.chrome.for.testing.plist", .high),
                P("~/Library/Saved Application State/com.google.chrome.for.testing.savedState", .high),
            ]),
        UninstallerKBEntry(
            id: "chromium", name: "Chromium", symbol: "globe",
            bundleIDs: ["org.chromium.Chromium"], idPrefixes: ["org.chromium.Chromium"],
            names: ["Chromium"],
            paths: [
                P("~/Library/Application Support/Chromium", .high, "Chromium profile"),
                P("~/Library/Caches/Chromium", .high),
                P("~/Library/Caches/org.chromium.Chromium", .high),
                P("~/Library/Preferences/org.chromium.Chromium.plist", .high),
                P("~/Library/Saved Application State/org.chromium.Chromium.savedState", .high),
            ]),
        UninstallerKBEntry(
            id: "google-updater", name: "Google Software Update", symbol: "arrow.triangle.2.circlepath",
            idPrefixes: ["com.google.GoogleUpdater", "com.google.keystone", "com.google.Keystone", "com.google.GoogleSoftwareUpdate",
                         "com.google.SoftwareUpdate"],
            vendorFolders: ["Google"],
            installedPrefixes: ["com.google."], sharedWithPrefixes: ["com.google."],
            pkgPrefixes: ["com.google.pkg.Keystone", "com.google.Keystone"],
            paths: [
                P("~/Library/Google/GoogleSoftwareUpdate", .medium, "Google Keystone updater (shared by all Google apps)", shared: true),
                P("~/Library/Application Support/Google/GoogleUpdater", .medium, "Google Updater", shared: true),
                P("~/Library/Caches/com.google.SoftwareUpdate", .medium, shared: true),
                P("~/Library/Caches/com.google.GoogleUpdater", .medium, shared: true),
                P("~/Library/Preferences/com.google.Keystone.Agent.plist", .medium, shared: true),
                P("~/Library/Preferences/com.google.keystone.plist", .medium, shared: true),
                P("~/Library/LaunchAgents/com.google.keystone.agent.plist", .medium, "Keystone background updater", shared: true),
                P("~/Library/LaunchAgents/com.google.keystone.xpcservice.plist", .medium, shared: true),
                P("~/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist", .medium, shared: true),
                P("/Library/LaunchAgents/com.google.keystone.agent.plist", .medium, shared: true),
                P("/Library/LaunchAgents/com.google.keystone.xpcservice.plist", .medium, shared: true),
                P("/Library/LaunchDaemons/com.google.keystone.daemon.plist", .medium, shared: true),
                P("/Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist", .medium, shared: true),
                P("/Library/Google/GoogleSoftwareUpdate", .medium, shared: true),
                P("/Library/Application Support/Google/GoogleUpdater", .medium, shared: true),
            ]),
        UninstallerKBEntry(
            id: "edge", name: "Microsoft Edge", symbol: "globe",
            bundleIDs: ["com.microsoft.edgemac"], idPrefixes: ["com.microsoft.edgemac", "com.microsoft.EdgeUpdater"],
            names: ["Microsoft Edge"], vendorFolders: ["Microsoft"],
            paths: [
                P("~/Library/Application Support/Microsoft Edge", .high, "Edge profile"),
                P("~/Library/Application Support/Microsoft/EdgeUpdater", .medium),
                P("~/Library/Caches/Microsoft Edge", .high),
                P("~/Library/Caches/com.microsoft.edgemac", .high),
                P("~/Library/Preferences/com.microsoft.edgemac.plist", .high),
                P("~/Library/Saved Application State/com.microsoft.edgemac.savedState", .high),
                P("~/Library/Application Support/Microsoft Edge Beta", .medium),
                P("~/Library/Application Support/Microsoft Edge Dev", .medium),
                P("~/Library/Application Support/Microsoft Edge Canary", .medium),
            ]),
        UninstallerKBEntry(
            id: "brave", name: "Brave", symbol: "globe",
            bundleIDs: ["com.brave.Browser"], idPrefixes: ["com.brave.Browser"],
            names: ["Brave Browser"], vendorFolders: ["BraveSoftware"],
            paths: [
                P("~/Library/Application Support/BraveSoftware/Brave-Browser", .high, "Brave profile"),
                P("~/Library/Caches/BraveSoftware/Brave-Browser", .high),
                P("~/Library/Caches/com.brave.Browser", .high),
                P("~/Library/Preferences/com.brave.Browser.plist", .high),
                P("~/Library/Saved Application State/com.brave.Browser.savedState", .high),
                P("~/Library/Application Support/BraveSoftware/Brave-Browser-Beta", .medium),
                P("~/Library/Application Support/BraveSoftware/Brave-Browser-Nightly", .medium),
            ]),
        UninstallerKBEntry(
            id: "firefox", name: "Firefox", symbol: "flame.fill",
            bundleIDs: ["org.mozilla.firefox"], idPrefixes: ["org.mozilla.firefox"],
            names: ["Firefox"], vendorFolders: ["Mozilla"], sharedWithPrefixes: ["org.mozilla."],
            paths: [
                P("~/Library/Application Support/Firefox", .high, "Firefox profiles"),
                P("~/Library/Caches/Firefox", .high),
                P("~/Library/Caches/Mozilla", .medium, shared: true),
                P("~/Library/Application Support/Mozilla", .low, "Mozilla shared data (native messaging hosts)", shared: true),
                P("~/Library/Preferences/org.mozilla.firefox.plist", .high),
                P("~/Library/Saved Application State/org.mozilla.firefox.savedState", .high),
                P("/Library/Application Support/Mozilla", .low, shared: true),
            ]),
        UninstallerKBEntry(
            id: "opera", name: "Opera", symbol: "globe",
            bundleIDs: ["com.operasoftware.Opera"], idPrefixes: ["com.operasoftware.Opera"],
            names: ["Opera"], vendorFolders: ["Opera Software"],
            paths: [
                P("~/Library/Application Support/com.operasoftware.Opera", .high, "Opera profile"),
                P("~/Library/Caches/com.operasoftware.Opera", .high),
                P("~/Library/Preferences/com.operasoftware.Opera.plist", .high),
                P("~/Library/Saved Application State/com.operasoftware.Opera.savedState", .high),
                P("~/Library/Application Support/Opera Software", .medium),
            ]),
        UninstallerKBEntry(
            id: "arc", name: "Arc", symbol: "globe",
            bundleIDs: ["company.thebrowser.Browser"], idPrefixes: ["company.thebrowser.Browser"],
            names: ["Arc"],
            paths: [
                P("~/Library/Application Support/Arc", .high, "Arc profile and spaces"),
                P("~/Library/Caches/company.thebrowser.Browser", .high),
                P("~/Library/Caches/Arc", .high),
                P("~/Library/Preferences/company.thebrowser.Browser.plist", .high),
                P("~/Library/Saved Application State/company.thebrowser.Browser.savedState", .high),
                P("~/Library/HTTPStorages/company.thebrowser.Browser", .high),
            ]),
    ]

    // MARK: Productivity / communication

    private static let productivity: [UninstallerKBEntry] = [
        UninstallerKBEntry(
            id: "ms-office", name: "Microsoft Office", symbol: "doc.richtext.fill",
            bundleIDs: ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
                        "com.microsoft.Outlook", "com.microsoft.onenote.mac"],
            idPrefixes: ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
                         "com.microsoft.onenote", "com.microsoft.office", "com.microsoft.OfficeReminders",
                         "com.microsoft.errorreporting", "com.microsoft.autoupdate", "com.microsoft.openxml"],
            names: ["Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook", "Microsoft OneNote"],
            vendorFolders: ["Microsoft"],
            sharedWithPrefixes: ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
                                 "com.microsoft.onenote", "com.microsoft.teams", "com.microsoft.OneDrive"],
            pkgPrefixes: ["com.microsoft.office", "com.microsoft.pkg.licensing", "com.microsoft.package"],
            paths: [
                P("~/Library/Group Containers/UBF8T346G9.Office", .medium, "Shared Office data", shared: true),
                P("~/Library/Group Containers/UBF8T346G9.ms", .medium, "Shared Microsoft data", shared: true),
                P("~/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost", .medium, shared: true),
                P("~/Library/Application Support/Microsoft/Office", .medium, shared: true),
                P("~/Library/Preferences/com.microsoft.office.plist", .medium, shared: true),
                P("/Library/Application Support/Microsoft/MAU2.0", .low, "Microsoft AutoUpdate (shared by all Microsoft apps)", shared: true),
                P("/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist", .medium, shared: true),
                P("/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper", .medium, shared: true),
                P("/Library/Preferences/com.microsoft.office.licensingV2.plist", .medium, shared: true),
                P("/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist", .low, shared: true),
                P("/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper", .low, shared: true),
            ]),
        UninstallerKBEntry(
            id: "ms-teams", name: "Microsoft Teams", symbol: "person.2.fill",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            idPrefixes: ["com.microsoft.teams"], names: ["Microsoft Teams", "Microsoft Teams (work or school)"],
            vendorFolders: ["Microsoft"],
            paths: [
                P("~/Library/Application Support/Microsoft/Teams", .high),
                P("~/Library/Application Support/Teams", .high),
                P("~/Library/Application Support/com.microsoft.teams2", .high),
                P("~/Library/Group Containers/UBF8T346G9.com.microsoft.teams", .high),
                P("~/Library/Logs/Microsoft Teams", .medium),
                P("~/Library/Containers/com.microsoft.teams2", .high),
                P("~/Library/Caches/com.microsoft.teams2", .high),
                P("/Library/Application Support/Microsoft/TeamsUpdaterDaemon", .medium),
                P("/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist", .medium),
                P("/Library/PrivilegedHelperTools/com.microsoft.teams.TeamsUpdaterDaemon", .medium),
            ] + std("com.microsoft.teams2")),
        UninstallerKBEntry(
            id: "zoom", name: "Zoom", symbol: "video.fill",
            bundleIDs: ["us.zoom.xos"], idPrefixes: ["us.zoom."],
            names: ["zoom.us", "Zoom"], pkgPrefixes: ["us.zoom."],
            paths: [
                P("~/.zoomus", .high),
                P("~/Library/Application Support/zoom.us", .high),
                P("~/Library/Caches/us.zoom.xos", .high),
                P("~/Library/Logs/zoom.us", .high),
                P("~/Library/Logs/zoominstall.log", .medium),
                P("~/Library/Preferences/us.zoom.xos.plist", .high),
                P("~/Library/Preferences/ZoomChat.plist", .high),
                P("~/Library/Preferences/us.zoom.config.plist", .high),
                P("~/Library/Saved Application State/us.zoom.xos.savedState", .high),
                P("/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin", .high, "Zoom browser plug-in"),
                P("/Library/Logs/zoominstall.log", .medium),
                P("/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon", .high),
                P("/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", .high),
            ]),
        UninstallerKBEntry(
            id: "slack", name: "Slack", symbol: "bubble.left.and.bubble.right.fill",
            bundleIDs: ["com.tinyspeck.slackmacgap"], idPrefixes: ["com.tinyspeck.slackmacgap"],
            names: ["Slack"],
            paths: std("com.tinyspeck.slackmacgap", support: ["Slack"], extra: [
                P("~/Library/Caches/com.tinyspeck.slackmacgap.ShipIt", .high),
                P("~/Library/Cookies/com.tinyspeck.slackmacgap.binarycookies", .high),
            ])),
        UninstallerKBEntry(
            id: "discord", name: "Discord", symbol: "bubble.left.fill",
            bundleIDs: ["com.hnc.Discord"], idPrefixes: ["com.hnc.Discord"],
            names: ["Discord"],
            paths: std("com.hnc.Discord", support: ["discord", "Discord"], extra: [
                P("~/Library/Caches/com.hnc.Discord.ShipIt", .high),
            ])),
        UninstallerKBEntry(
            id: "spotify", name: "Spotify", symbol: "music.note",
            bundleIDs: ["com.spotify.client"], idPrefixes: ["com.spotify."],
            names: ["Spotify"],
            paths: std("com.spotify.client", support: ["Spotify"], extra: [
                P("~/Library/Cookies/com.spotify.client.binarycookies", .high),
                P("~/Library/LaunchAgents/com.spotify.webhelper.plist", .high),
            ])),
        UninstallerKBEntry(
            id: "adobe", name: "Adobe", symbol: "a.circle.fill",
            idPrefixes: ["com.adobe."], names: ["Adobe Creative Cloud"], vendorFolders: ["Adobe"],
            installedPrefixes: ["com.adobe."], sharedWithPrefixes: ["com.adobe."],
            pkgPrefixes: ["com.adobe."], vendorWide: true,
            paths: [
                P("~/Library/Application Support/Adobe", .low, "Adobe shared data (fonts, licensing, presets)", shared: true),
                P("~/Library/Caches/Adobe", .low, shared: true),
                P("~/Library/Logs/Adobe", .low, shared: true),
                P("~/Library/Preferences/Adobe", .low, shared: true),
                P("/Library/Application Support/Adobe", .low, "Adobe shared data", shared: true),
                P("/Library/Application Support/regid.1986-12.com.adobe", .low, shared: true),
                P("/Library/Application Support/regid.1991-06.com.adobe", .low, shared: true),
                P("/Library/LaunchAgents/com.adobe.*", .low, shared: true),
                P("/Library/LaunchDaemons/com.adobe.*", .low, shared: true),
                P("/Library/PrivilegedHelperTools/com.adobe.*", .low, shared: true),
            ]),
        UninstallerKBEntry(
            id: "dropbox", name: "Dropbox", symbol: "shippingbox.fill",
            bundleIDs: ["com.getdropbox.dropbox"], idPrefixes: ["com.getdropbox.", "com.dropbox."],
            names: ["Dropbox"], sharedWithPrefixes: [],
            paths: [
                P("~/.dropbox", .high),
                P("~/Library/Dropbox", .high),
                P("~/Library/Application Support/Dropbox", .high),
                P("~/Library/DropboxMacUpdate", .high),
                P("~/Library/Caches/com.getdropbox.dropbox", .high),
                P("~/Library/Preferences/com.getdropbox.dropbox.plist", .high),
                P("~/Library/LaunchAgents/com.dropbox.DropboxMacUpdate.agent.plist", .high),
                P("/Library/DropboxHelperTools", .medium),
            ]),
        UninstallerKBEntry(
            id: "notion", name: "Notion", symbol: "note.text",
            bundleIDs: ["notion.id"], idPrefixes: ["notion.id"], names: ["Notion"],
            paths: [
                P("~/Library/Application Support/Notion", .high),
                P("~/Library/Caches/notion.id", .high),
                P("~/Library/Caches/notion.id.ShipIt", .high),
                P("~/Library/Preferences/notion.id.plist", .high),
                P("~/Library/Saved Application State/notion.id.savedState", .high),
                P("~/Library/Logs/Notion", .medium),
            ]),
        UninstallerKBEntry(
            id: "figma", name: "Figma", symbol: "pencil.and.ruler.fill",
            bundleIDs: ["com.figma.Desktop"], idPrefixes: ["com.figma."], names: ["Figma"],
            paths: std("com.figma.Desktop", support: ["Figma"], extra: [
                P("~/Library/Application Support/Figma Agent", .medium),
            ])),
        UninstallerKBEntry(
            id: "whatsapp", name: "WhatsApp", symbol: "message.fill",
            bundleIDs: ["net.whatsapp.WhatsApp"], idPrefixes: ["net.whatsapp."], names: ["WhatsApp"],
            paths: std("net.whatsapp.WhatsApp", support: ["WhatsApp"], extra: [
                P("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", .high),
                P("~/Library/Group Containers/*.net.whatsapp.WhatsApp.shared", .high),
            ])),
        UninstallerKBEntry(
            id: "telegram", name: "Telegram", symbol: "paperplane.fill",
            bundleIDs: ["ru.keepcoder.Telegram"], idPrefixes: ["ru.keepcoder.Telegram"], names: ["Telegram"],
            paths: std("ru.keepcoder.Telegram", extra: [
                P("~/Library/Group Containers/*.ru.keepcoder.Telegram", .high),
            ])),
        UninstallerKBEntry(
            id: "telegram-desktop", name: "Telegram Desktop", symbol: "paperplane.fill",
            bundleIDs: ["com.tdesktop.Telegram"], idPrefixes: ["com.tdesktop.Telegram"], names: ["Telegram Desktop"],
            paths: std("com.tdesktop.Telegram", support: ["Telegram Desktop"])),
        UninstallerKBEntry(
            id: "postman", name: "Postman", symbol: "paperplane.circle.fill",
            bundleIDs: ["com.postmanlabs.mac"], idPrefixes: ["com.postmanlabs."], names: ["Postman"],
            paths: std("com.postmanlabs.mac", support: ["Postman"], extra: [
                P("~/Library/Caches/com.postmanlabs.mac.ShipIt", .high),
            ])),
        UninstallerKBEntry(
            id: "steam", name: "Steam", symbol: "gamecontroller.fill",
            bundleIDs: ["com.valvesoftware.steam"], idPrefixes: ["com.valvesoftware.steam"], names: ["Steam"],
            paths: [
                P("~/Library/Application Support/Steam", .low, "Includes installed games and save data"),
                P("~/Library/Caches/com.valvesoftware.steam", .high),
                P("~/Library/Preferences/com.valvesoftware.steam.plist", .high),
                P("~/Library/Preferences/com.valvesoftware.steam.helper.plist", .high),
                P("~/Library/Saved Application State/com.valvesoftware.steam.savedState", .high),
                P("~/Library/Logs/Steam", .medium),
            ]),
    ]

    // MARK: Developer apps

    private static let devTools: [UninstallerKBEntry] = [
        UninstallerKBEntry(
            id: "docker", name: "Docker Desktop", symbol: "shippingbox.fill",
            bundleIDs: ["com.docker.docker"], idPrefixes: ["com.docker."], names: ["Docker", "Docker Desktop"],
            paths: [
                P("~/.docker", .medium, "Docker CLI config and contexts"),
                P("~/Library/Containers/com.docker.docker", .high, "Docker VM disk image and data"),
                P("~/Library/Group Containers/group.com.docker", .high),
                P("~/Library/Application Support/Docker Desktop", .high),
                P("~/Library/Preferences/com.docker.docker.plist", .high),
                P("~/Library/Caches/com.docker.docker", .high),
                P("~/Library/Logs/Docker Desktop", .high),
                P("~/Library/Saved Application State/com.docker.docker.savedState", .high),
                P("/Library/PrivilegedHelperTools/com.docker.vmnetd", .high),
                P("/Library/PrivilegedHelperTools/com.docker.socket", .high),
                P("/Library/LaunchDaemons/com.docker.vmnetd.plist", .high),
                P("/Library/LaunchDaemons/com.docker.socket.plist", .high),
                P("/usr/local/bin/docker", .low, "Docker CLI link"),
                P("/usr/local/bin/docker-compose", .low),
                P("/usr/local/bin/hub-tool", .low),
            ]),
        UninstallerKBEntry(
            id: "vscode", name: "Visual Studio Code", symbol: "chevron.left.forwardslash.chevron.right",
            bundleIDs: ["com.microsoft.VSCode"], idPrefixes: ["com.microsoft.VSCode"],
            names: ["Visual Studio Code", "Code"], vendorFolders: ["Microsoft"],
            paths: [
                P("~/.vscode", .medium, "VS Code extensions and settings"),
                P("~/Library/Application Support/Code", .high),
                P("~/Library/Caches/com.microsoft.VSCode", .high),
                P("~/Library/Caches/com.microsoft.VSCode.ShipIt", .high),
                P("~/Library/Preferences/com.microsoft.VSCode.plist", .high),
                P("~/Library/Saved Application State/com.microsoft.VSCode.savedState", .high),
                P("~/Library/Logs/Code", .medium),
                P("/usr/local/bin/code", .low, "VS Code command-line link"),
            ]),
        UninstallerKBEntry(
            id: "cursor", name: "Cursor", symbol: "cursorarrow.rays",
            bundleIDs: ["com.todesktop.230313mzl4w4u92"], idPrefixes: ["com.todesktop.230313mzl4w4u92"],
            names: ["Cursor"],
            paths: [
                P("~/.cursor", .medium, "Cursor extensions and settings"),
                P("~/Library/Application Support/Cursor", .high),
                P("~/Library/Caches/com.todesktop.230313mzl4w4u92", .high),
                P("~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", .high),
                P("~/Library/Preferences/com.todesktop.230313mzl4w4u92.plist", .high),
                P("~/Library/Saved Application State/com.todesktop.230313mzl4w4u92.savedState", .high),
                P("~/Library/Logs/Cursor", .medium),
                P("/usr/local/bin/cursor", .low),
            ]),
    ]

    // MARK: Developer leftovers (no owning app; shown as "Developer leftovers")

    private static let developerLeftovers: [UninstallerKBEntry] = [
        UninstallerKBEntry(
            id: "puppeteer", name: "Puppeteer browsers", symbol: "theatermasks.fill",
            isDeveloper: true,
            paths: [P("~/.cache/puppeteer", .medium, "Chrome / Chrome for Testing downloaded by Puppeteer"),
                    P("~/.cache/puppeteer-core", .medium)]),
        UninstallerKBEntry(
            id: "playwright", name: "Playwright browsers", symbol: "theatermasks.fill",
            isDeveloper: true,
            paths: [P("~/Library/Caches/ms-playwright", .medium, "Chromium / Firefox / WebKit builds downloaded by Playwright"),
                    P("~/Library/Caches/ms-playwright-go", .medium)]),
        UninstallerKBEntry(
            id: "selenium", name: "Selenium drivers", symbol: "testtube.2",
            isDeveloper: true,
            paths: [P("~/.cache/selenium", .medium, "Browsers and drivers downloaded by Selenium Manager"),
                    P("~/.wdm", .medium, "webdriver-manager driver cache")]),
        UninstallerKBEntry(
            id: "cypress", name: "Cypress binary", symbol: "testtube.2",
            isDeveloper: true,
            paths: [P("~/Library/Caches/Cypress", .medium, "Cypress test runner binaries")]),
        UninstallerKBEntry(
            id: "xcode", name: "Xcode leftovers", symbol: "hammer.fill",
            bundleIDs: ["com.apple.dt.Xcode", "com.apple.dt.Xcode-beta"], names: ["Xcode"],
            isDeveloper: true, allowApple: true,
            paths: [
                P("~/Library/Developer/Xcode/DerivedData", .medium, "Xcode build products"),
                P("~/Library/Developer/Xcode/iOS DeviceSupport", .medium),
                P("~/Library/Developer/Xcode/watchOS DeviceSupport", .medium),
                P("~/Library/Developer/Xcode/tvOS DeviceSupport", .medium),
                P("~/Library/Developer/Xcode/DocumentationCache", .medium),
                P("~/Library/Developer/Xcode/Products", .medium),
                P("~/Library/Developer/Xcode/Archives", .low, "May contain app archives and dSYMs you still need"),
                P("~/Library/Developer/Xcode/UserData", .low, "Your Xcode snippets, themes and key bindings"),
                P("~/Library/Developer/CoreSimulator", .medium, "iOS simulators"),
                P("~/Library/Caches/com.apple.dt.Xcode", .medium),
                P("~/Library/Preferences/com.apple.dt.Xcode.plist", .medium),
                P("/Library/Developer/CoreSimulator", .low, "Simulator runtimes (system-wide)"),
            ]),
        UninstallerKBEntry(
            id: "android-studio", name: "Android Studio leftovers", symbol: "hammer.fill",
            bundleIDs: ["com.google.android.studio", "com.google.android.studio-EAP"], names: ["Android Studio"],
            vendorFolders: ["Google"], isDeveloper: true,
            paths: [
                P("~/Library/Application Support/Google/AndroidStudio*", .medium, "Android Studio settings"),
                P("~/Library/Caches/Google/AndroidStudio*", .medium),
                P("~/Library/Logs/Google/AndroidStudio*", .medium),
                P("~/Library/Preferences/com.google.android.studio.plist", .medium),
                P("~/Library/Preferences/AndroidStudio*", .medium),
                P("~/.android", .low, "Android SDK tooling state and AVDs"),
                P("~/Library/Android/sdk", .low, "Android SDK (may be used by other tools)"),
            ]),
        UninstallerKBEntry(
            id: "electron-tooling", name: "Electron tooling", symbol: "atom",
            isDeveloper: true,
            paths: [P("~/Library/Caches/electron", .medium, "Electron binaries downloaded by npm"),
                    P("~/Library/Caches/electron-builder", .medium),
                    P("~/.electron-gyp", .low),
                    P("~/Library/Application Support/Electron", .low, "Data of apps run with the stock Electron binary")]),
    ]

    // MARK: JetBrains (generated)

    private static let jetBrains: [UninstallerKBEntry] = {
        // (display name, bundle ids, folder glob stem, bracket for versions)
        let products: [(String, [String], String)] = [
            ("IntelliJ IDEA", ["com.jetbrains.intellij"], "IntelliJIdea"),
            ("IntelliJ IDEA CE", ["com.jetbrains.intellij.ce"], "IdeaIC"),
            ("PyCharm", ["com.jetbrains.pycharm"], "PyCharm"),
            ("PyCharm CE", ["com.jetbrains.pycharm.ce"], "PyCharmCE"),
            ("WebStorm", ["com.jetbrains.WebStorm"], "WebStorm"),
            ("PhpStorm", ["com.jetbrains.PhpStorm"], "PhpStorm"),
            ("CLion", ["com.jetbrains.CLion"], "CLion"),
            ("GoLand", ["com.jetbrains.goland"], "GoLand"),
            ("DataGrip", ["com.jetbrains.datagrip"], "DataGrip"),
            ("Rider", ["com.jetbrains.rider"], "Rider"),
            ("RubyMine", ["com.jetbrains.rubymine"], "RubyMine"),
            ("AppCode", ["com.jetbrains.AppCode"], "AppCode"),
            ("DataSpell", ["com.jetbrains.dataspell"], "DataSpell"),
            ("RustRover", ["com.jetbrains.rustrover"], "RustRover"),
        ]
        return products.map { (name, ids, stem) in
            let g = "\(stem)[0-9]*"
            return UninstallerKBEntry(
                id: "jetbrains-" + stem.lowercased(), name: name, symbol: "hammer.circle.fill",
                bundleIDs: ids, idPrefixes: ids, names: [name], vendorFolders: ["JetBrains"],
                paths: [
                    P("~/Library/Application Support/JetBrains/\(g)", .high, "\(name) settings, plug-ins and indexes"),
                    P("~/Library/Caches/JetBrains/\(g)", .high),
                    P("~/Library/Logs/JetBrains/\(g)", .high),
                    P("~/Library/Preferences/\(g)", .medium, "Legacy \(name) preferences"),
                    P("~/Library/Application Support/\(g)", .medium, "Legacy \(name) settings"),
                ])
        }
    }()
}
