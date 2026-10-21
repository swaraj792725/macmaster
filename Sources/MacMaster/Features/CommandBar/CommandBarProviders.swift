import SwiftUI
import AppKit

// MARK: - Apps index

struct CBApp: Sendable {
    let name: String
    let folded: String
    let path: String
}

/// Installed apps. Scanned in the background when the bar is enabled and re-scanned (when the bar opens)
/// if the last scan is older than 10 minutes. No timers.
@MainActor
final class CommandBarAppIndex {
    static let shared = CommandBarAppIndex()
    private(set) var apps: [CBApp] = []
    private(set) var lastScan: Date?
    private var scanning = false
    private static let maxAge: TimeInterval = 600

    private init() {}

    func refreshIfStale(force: Bool = false) {
        guard !scanning else { return }
        if !force, let last = lastScan, Date().timeIntervalSince(last) < Self.maxAge { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = CommandBarAppIndex.scan()
            await MainActor.run {
                let index = CommandBarAppIndex.shared
                index.apps = found
                index.lastScan = Date()
                index.scanning = false
            }
        }
    }

    nonisolated private static func scan() -> [CBApp] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // (folder, how many folder levels below it may hold apps)
        let roots: [(String, Int)] = [
            ("/Applications", 2), (home + "/Applications", 2),
            ("/System/Applications", 2), ("/System/Library/CoreServices/Applications", 1),
        ]
        var seenPaths = Set<String>()
        var seenNames = Set<String>()
        var out: [CBApp] = []

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let full = dir + "/" + n
                if n.hasSuffix(".app") {
                    guard seenPaths.insert(full).inserted else { continue }
                    var name = fm.displayName(atPath: full)
                    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                    guard seenNames.insert(name.lowercased()).inserted else { continue }
                    out.append(CBApp(name: name, folded: CommandBarFuzzy.fold(name), path: full))
                } else if depth > 1 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue { walk(full, depth: depth - 1) }
                }
            }
        }
        for (root, depth) in roots { walk(root, depth: depth) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Files (Spotlight)

/// Optional file search through NSMetadataQuery. Starts only for 3+ characters, after a 150 ms pause.
@MainActor
final class CommandBarFiles {
    private var query: NSMetadataQuery?
    private var token: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    var onResults: (([CBResult]) -> Void)?
    private static let limit = 8

    func update(_ text: String) {
        cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard CBKind.files.isOn, t.count >= 3, t.count <= 60 else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.begin(t)
        }
    }

    func cancel() {
        debounce?.cancel(); debounce = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        query?.stop(); query = nil
    }

    private func begin(_ text: String) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemDisplayNameKey, text)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(text) }
        }
        query = q
        q.start()
    }

    private func finish(_ text: String) {
        guard let q = query else { return }
        q.disableUpdates()
        var out: [CBResult] = []
        let folded = CommandBarFuzzy.fold(text)
        let scan = min(q.resultCount, 80)
        for i in 0..<scan {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !CommandBarFiles.excluded(path) else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? (path as NSString).lastPathComponent
            let s = min(CommandBarFuzzy.score(folded, in: CommandBarFuzzy.fold(name)) ?? 200, 520)
            let dir = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            out.append(CBResult(id: "file:" + path, kind: .files, title: name, subtitle: dir,
                                symbol: "doc", colors: CBKind.files.colors, iconPath: path, score: s,
                                hint: "Open", altHint: "Reveal in Finder",
                                perform: { NSWorkspace.shared.open(URL(fileURLWithPath: path)) },
                                alt: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }))
        }
        out.sort { $0.score > $1.score }
        token.map { NotificationCenter.default.removeObserver($0) }
        token = nil
        q.stop(); query = nil
        onResults?(Array(out.prefix(Self.limit)))
    }

    private static func excluded(_ path: String) -> Bool {
        if path.contains("/Library/") || path.contains("/.") || path.contains("/node_modules/") { return true }
        if path.contains(".app/") || path.contains(".photoslibrary/") || path.contains(".xcodeproj/") { return true }
        return false
    }
}

