import SwiftUI
import AppKit
import Observation
import ImageIO
import os

// MARK: - Item

struct ToolsClipboardItem: Identifiable {
    /// Kept as-is: the Drop Shelf stages clipboard items through this enum.
    enum Kind { case text(String), image(Data), files([URL]) }
    var id = UUID()
    var kind: Kind
    var date = Date()
    var pinned = false
    /// Original rich text (RTF) that came with a text copy; nil for plain text.
    var rtf: Data?
    var sourceBundleID: String?
    var sourceName: String?
    /// Set when the text is a single web link.
    private(set) var linkURL: URL?
    /// Set when the text is a color such as `#FF8800` or `rgb(255, 136, 0)`: red, green, blue, alpha in 0...1.
    private(set) var colorRGBA: [Double]?

    init(id: UUID = UUID(), kind: Kind, date: Date = Date(), pinned: Bool = false, rtf: Data? = nil,
         sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.id = id; self.kind = kind; self.date = date; self.pinned = pinned; self.rtf = rtf
        self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        if case .text(let s) = kind {
            linkURL = Self.parseLink(s)
            colorRGBA = linkURL == nil ? Self.parseColor(s) : nil
        }
    }

    var searchText: String {
        let base: String
        switch kind {
        case .text(let s): base = s
        case .image: base = "image"
        case .files(let u): base = u.map(\.lastPathComponent).joined(separator: " ")
        }
        return sourceName.map { base + " " + $0 } ?? base
    }

    var isText: Bool { if case .text = kind { true } else { false } }
    var plainText: String? { if case .text(let s) = kind { s } else { nil } }

    /// Approximate memory cost, used for the image budget and the size label.
    var byteCount: Int {
        switch kind {
        case .image(let d): d.count
        case .text(let s): s.utf8.count
        case .files: 0
        }
    }

    // MARK: Detection

    static func parseLink(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count < 4_000, t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("ftp://"),
              t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let u = URL(string: t), let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    static func parseColor(_ s: String) -> [Double]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count <= 40 else { return nil }
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            var full = hex
            if hex.count <= 4 { full = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(full, radix: 16) else { return nil }
            if full.count == 6 {
                return [Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1]
            }
            return [Double((v >> 24) & 255) / 255, Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255]
        }
        if t.hasPrefix("rgb"), let open = t.firstIndex(of: "("), t.hasSuffix(")") {
            let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
            guard parts.count == 3 || parts.count == 4, parts.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
            let a = parts.count == 4 ? max(0, min(1, parts[3])) : 1
            return [parts[0] / 255, parts[1] / 255, parts[2] / 255, a]
        }
        return nil
    }

    /// `#RRGGBB` label for a color item.
    var colorLabel: String? {
        guard let c = colorRGBA, c.count == 4 else { return nil }
        let h = String(format: "#%02X%02X%02X", Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
        return c[3] < 0.999 ? h + String(format: "%02X", Int((c[3] * 255).rounded())) : h
    }
}

/// Filter chips on the history list.
enum ToolsClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, images, links, files, pinned
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }

    func matches(_ item: ToolsClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.isText && item.linkURL == nil
        case .images: if case .image = item.kind { true } else { false }
        case .links: item.linkURL != nil
        case .files: if case .files = item.kind { true } else { false }
        case .pinned: item.pinned
        }
    }
}

/// Saved pins. Old files only have `text` / `files`; every newer field is optional so they still load.
private struct ToolsClipboardPin: Codable {
    var text: String?
    var files: [String]?
    var id: UUID?
    var image: String?
    var rtf: Data?
    var date: Date?
    var source: String?
    var sourceName: String?
}

// MARK: - Engine