// MARK: - Feedback helpers

/// Copy / paste helpers shared by providers.
@MainActor
enum CBPaste {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Inserts text into the app that was in front before the bar opened (copy + Command-V, clipboard restored).
    /// Needs Accessibility to send the keystroke; without it the text is only copied.
    static func insert(_ text: String) {
        guard Permissions.isGranted(.accessibility) else {
            copy(text)
            CommandBarHUD.show("Copied. Allow Accessibility in MacMaster to paste automatically.", symbol: "exclamationmark.triangle.fill")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            KeyboardSnippetExpander.expand(text: text, backspaces: 0)
        }
    }

    /// Puts a clipboard-history entry back on the clipboard and pastes it.
    static func paste(_ item: ToolsClipboardItem) {
        ToolsClipboard.shared.copyBack(item)
        guard Permissions.isGranted(.accessibility) else {
            CommandBarHUD.show("Copied. Allow Accessibility in MacMaster to paste automatically.", symbol: "exclamationmark.triangle.fill")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { KeyboardKeyPoster.tap(9, flags: .maskCommand) }
    }
}

// MARK: - Providers

@MainActor
final class CommandBarProviders {
    static let shared = CommandBarProviders()
    private lazy var qa = ToolsQuickActionsModel()
    private init() {}

    private struct Cand {
        var result: CBResult
        var title: String      // folded
        var words: String      // folded keywords
    }

    // MARK: Entry points

    /// Results for the empty query: what you use most, topped up with a few useful defaults.
    func suggestions() -> [CBResult] {
        var out: [CBResult] = []
        var seen = Set<String>()
        let actions = actionCandidates().map(\.result)
        for id in CommandBarUsage.shared.topIDs(limit: 7) {
            var found: CBResult?
            if id.hasPrefix("app:") {
                let path = String(id.dropFirst(4))
                if let app = CommandBarAppIndex.shared.apps.first(where: { $0.path == path }) { found = appResult(app, score: 0) }
            } else if id.hasPrefix("page:") {
                if let e = AppSearch.all.first(where: { "page:" + $0.id == id }) { found = pageResult(e, score: 0) }
            } else {
                found = actions.first { $0.id == id }
            }
            if let f = found, f.kind.isOn, seen.insert(f.id).inserted { out.append(f) }
        }
        let defaults = ["act:keepAwake", "act:darkMode", "act:clipboardHistory", "act:freeMemory", "act:timer"]
        for id in defaults where out.count < 6 {
            if let a = actions.first(where: { $0.id == id }), a.kind.isOn, seen.insert(a.id).inserted { out.append(a) }
        }
        return out
    }

    /// Everything that matches `raw`, best first. `scope` is a short label when a prefix like "clip" narrowed the list.
    func search(_ raw: String) -> (results: [CBResult], scope: String?) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (suggestions(), nil) }
        let lower = q.lowercased()

        if CBKind.clipboard.isOn, let rest = Self.rest(of: lower, after: ["clip", "clipboard", "paste"]) {
            return (clipboardResults(rest), "Clipboard")
        }
        if CBKind.snippets.isOn, let rest = Self.rest(of: lower, after: ["snip", "snippet", "snippets"]) {
            return (snippetResults(rest, scoped: true), "Snippets")
        }

        let fq = CommandBarFuzzy.fold(q)
        var out: [CBResult] = []