/// Records what you copy. Off by default; history lives in memory only (pins are saved).
@Observable
@MainActor
final class ToolsClipboard {
    static let shared = ToolsClipboard()
    private static let log = Logger(subsystem: "com.macmaster.app", category: "clipboard")
    private static let enabledKey = "mm.tools.clipboard.enabled"
    static let menuBarKey = "mm.tools.clipboard.menuBar"
    static let plainHotKeyKey = "mm.tools.clipboard.plainHotkey"
    static let quickHotKeyKey = "mm.tools.clipboard.quickHotkey"
    private static let maxImageBytes = 10_000_000
    private static let maxTIFFBytes = 40_000_000
    private static let maxRTFBytes = 2_000_000
    private static let imageBudget = 150_000_000
    /// Marked by password managers and other apps that do not want their copies recorded.
    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "com.typeit4me.clipping",
    ]
    private static let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "de.petermaurer.TransientPasteboardType",
    ]
    static let defaultExcludedApps = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.Passwords",
        "com.apple.keychainaccess", "com.lastpass.lastpassmacdesktop", "com.dashlane.dashlanephonefinal",
        "in.sinew.enpass-desktop", "com.nordsec.nordpass", "ch.protonmail.pass", "me.proton.pass.electron",
    ]
    static let historySizes = [25, 50, 100, 200]
    static let expiryOptions: [(days: Int, label: String)] = [(0, "Never"), (1, "After 1 day"), (7, "After 7 days"), (30, "After 30 days")]
    static let autoClearOptions: [(seconds: Int, label: String)] = [(0, "Off"), (15, "After 15 seconds"), (30, "After 30 seconds"), (60, "After 1 minute"), (120, "After 2 minutes")]

    private(set) var items: [ToolsClipboardItem] = []
    private(set) var copiedID: UUID?
    /// Links cleaned since the feature was first turned on (saved).
    private(set) var cleanedCount: Int

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            refreshPolling()
            ToolsClipboardMenuBar.shared.update()
        }
    }

    /// Explicit user choice for the menu bar icon; nil = follow `isEnabled`.
    private(set) var menuBarExplicit: Bool?

    /// Separate menu bar icon with the history popover. Defaults to on while recording is on.
    var showInMenuBar: Bool {
        get { menuBarExplicit ?? isEnabled }
        set {
            menuBarExplicit = newValue
            UserDefaults.standard.set(newValue, forKey: Self.menuBarKey)
            ToolsClipboardMenuBar.shared.update()
        }
    }

    // Privacy
    var skipSensitive: Bool { didSet { save(skipSensitive, "skipSensitive") } }
    private(set) var excludedApps: [String]
    var autoClearSeconds: Int { didSet { save(autoClearSeconds, "autoClearSeconds"); refreshPolling() } }
    var clearOnLock: Bool { didSet { save(clearOnLock, "clearOnLock") } }
    // Cleanup
    var expireDays: Int { didSet { save(expireDays, "expireDays"); expireOld() } }
    var maxItems: Int { didSet { save(maxItems, "maxItems"); trim() } }
    // Paste
    var plainAlways: Bool { didSet { save(plainAlways, "plainAlways") } }
    var cleanLinks: Bool { didSet { save(cleanLinks, "cleanLinks") } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    @ObservationIgnored private var autoClearWork: DispatchWorkItem?

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "mm.tools.clipboard." + k) as? Bool ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: "mm.tools.clipboard." + k) as? Int ?? def }
        isEnabled = d.bool(forKey: Self.enabledKey)
        menuBarExplicit = d.object(forKey: Self.menuBarKey) as? Bool
        skipSensitive = bool("skipSensitive", true)
        excludedApps = d.stringArray(forKey: "mm.tools.clipboard.excludedApps") ?? Self.defaultExcludedApps
        autoClearSeconds = int("autoClearSeconds", 0)
        clearOnLock = bool("clearOnLock", false)
        expireDays = int("expireDays", 0)
        maxItems = Self.historySizes.contains(int("maxItems", 50)) ? int("maxItems", 50) : 50
        plainAlways = bool("plainAlways", false)
        cleanLinks = bool("cleanLinks", false)
        cleanedCount = int("cleanedCount", 0)
        loadPins()
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: "mm.tools.clipboard." + key) }

    /// Call at app launch; honours the saved settings. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.clearOnLock == true { self?.clearUnpinned() } }
        }
        registerHotKeys()
        refreshPolling()
    }

    func stop() {
        halt()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        GlobalHotKeys.shared.unregister("clipboard.plain")
        GlobalHotKeys.shared.unregister("clipboard.quick")
        started = false
    }

    /// (Re)registers both global shortcuts from their saved values. Both default to none.
    func registerHotKeys() {
        GlobalHotKeys.shared.register("clipboard.plain", defaultsKey: Self.plainHotKeyKey) {
            MainActor.assumeIsolated { ToolsClipboard.shared.pastePlainText() }
        }
        GlobalHotKeys.shared.register("clipboard.quick", defaultsKey: Self.quickHotKeyKey) {
            MainActor.assumeIsolated { ToolsClipboardQuickPanel.shared.toggle() }
        }
    }

    // MARK: Polling

    /// The 0.5 s changeCount poll only runs while recording is on (or auto-clear needs to watch the clipboard).
    private func refreshPolling() {
        guard started else { return }
        if isEnabled || autoClearSeconds > 0 { begin() } else { halt() }
    }

    private func begin() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        expireOld()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func halt() {
        timer?.invalidate()
        timer = nil
        autoClearWork?.cancel()
        autoClearWork = nil
    }

    private func poll() {
        tick += 1
        if tick % 120 == 0 { expireOld() }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        ingest(pb)
    }

    /// Reads the pasteboard after a change. Only runs when `changeCount` moved.
    private func ingest(_ pb: NSPasteboard) {
        let types = Set((pb.types ?? []).map(\.rawValue))
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        let fromExcluded = bundleID.map { id in excludedApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame } } ?? false
        let concealed = !types.isDisjoint(with: Self.concealedTypes)
        let transient = !types.isDisjoint(with: Self.transientTypes)

        // Secrets from password managers can be wiped from the clipboard after a while.
        if concealed || fromExcluded { scheduleAutoClear(for: pb.changeCount) }
        guard isEnabled, !fromExcluded else { return }
        if skipSensitive, concealed || transient { return }

        let sourceName = front?.localizedName
        var text = pb.string(forType: .string)
        let hasRich = types.contains(NSPasteboard.PasteboardType.rtf.rawValue) || types.contains(NSPasteboard.PasteboardType.html.rawValue)

        if cleanLinks, !hasRich, let s = text, let cleaned = ToolsClipboardLinkCleaner.clean(s) {
            pb.clearContents()
            pb.declareTypes([.string, .URL], owner: nil)
            pb.setString(cleaned, forType: .string)
            pb.setString(cleaned, forType: .URL)
            lastChange = pb.changeCount
            cleanedCount += 1
            save(cleanedCount, "cleanedCount")
            text = cleaned
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(.files(urls), bundleID: bundleID, name: sourceName); return
        }
        if let s = text, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var rtf: Data?
            if let d = pb.data(forType: .rtf), d.count <= Self.maxRTFBytes { rtf = d }
            add(.text(s), rtf: rtf, bundleID: bundleID, name: sourceName); return
        }
        if let png = pb.data(forType: .png) {
            if png.count < Self.maxImageBytes { add(.image(png), bundleID: bundleID, name: sourceName) }
            return
        }
        if let tiff = pb.data(forType: .tiff), tiff.count < Self.maxTIFFBytes {
            // TIFF is huge; store a PNG instead, converted off the main thread.
            Task { [weak self] in
                let png = await Task.detached(priority: .utility) { Self.pngData(fromTIFF: tiff) }.value
                guard let self, let png, png.count < Self.maxImageBytes else { return }
                self.add(.image(png), bundleID: bundleID, name: sourceName)
            }
        }
    }

    nonisolated private static func pngData(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func add(_ kind: ToolsClipboardItem.Kind, rtf: Data? = nil, bundleID: String?, name: String?) {
        // Move duplicates to the top instead of repeating them.
        if let i = items.firstIndex(where: { Self.same($0.kind, kind) }) {
            var it = items.remove(at: i)
            it.date = Date()
            if rtf != nil { it.rtf = rtf }
            it.sourceBundleID = bundleID ?? it.sourceBundleID
            it.sourceName = name ?? it.sourceName
            // Pins stay in their saved order; recent items go straight to the top.
            items.insert(it, at: 0)
        } else {
            items.insert(ToolsClipboardItem(kind: kind, rtf: rtf, sourceBundleID: bundleID, sourceName: name), at: 0)
        }
        trim()
    }

    private static func same(_ a: ToolsClipboardItem.Kind, _ b: ToolsClipboardItem.Kind) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x == y
        case (.files(let x), .files(let y)): return x == y
        case (.image(let x), .image(let y)): return x.count == y.count && x == y
        default: return false
        }
    }

    private func trim() {
        var unpinned = 0, imageBytes = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            guard unpinned <= maxItems else { return false }
            // Newest first, so the oldest images are the ones dropped over budget.
            if case .image(let d) = item.kind {
                imageBytes += d.count
                return imageBytes <= Self.imageBudget
            }
            return true
        }
    }

    /// Drops unpinned items older than the chosen number of days.
    func expireOld() {
        guard expireDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(expireDays) * 86_400)
        items.removeAll { !$0.pinned && $0.date < cutoff }
    }

    /// After `autoClearSeconds`, wipes the clipboard if it still holds the secret that was just copied.
    private func scheduleAutoClear(for changeCount: Int) {
        autoClearWork?.cancel()
        autoClearWork = nil
        guard autoClearSeconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                let pb = NSPasteboard.general
                guard pb.changeCount == changeCount else { return }
                pb.clearContents()
                self?.lastChange = pb.changeCount
                self?.autoClearWork = nil
            }
        }
        autoClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoClearSeconds), execute: work)
    }

    // MARK: Excluded apps

    func excludeApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        excludedApps.append(bundleID)
        UserDefaults.standard.set(excludedApps, forKey: "mm.tools.clipboard.excludedApps")
    }

    func includeApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        UserDefaults.standard.set(excludedApps, forKey: "mm.tools.clipboard.excludedApps")
    }

    func resetExcludedApps() {
        excludedApps = Self.defaultExcludedApps
        UserDefaults.standard.removeObject(forKey: "mm.tools.clipboard.excludedApps")
    }

    // MARK: Actions

    /// Puts an item back on the clipboard. `plain` drops formatting from rich text.
    func copyBack(_ item: ToolsClipboardItem, plain: Bool? = nil) {
        let asPlain = plain ?? plainAlways
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s):
            if !asPlain, let rtf = item.rtf {
                pb.declareTypes([.string, .rtf], owner: nil)
                pb.setString(s, forType: .string)
                pb.setData(rtf, forType: .rtf)
            } else {
                pb.setString(s, forType: .string)
            }
        case .image(let d):
            if let img = NSImage(data: d) { pb.writeObjects([img]) } else { pb.setData(d, forType: .png) }
        case .files(let urls): pb.writeObjects(urls as [NSURL])
        }
        lastChange = pb.changeCount
        copiedID = item.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == item.id { copiedID = nil }
        }
    }

    /// Copies the item, brings `app` forward and sends ⌘V. Needs Accessibility; without it the item is only copied.
    @discardableResult
    func paste(_ item: ToolsClipboardItem, plain: Bool? = nil, into app: NSRunningApplication?) -> Bool {
        copyBack(item, plain: plain)
        guard Permissions.isGranted(.accessibility) else {
            Permissions.request(.accessibility)
            Notifier.post(title: "Copied to clipboard", body: "Allow MacMaster in Accessibility settings to paste automatically.", id: "clipboard.ax", sound: false)
            return false
        }
        FrontAppTracker.markDeliberate()
        let target = app ?? FrontAppTracker.lastExternal
        if let target, !FrontAppTracker.isSelf(target) {
            FrontAppTracker.activate(target) { Self.whenModifiersReleased { Self.sendCommandV() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.whenModifiersReleased { Self.sendCommandV() } }
        }
        return true
    }

    /// Hotkey action: pastes the current clipboard as plain text, then puts the original (rich) contents back.
    func pastePlainText() {
        guard Permissions.isGranted(.accessibility) else {
            Permissions.request(.accessibility)
            Notifier.post(title: "Accessibility access needed", body: "Allow MacMaster in Accessibility settings to paste as plain text.", id: "clipboard.ax", sound: false)
            return
        }
        let pb = NSPasteboard.general
        let isFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard !isFiles, let s = pb.string(forType: .string), !s.isEmpty else { NSSound.beep(); return }
        let saved = Self.snapshot(pb)
        pb.clearContents()
        pb.setString(s, forType: .string)
        let mine = pb.changeCount
        lastChange = mine
        Self.whenModifiersReleased {
            Self.sendCommandV()
            // Give the app time to read the plain text, then restore what was there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let pb = NSPasteboard.general
                    guard pb.changeCount == mine else { return }   // the user copied something new meanwhile
                    Self.restore(saved, to: pb)
                    ToolsClipboard.shared.lastChange = pb.changeCount
                }
            }
        }
    }

    private typealias Snapshot = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let objs: [NSPasteboardItem] = snap.map { entries in
            let it = NSPasteboardItem()
            for e in entries { it.setData(e.data, forType: e.type) }
            return it
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
    }

    /// Waits (up to ~0.8 s) for the user to let go of the shortcut's modifier keys, so they don't mix into ⌘V.
    private static func whenModifiersReleased(_ action: @escaping @MainActor () -> Void) {
        var tries = 0
        func check() {
            tries += 1
            let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if held.isEmpty || tries > 40 {
                MainActor.assumeIsolated { action() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
            }
        }
        check()
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    func togglePin(_ item: ToolsClipboardItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        if case .image(let d) = items[i].kind {
            if items[i].pinned { Self.writeImageFile(d, id: items[i].id) } else { Self.deleteImageFile(id: items[i].id) }
        }
        savePins()
    }

    func remove(_ item: ToolsClipboardItem) {
        items.removeAll { $0.id == item.id }
        if item.pinned { Self.deleteImageFile(id: item.id) }
        savePins()
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
    }

    // MARK: Persistence of pins

    private static var imageDir: URL {
        let u = AppPaths.support.appendingPathComponent("clipboard-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func imageURL(id: UUID) -> URL { imageDir.appendingPathComponent(id.uuidString + ".png") }

    private static func writeImageFile(_ data: Data, id: UUID) {
        let url = imageURL(id: id)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    private static func deleteImageFile(id: UUID) {
        let url = imageURL(id: id)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }

    private func savePins() {
        let pins: [ToolsClipboardPin] = items.filter(\.pinned).compactMap { it in
            var p = ToolsClipboardPin(id: it.id, rtf: it.rtf, date: it.date, source: it.sourceBundleID, sourceName: it.sourceName)
            switch it.kind {
            case .text(let s): p.text = s
            case .files(let u): p.files = u.map(\.path)
            case .image: p.image = it.id.uuidString + ".png"
            }
            return p
        }
        Store.save(pins, to: "clipboard-pins.json")
    }

    private func loadPins() {
        let pins = Store.load([ToolsClipboardPin].self, from: "clipboard-pins.json") ?? []
        items = pins.compactMap { p in
            let id = p.id ?? UUID()
            let date = p.date ?? Date()
            if let t = p.text {
                return ToolsClipboardItem(id: id, kind: .text(t), date: date, pinned: true, rtf: p.rtf, sourceBundleID: p.source, sourceName: p.sourceName)
            }
            if let f = p.files {
                return ToolsClipboardItem(id: id, kind: .files(f.map { URL(fileURLWithPath: $0) }), date: date, pinned: true,
                                          sourceBundleID: p.source, sourceName: p.sourceName)
            }
            if p.image != nil, let d = try? Data(contentsOf: Self.imageURL(id: id)) {
                return ToolsClipboardItem(id: id, kind: .image(d), date: date, pinned: true, sourceBundleID: p.source, sourceName: p.sourceName)
            }
            return nil
        }
    }
}