        if CBKind.calc.isOn {
            if let c = CommandBarCalc.evaluate(q) {
                out.append(CBResult(id: "calc", kind: .calc, title: "= " + c.pretty, subtitle: q,
                                    symbol: "equal.square.fill", colors: CBKind.calc.colors, score: c.trivial ? 300 : 960,
                                    hint: "Copy answer", altHint: "Copy with expression",
                                    perform: { CBPaste.copy(c.plain); CommandBarHUD.show("Copied " + c.plain) },
                                    alt: { CBPaste.copy("\(q) = \(c.plain)"); CommandBarHUD.show("Copied " + c.plain) }))
            }
            if let u = CommandBarUnits.convert(q) {
                out.append(CBResult(id: "unit", kind: .calc, title: "= " + u.title, subtitle: u.subtitle,
                                    symbol: "arrow.left.arrow.right.square.fill", colors: CBKind.calc.colors, score: 970,
                                    hint: "Copy answer", altHint: "Copy with units",
                                    perform: { CBPaste.copy(u.plain); CommandBarHUD.show("Copied " + u.plain) },
                                    alt: { CBPaste.copy(u.title); CommandBarHUD.show("Copied " + u.title) }))
            }
        }

        if CBKind.apps.isOn {
            for app in CommandBarAppIndex.shared.apps {
                if let s = CommandBarFuzzy.score(fq, in: app.folded) { out.append(appResult(app, score: s + 15)) }
            }
        }

        if CBKind.actions.isOn {
            out += scored(actionCandidates(), fq)
        }

        if CBKind.systemSettings.isOn {
            out += scored(systemPaneCandidates(), fq)
        }

        if CBKind.pages.isOn {
            for (rank, e) in AppSearch.results(for: q, limit: 14).enumerated() {
                let t = CommandBarFuzzy.fold(e.title)
                let s = CommandBarFuzzy.score(fq, in: t) ?? max(120, 200 - rank * 8)
                out.append(pageResult(e, score: s + (e.isFeature ? 40 : 0)))
            }
        }

        if CBKind.snippets.isOn {
            out += snippetResults(fq, scoped: false)
        }

        if CBKind.web.isOn { out += webResults(q) }

        let usage = CommandBarUsage.shared
        for i in out.indices where !Self.noUsage.contains(out[i].kind) {
            out[i].score += usage.boost(id: out[i].id, query: q)
        }
        // Same id from two sources (e.g. a page and its feature entry): keep the best.
        var best: [String: CBResult] = [:]
        for r in out where (best[r.id]?.score ?? Int.min) < r.score { best[r.id] = r }
        let rank: [CBKind: Int] = Dictionary(uniqueKeysWithValues: CBKind.allCases.enumerated().map { ($1, $0) })
        let sorted = best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.kind != $1.kind { return (rank[$0.kind] ?? 0) < (rank[$1.kind] ?? 0) }
            return $0.title.count < $1.title.count
        }
        return (Array(sorted.prefix(24)), nil)
    }

    private static let noUsage: Set<CBKind> = [.calc, .web, .clipboard]

    private static func rest(of lower: String, after words: [String]) -> String? {
        for w in words {
            if lower == w { return "" }
            if lower.hasPrefix(w + " ") { return String(lower.dropFirst(w.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func scored(_ cands: [Cand], _ fq: String) -> [CBResult] {
        var out: [CBResult] = []
        for c in cands {
            var s = CommandBarFuzzy.score(fq, in: c.title)
            if s == nil, fq.count >= 3, c.words.contains(fq) { s = 190 }
            if var r = Optional(c.result), let s { r.score = s; out.append(r) }
        }
        return out
    }

    // MARK: Apps

    private func appResult(_ app: CBApp, score: Int) -> CBResult {
        let url = URL(fileURLWithPath: app.path)
        return CBResult(id: "app:" + app.path, kind: .apps, title: app.name,
                        subtitle: (app.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                        symbol: "app.fill", colors: CBKind.apps.colors, iconPath: app.path, score: score,
                        hint: "Open", altHint: "Reveal in Finder",
                        perform: {
                            let cfg = NSWorkspace.OpenConfiguration()
                            cfg.activates = true
                            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
                        },
                        alt: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    // MARK: MacMaster pages and settings

    private func pageResult(_ e: SearchEntry, score: Int) -> CBResult {
        CBResult(id: "page:" + e.id, kind: .pages, title: e.title, subtitle: e.path,
                 symbol: e.opensAppSettings ? "gearshape.fill" : e.section.symbol,
                 colors: e.opensAppSettings ? Theme.Palette.gray : e.section.colors, score: score,
                 hint: e.isFeature ? "Open page" : "Open setting",
                 perform: { CommandBarProviders.open(e) })
    }

    /// Same routing as the sidebar search in the main window.
    static func open(_ e: SearchEntry) {
        if e.opensAppSettings {
            MainWindow.restoreDockPolicy()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return
        }
        if e.anchor != nil || e.tab != nil { AppSearchRouter.shared.request(anchor: e.anchor, tab: e.tab) }
        MainWindow.show(section: e.section)
    }

    static func openTools(tab: String) {
        AppSearchRouter.shared.request(anchor: nil, tab: tab)
        MainWindow.show(section: .tools)
    }

    // MARK: Quick actions and toggles

    private func actionCandidates() -> [Cand] {
        var list: [CBResult] = []
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ colors: [Color],
                 hint: String = "Run", _ perform: @escaping @MainActor () -> Void) {
            list.append(CBResult(id: id, kind: .actions, title: title, subtitle: detail, symbol: symbol, colors: colors,
                                 hint: hint, perform: perform))
        }

        // Everything on the Tools > Quick Actions page.
        for a in qa.actions {
            add("qa:" + a.id, a.title, a.detail, a.symbol, a.colors) { [weak self] in
                if a.sheet { CommandBarProviders.openTools(tab: "quickActions"); return }
                if let message = a.confirm {
                    CBConfirm.ask(a.title, message, button: a.confirmButton) { self?.execute(a) }
                } else {
                    self?.execute(a)
                }
            }
        }

        let keepAwake = ToolsKeepAwake.shared
        add("act:keepAwake", "Keep Awake", keepAwake.isActive ? "On. Return to let the Mac sleep again." : "Prevent the Mac from sleeping.",
            "cup.and.saucer.fill", Theme.Palette.orange, hint: keepAwake.isActive ? "Turn off" : "Turn on") {
            let k = ToolsKeepAwake.shared
            k.toggle()
            CommandBarHUD.show(k.isActive ? "Keep Awake is on" : "Keep Awake is off", symbol: "cup.and.saucer.fill")
        }
        add("act:darkMode", "Toggle Dark Mode", "Switch between light and dark appearance.", "circle.lefthalf.filled",
            Theme.Palette.indigo, hint: "Toggle") {
            Task.detached {
                let err = MenuBarSystem.toggleDarkMode()
                await CommandBarHUD.show(err ?? "Appearance switched", symbol: "circle.lefthalf.filled")
            }
        }
        add("act:desktopIcons", "Toggle Desktop Icons", "Hide or show the icons on the desktop (restarts Finder).", "menubar.dock.rectangle",
            Theme.Palette.teal, hint: "Toggle") {
            let shown = toolsReadBool("CreateDesktop", domain: "com.apple.finder", default: true)
            Task.detached {
                let err = MenuBarSystem.setDesktopIconsHidden(shown)
                await CommandBarHUD.show(err ?? (shown ? "Desktop icons hidden" : "Desktop icons shown"), symbol: "menubar.dock.rectangle")
            }
        }
        add("act:mute", "Toggle Mute", "Mute or unmute the sound output.", "speaker.slash.fill", Theme.Palette.pink, hint: "Toggle") {
            let muted = MenuBarSystem.isMuted() ?? false
            MenuBarSystem.setMuted(!muted)
            CommandBarHUD.show(muted ? "Sound on" : "Sound muted", symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        add("act:lock", "Lock Screen", "Lock the Mac right now.", "lock.fill", Theme.Palette.gray) { _ = MenuBarSystem.lockScreen() }
        add("act:sleepDisplays", "Sleep Displays", "Turn the displays off. The Mac keeps running.", "display", Theme.Palette.gray) {
            _ = MenuBarSystem.sleepDisplays()
        }
        add("act:screensaver", "Start Screen Saver", "Start the screen saver now.", "sparkles.tv.fill", Theme.Palette.purple) {
            _ = MenuBarSystem.startScreenSaver()
        }
        add("act:emptyTrash", "Empty Trash", "Permanently delete everything in the Trash.", "trash.fill", Theme.Palette.red, hint: "Empty") {
            CBConfirm.ask("Empty the Trash?", "Everything in the Trash is deleted for good. This cannot be undone.", button: "Empty Trash") {
                CommandBarProviders.emptyTrash()
            }
        }
        add("act:freeMemory", "Free Up Memory", "Release inactive memory without an admin password.", "memorychip", Theme.Palette.blue) {
            guard let hook = MenuBarHooks.freeMemory else { MainWindow.show(section: .optimizer); return }
            Task {
                CommandBarHUD.show("Freeing memory...", symbol: "memorychip")
                CommandBarHUD.show(await hook(), symbol: "memorychip")
            }
        }
        add("act:quickOptimize", "Quick Optimize", "Free memory and trim background load in one step.", "wand.and.stars", Theme.Palette.purple) {
            guard let hook = MenuBarHooks.quickOptimize else { MainWindow.show(section: .optimizer); return }
            Task {
                CommandBarHUD.show("Optimizing...", symbol: "wand.and.stars")
                CommandBarHUD.show(await hook(), symbol: "wand.and.stars")
            }
        }
        add("act:dropShelf", "Show Drop Shelf", "Open the file shelf near the pointer.", "tray.and.arrow.down.fill", Theme.Palette.teal) {
            DropShelf.shared.openNow()
        }
        add("act:clipboardHistory", "Clipboard History", "Browse everything you copied recently.", "doc.on.clipboard.fill", Theme.Palette.teal,
            hint: "Open") { CommandBarProviders.openTools(tab: "clipboard") }
        add("act:timer", "Timer and Stopwatch", "Open the Timer tool to start a countdown.", "timer", Theme.Palette.orange,
            hint: "Open") { CommandBarProviders.openTools(tab: "timer") }
        add("act:captureOCR", "Capture: Copy Text from Screen", "Recognize text on screen and copy it.", "text.viewfinder", Theme.Palette.purple,
            hint: "Open Capture") { MainWindow.show(section: .capture) }
        add("act:captureQR", "Capture: Scan QR Code", "Read a QR code or barcode from the screen.", "qrcode.viewfinder", Theme.Palette.purple,
            hint: "Open Capture") { MainWindow.show(section: .capture) }
        add("act:captureColor", "Capture: Pick Color", "Pick any color on screen.", "eyedropper", Theme.Palette.purple,
            hint: "Open Capture") { MainWindow.show(section: .capture) }
        add("act:screenshot", "Screenshot Tools", "Open the macOS screenshot toolbar.", "camera.viewfinder", Theme.Palette.red) {
            _ = MenuBarSystem.openScreenshotTools()
        }
        add("act:openMacMaster", "Open MacMaster", "Show the main window.", "macwindow", Theme.Palette.blue) { MainWindow.show() }

        return list.map { Cand(result: $0, title: CommandBarFuzzy.fold($0.title),
                               words: CommandBarFuzzy.fold($0.subtitle + " " + Self.extraWords($0.id))) }
    }

    private static func extraWords(_ id: String) -> String {
        switch id {
        case "act:keepAwake": "caffeinate amphetamine sleep awake"
        case "act:darkMode": "appearance theme night light"
        case "act:desktopIcons": "clutter hide show"
        case "act:emptyTrash": "bin delete garbage"
        case "act:freeMemory": "ram purge"
        case "act:timer": "countdown pomodoro alarm stopwatch"
        case "act:captureOCR": "ocr screenshot text recognition"
        case "act:captureQR": "barcode scan"
        case "act:captureColor": "eyedropper color picker"
        case "act:lock": "secure"
        case "qa:eject": "unmount usb drive disk"
        case "qa:dock": "reset relaunch"
        case "qa:finder": "reset relaunch"
        default: ""
        }
    }

    private func execute(_ a: ToolsQuickAction) {
        Task {
            CommandBarHUD.show(a.admin ? a.title + "..." : "Running...", symbol: a.symbol)
            let r = await a.run()
            CommandBarHUD.show(r.message, symbol: r.ok ? a.symbol : "exclamationmark.triangle.fill")
        }
    }

    private static func emptyTrash() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            var message = "Trash emptied"
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                message = code == -1743
                    ? "Allow MacMaster to control Finder in System Settings, Privacy & Security, Automation."
                    : "Could not empty the Trash"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { CommandBarHUD.show(message, symbol: "trash.fill") } }
        }
    }

    // MARK: System Settings panes

    private static let panes: [(title: String, words: String, url: String, symbol: String)] = [
        ("Wi-Fi", "wireless network internet", "com.apple.wifi-settings-extension", "wifi"),
        ("Network", "ethernet vpn dns proxy", "com.apple.Network-Settings.extension", "network"),
        ("Bluetooth", "devices airpods pair", "com.apple.BluetoothSettings", "wave.3.right"),
        ("Sound", "audio volume output input", "com.apple.Sound-Settings.extension", "speaker.wave.2.fill"),
        ("Displays", "monitor resolution brightness night shift", "com.apple.Displays-Settings.extension", "display"),
        ("Battery", "power energy low power mode", "com.apple.Battery-Settings.extension", "battery.100"),
        ("Notifications", "alerts banners", "com.apple.Notifications-Settings.extension", "bell.badge.fill"),
        ("Focus", "do not disturb", "com.apple.Focus-Settings.extension", "moon.fill"),
        ("Screen Time", "limits usage", "com.apple.ScreenTime-Settings.extension", "hourglass"),
        ("Lock Screen", "password login", "com.apple.Lock-Screen-Settings.extension", "lock.fill"),
        ("Privacy and Security", "permissions filevault firewall", "com.apple.settings.PrivacySecurity.extension", "hand.raised.fill"),
        ("Accessibility Privacy", "accessibility permission allow control computer", "com.apple.preference.security?Privacy_Accessibility", "accessibility"),
        ("Screen Recording Privacy", "screen recording permission capture", "com.apple.preference.security?Privacy_ScreenCapture", "record.circle"),
        ("Full Disk Access", "privacy permission files", "com.apple.preference.security?Privacy_AllFiles", "externaldrive.fill"),
        ("Desktop and Dock", "dock menu bar mission control hot corners", "com.apple.Desktop-Settings.extension", "dock.rectangle"),
        ("Control Center", "menu bar controls", "com.apple.ControlCenter-Settings.extension", "switch.2"),
        ("Wallpaper", "background picture", "com.apple.Wallpaper-Settings.extension", "photo.fill"),
        ("Appearance", "dark mode accent color", "com.apple.Appearance-Settings.extension", "circle.lefthalf.filled"),
        ("Keyboard", "shortcuts text replacement input sources", "com.apple.Keyboard-Settings.extension", "keyboard"),
        ("Mouse", "pointer scrolling tracking speed", "com.apple.Mouse-Settings.extension", "computermouse.fill"),
        ("Trackpad", "gestures tap click", "com.apple.Trackpad-Settings.extension", "rectangle.and.hand.point.up.left.fill"),
        ("Printers and Scanners", "print", "com.apple.Printers-Scanners-Settings.extension", "printer.fill"),
        ("Accessibility", "voiceover zoom captions", "com.apple.Accessibility-Settings.extension", "figure.stand"),
        ("Software Update", "macos upgrade", "com.apple.Software-Update-Settings.extension", "arrow.triangle.2.circlepath"),
        ("General", "about storage airdrop language", "com.apple.systempreferences.GeneralSettings", "gearshape.fill"),
        ("Storage", "disk space", "com.apple.Storage-Settings.extension", "internaldrive.fill"),
        ("Login Items", "startup launch at login background items", "com.apple.LoginItems-Settings.extension", "person.crop.circle.badge.checkmark"),
        ("Users and Groups", "accounts admin", "com.apple.Users-Groups-Settings.extension", "person.2.fill"),
        ("Passwords", "keychain autofill", "com.apple.Passwords-Settings.extension", "key.fill"),
        ("Date and Time", "clock timezone", "com.apple.Date-Time-Settings.extension", "clock.fill"),
        ("Time Machine", "backup", "com.apple.Time-Machine-Settings.extension", "clock.arrow.circlepath"),
        ("Sharing", "file sharing remote login screen sharing hostname", "com.apple.Sharing-Settings.extension", "square.and.arrow.up.fill"),
        ("Spotlight", "search index", "com.apple.Spotlight-Settings.extension", "magnifyingglass"),
        ("Siri", "assistant voice", "com.apple.Siri-Settings.extension", "waveform"),
        ("Internet Accounts", "icloud mail google", "com.apple.Internet-Accounts-Settings.extension", "at"),
    ]

    private func systemPaneCandidates() -> [Cand] {
        Self.panes.map { p in
            let r = CBResult(id: "pane:" + p.url, kind: .systemSettings, title: p.title + " Settings", subtitle: "System Settings",
                             symbol: p.symbol, colors: CBKind.systemSettings.colors, hint: "Open",
                             perform: { CommandBarProviders.openPane(p.url) })
            return Cand(result: r, title: CommandBarFuzzy.fold(p.title + " settings"), words: CommandBarFuzzy.fold(p.words))
        }
    }

    /// Opens a System Settings pane. Falls back to just launching System Settings when the link is not known.
    static func openPane(_ id: String) {
        if let url = URL(string: "x-apple.systempreferences:" + id), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    // MARK: Clipboard

    private func clipboardResults(_ rest: String) -> [CBResult] {
        let clip = ToolsClipboard.shared
        guard clip.isEnabled else {
            return [CBResult(id: "clip:off", kind: .clipboard, title: "Clipboard history is off",
                             subtitle: "Turn it on in Tools, Clipboard History.", symbol: "doc.on.clipboard",
                             colors: CBKind.clipboard.colors, score: 900, hint: "Open",
                             perform: { CommandBarProviders.openTools(tab: "clipboard") })]
        }
        let fq = CommandBarFuzzy.fold(rest)
        var out: [CBResult] = []
        for (i, item) in clip.items.enumerated() {
            if !fq.isEmpty, !CommandBarFuzzy.fold(item.searchText).contains(fq) { continue }
            let (title, symbol): (String, String)
            switch item.kind {
            case .text(let s):
                let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
                title = String(line.trimmingCharacters(in: .whitespaces).prefix(90))
                symbol = "doc.plaintext.fill"
            case .image: (title, symbol) = ("Image", "photo.fill")
            case .files(let urls): (title, symbol) = (urls.map(\.lastPathComponent).joined(separator: ", "), "doc.on.doc.fill")
            }
            out.append(CBResult(id: "clip:" + item.id.uuidString, kind: .clipboard, title: title.isEmpty ? "(blank)" : title,
                                subtitle: "Copied " + item.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                                symbol: symbol, colors: CBKind.clipboard.colors, score: 800 - i, hint: "Copy",
                                altHint: "Paste",
                                perform: { ToolsClipboard.shared.copyBack(item); CommandBarHUD.show("Copied to clipboard", symbol: "doc.on.clipboard.fill") },
                                alt: { CBPaste.paste(item) }))
            if out.count >= 12 { break }
        }
        return out
    }

    // MARK: Snippets

    private func snippetResults(_ rest: String, scoped: Bool) -> [CBResult] {
        let fq = CommandBarFuzzy.fold(rest)
        var out: [CBResult] = []
        for s in KeyboardStore.shared.snippets where s.enabled && !s.trigger.isEmpty {
            var score = 700
            if !fq.isEmpty {
                let trig = CommandBarFuzzy.fold(s.trigger)
                let body = CommandBarFuzzy.fold(s.text)
                if let t = CommandBarFuzzy.score(fq, in: trig) { score = t }
                else if scoped, body.contains(fq) { score = 300 }
                else { continue }
                if !scoped && score < 650 { continue }   // outside "snip", only close trigger matches show up
            }
            let preview = s.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? s.text
            out.append(CBResult(id: "snip:" + s.id.uuidString, kind: .snippets, title: s.trigger,
                                subtitle: String(preview.prefix(100)), symbol: "text.badge.plus",
                                colors: CBKind.snippets.colors, score: score, hint: "Insert", altHint: "Copy",
                                perform: { CBPaste.insert(s.text) },
                                alt: { CBPaste.copy(s.text); CommandBarHUD.show("Snippet copied", symbol: "text.badge.plus") }))
            if out.count >= 12 { break }
        }
        return out
    }

    // MARK: Web

    private func webResults(_ q: String) -> [CBResult] {
        var out: [CBResult] = []
        if let (url, explicit) = Self.url(from: q) {
            out.append(CBResult(id: "web:open", kind: .web, title: "Open " + (url.host ?? url.absoluteString),
                                subtitle: url.absoluteString, symbol: "safari.fill", colors: CBKind.web.colors,
                                score: explicit ? 900 : 480, hint: "Open",
                                perform: { NSWorkspace.shared.open(url) }))
        }
        let engine = CBWebEngine.current
        let text = q.lowercased().hasPrefix("open ") ? String(q.dropFirst(5)) : q
        if let url = engine.searchURL(text) {
            let other = engine.other
            out.append(CBResult(id: "web:search", kind: .web, title: "Search \(engine.title) for \"\(text)\"",
                                subtitle: url.host ?? "", symbol: "magnifyingglass", colors: CBKind.web.colors,
                                score: 40, hint: "Search", altHint: "Search \(other.title)",
                                perform: { NSWorkspace.shared.open(url) },
                                alt: { if let u = other.searchURL(text) { NSWorkspace.shared.open(u) } }))
        }
        return out
    }

    /// A typed web address, or nil. `explicit` is true when it had a scheme or the "open" prefix.
    static func url(from raw: String) -> (URL, Bool)? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var explicit = false
        if t.lowercased().hasPrefix("open ") {
            t = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            explicit = true
        }
        guard !t.isEmpty, t.count <= 300, !t.contains(" ") else { return nil }
        let lower = t.lowercased()
        var candidate = t
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            explicit = true
        } else if lower.contains("://") {
            return nil
        } else {
            let hostPart = t.split(separator: "/", maxSplits: 1).first.map(String.init) ?? t
            let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            let labels = host.split(separator: ".")
            let looksLikeHost = host == "localhost"
                || (labels.count >= 2 && (labels.last?.count ?? 0) >= 2 && (labels.last?.allSatisfy(\.isLetter) ?? false)
                    && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
            guard looksLikeHost else { return nil }
            candidate = "https://" + t
        }
        guard let u = URL(string: candidate), let h = u.host, !h.isEmpty,
              u.scheme == "http" || u.scheme == "https" else { return nil }
        return (u, explicit)
    }
}

// MARK: - Confirmation

@MainActor
enum CBConfirm {
    /// Asks before something destructive. Runs after the bar has closed, so the alert is the only window.
    static func ask(_ title: String, _ message: String, button: String, _ go: @escaping @MainActor () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { go() }
    }
}
