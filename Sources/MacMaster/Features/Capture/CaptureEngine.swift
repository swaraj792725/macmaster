import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let captureLog = Logger(subsystem: "com.macmaster.app", category: "capture")

/// Orchestrates Capture: region overlay, OCR, QR scan, color picker, screenshots and pins.
/// `start()` only registers hot keys and the optional menu bar item. Nothing heavy runs until the user captures.
@MainActor @Observable
final class CaptureEngine {
    static let shared = CaptureEngine()

    /// Newest first. Text and codes are kept in memory only (they may be sensitive); colors persist.
    private(set) var recents: [CaptureRecent] = []
    private(set) var colors: [PickedColor] = []
    /// Actions whose saved shortcut macOS or another app already owns.
    private(set) var conflicted: Set<CaptureAction> = []
    /// True from the click until the region overlay closes.
    private(set) var busy = false
    private(set) var pins: [CapturePinWindow] = []

    @ObservationIgnored private var overlay: CaptureOverlay?
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private var lastShot: CaptureImage?
    @ObservationIgnored private var lastShotRect: CGRect?
    @ObservationIgnored private var started = false

    private static let historyLimit = 24
    private static let recentLimit = 12

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: CapturePrefs.colorHistory) ?? []
        colors = saved.compactMap { PickedColor(hex: $0) }
    }

    var hasPin: Bool { !pins.isEmpty }
    var canPinLast: Bool { lastShot != nil }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        registerHotKeys()
        updateMenuBar()
    }

    /// Re-reads every saved shortcut. Call after the user records one.
    func registerHotKeys() {
        var bad = Set<CaptureAction>()
        for a in CaptureAction.allCases {
            let ok = GlobalHotKeys.shared.register(a.hotKeyName, defaultsKey: CapturePrefs.hotKeyKey(a)) { [weak self] in
                self?.run(a)
            }
            if !ok { bad.insert(a) }
        }
        conflicted = bad
    }

    func updateMenuBar() {
        let on = UserDefaults.standard.bool(forKey: CapturePrefs.menuBar)
        CaptureMenuBar.shared.set(visible: on)
    }

    func run(_ action: CaptureAction) {
        switch action {
        case .text: beginRegion(.text)
        case .code: beginRegion(.code)
        case .shot: beginRegion(.shot)
        case .color: pickColor()
        case .pin: pinLast()
        }
    }

    // MARK: Region capture

    enum RegionMode {
        case text, code, shot
        var hint: String {
            switch self {
            case .text: "Drag over the text to copy · Esc to cancel"
            case .code: "Drag over a QR code or barcode · Esc to cancel"
            case .shot: "Drag to capture · click a window · Esc to cancel"
            }
        }
    }

    func beginRegion(_ mode: RegionMode) {
        guard !busy else { return }
        guard Permissions.isGranted(.screenRecording) else { needScreenRecording(); return }
        busy = true
        let windows = Self.windowRects()
        let keep = Set(pins.map { CGWindowID($0.windowNumber) })
        Task { @MainActor [weak self] in
            do {
                let frames = try await CaptureGrabber.grabAll(keepWindowNumbers: keep)
                guard let self else { return }
                let ov = CaptureOverlay(frames: frames, windowRects: windows, hint: mode.hint)
                self.overlay = ov
                ov.begin { [weak self] sel in
                    guard let self else { return }
                    self.overlay = nil
                    self.busy = false
                    guard let sel else { return }
                    self.handle(sel, mode: mode)
                }
            } catch {
                captureLog.error("grab failed: \(error.localizedDescription, privacy: .public)")
                self?.busy = false
                self?.fail("Couldn't capture the screen", error.localizedDescription)
            }
        }
    }

    /// Cancels an open overlay (for example when the app is quitting).
    func cancelOverlay() { overlay?.cancel() }

    private func needScreenRecording() {
        CaptureHUD.shared.show(CaptureToast(
            title: "Screen Recording needed",
            detail: "Capture Text, Scan Code and Screenshot need it to freeze the screen.",
            symbol: "lock.shield.fill", tint: .orange,
            actionTitle: "Grant", action: { Permissions.request(.screenRecording) }, duration: 8))
    }

    private func fail(_ title: String, _ detail: String = "") {
        CaptureHUD.shared.show(CaptureToast(title: title, detail: detail,
                                            symbol: "exclamationmark.triangle.fill", tint: .orange, duration: 5))
    }

    /// Windows on screen, front to back, in global Cocoa coordinates. Our own windows are skipped.
    private static func windowRects() -> [CGRect] {
        guard let primaryH = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [CGRect] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d as CFDictionary),
                  b.width >= 24, b.height >= 24 else { continue }
            out.append(CGRect(x: b.minX, y: primaryH - b.maxY, width: b.width, height: b.height))
        }
        return out
    }

    private func handle(_ sel: CaptureOverlay.Selection, mode: RegionMode) {
        switch mode {
        case .text: recognize(sel, codesOnly: false)
        case .code: recognize(sel, codesOnly: true)
        case .shot: finishShot(sel)
        }
    }

    // MARK: OCR and codes

    private func recognize(_ sel: CaptureOverlay.Selection, codesOnly: Bool) {
        let img = sel.image
        let preferred = CapturePrefs.preferredLanguages
        let keep = CapturePrefs.keepBreaks
        let alsoCodes = codesOnly || CapturePrefs.alsoCodes
        Task { @MainActor [weak self] in
            let out = await Task.detached(priority: .userInitiated) {
                CaptureVision.analyze(img.cg, text: !codesOnly, codes: alsoCodes, preferredLanguages: preferred, keepLineBreaks: keep)
            }.value
            self?.present(out, codesOnly: codesOnly)
        }
    }

    private func present(_ out: CaptureVision.Output, codesOnly: Bool) {
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let codes = out.codes
        for c in codes.reversed() { addRecent(.init(kind: .code, text: c.payload, date: Date())) }

        if !codesOnly, !text.isEmpty {
            Self.copyText(text)
            addRecent(.init(kind: .text, text: text, date: Date()))
            beep()
            let words = CaptureText.wordCount(text)
            var toast = CaptureToast(title: "Copied \(words) \(words == 1 ? "word" : "words")",
                                     detail: Self.preview(text), symbol: "text.viewfinder", tint: .purple)
            if let c = codes.first {
                toast.actionTitle = "Copy code"
                toast.action = { Self.copyText(c.payload) }
                toast.detail += "\nAlso found a \(c.symbology)"
            }
            CaptureHUD.shared.show(toast)
            return
        }
        if let first = codes.first {
            let all = codes.map(\.payload).joined(separator: "\n")
            Self.copyText(all)
            beep()
            var toast = CaptureToast(title: codes.count == 1 ? "Copied \(first.symbology)" : "Copied \(codes.count) codes",
                                     detail: Self.preview(first.payload), symbol: "qrcode.viewfinder", tint: .blue)
            if let url = CaptureRecent.url(from: first.payload) {
                toast.actionTitle = "Open"
                toast.action = { NSWorkspace.shared.open(url) }
                toast.duration = 7
            }
            CaptureHUD.shared.show(toast)
            return
        }
        fail(codesOnly ? "No QR code or barcode found" : "No text found",
             codesOnly ? "Select the whole code, with a little margin." : "Try a tighter selection around the text.")
    }

    private static func preview(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).joined(separator: "\n")
        return lines.count > 160 ? String(lines.prefix(160)) + "…" : lines
    }

    private func addRecent(_ r: CaptureRecent) {
        recents.removeAll { $0.text == r.text && $0.kind == r.kind }
        recents.insert(r, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
    }

    func clearRecents() { recents.removeAll() }

    // MARK: Screenshots

    private func finishShot(_ sel: CaptureOverlay.Selection) {
        let img = sel.image
        lastShot = img
        lastShotRect = sel.rect
        let after = CapturePrefs.after
        let thumb = Self.thumbnail(img)
        beep(shutter: true)

        if after == .copy || after == .both { Self.copyToClipboard(img) }
        if after == .pin { pin(img, near: sel.rect) }

        guard after == .save || after == .both else {
            let title = after == .pin ? "Pinned to screen" : "Screenshot copied"
            var t = CaptureToast(title: title, detail: "\(Int(img.size.width)) × \(Int(img.size.height))",
                                 symbol: "camera.viewfinder", tint: .purple, thumbnail: thumb)
            if after != .pin {
                t.actionTitle = "Pin"
                t.action = { [weak self] in self?.pin(img, near: sel.rect) }
            }
            CaptureHUD.shared.show(t)
            return
        }
        let folder = CapturePrefs.saveFolderURL
        Task { @MainActor [weak self] in
            do {
                let url = try await Task.detached(priority: .userInitiated) { try Self.writePNG(img, to: folder) }.value
                let verb = after == .both ? "Copied and saved" : "Saved"
                CaptureHUD.shared.show(CaptureToast(
                    title: "\(verb) screenshot", detail: url.lastPathComponent, symbol: "camera.viewfinder", tint: .purple,
                    thumbnail: thumb, actionTitle: "Show",
                    action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }, duration: 5))
            } catch {
                self?.fail("Couldn't save the screenshot", error.localizedDescription)
            }
        }
    }

    nonisolated static func writePNG(_ image: CaptureImage, to folder: URL) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: image.cg)
        rep.size = NSSize(width: image.size.width, height: image.size.height)   // keeps the DPI of a Retina capture
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(f.string(from: Date()))"
        var url = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func copyToClipboard(_ image: CaptureImage) {
        let ns = NSImage(cgImage: image.cg, size: NSSize(width: image.size.width, height: image.size.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func savePanel(_ image: CaptureImage) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "Screenshot.png"
        p.directoryURL = CapturePrefs.saveFolderURL
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { @MainActor [weak self] in
            do {
                let folder = url.deletingLastPathComponent()
                let saved = try await Task.detached { try Self.writePNG(image, to: folder) }.value
                if saved != url { try? FileManager.default.removeItem(at: url); try FileManager.default.moveItem(at: saved, to: url) }
            } catch { self?.fail("Couldn't save the image", error.localizedDescription) }
        }
    }

    private static func thumbnail(_ img: CaptureImage) -> NSImage {
        let full = NSImage(cgImage: img.cg, size: NSSize(width: img.size.width, height: img.size.height))
        return full
    }

    // MARK: Pins

    func pin(_ image: CaptureImage, near rect: CGRect?) {
        let w = CapturePinWindow(image: image, near: rect)
        w.onClose = { [weak self] win in self?.pins.removeAll { $0 === win } }
        pins.append(w)
        w.present()
    }

    func pinLast() {
        guard let img = lastShot else {
            CaptureHUD.shared.show(CaptureToast(title: "Nothing to pin yet", detail: "Take a screenshot first.",
                                                symbol: "pin.slash", tint: .secondary))
            return
        }
        pin(img, near: lastShotRect)
    }

    func closeAllPins() {
        for p in pins { p.closePin() }
        pins.removeAll()
    }

    // MARK: Colors

    /// Opens the system eyedropper. With `copy`, the color goes to the clipboard in the chosen format.
    func pickColor(copy: Bool = true, completion: ((PickedColor) -> Void)? = nil) {
        guard sampler == nil else { return }
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] picked in
            Task { @MainActor in
                guard let self else { return }
                self.sampler = nil
                guard let picked, let c = PickedColor(nsColor: picked) else { return }
                self.addColor(c)
                if copy { self.copyColor(c, format: CapturePrefs.format, toast: true) }
                completion?(c)
            }
        }
    }

    func addColor(_ c: PickedColor) {
        colors.removeAll { $0 == c }
        colors.insert(c, at: 0)
        if colors.count > Self.historyLimit { colors.removeLast(colors.count - Self.historyLimit) }
        saveColors()
    }

    func removeColor(_ c: PickedColor) {
        colors.removeAll { $0 == c }
        saveColors()
    }

    func clearColors() {
        colors.removeAll()
        saveColors()
    }

    private func saveColors() {
        UserDefaults.standard.set(colors.map(\.hex), forKey: CapturePrefs.colorHistory)
    }

    func copyColor(_ c: PickedColor, format: ColorFormat, toast: Bool = false) {
        let s = c.string(format)
        Self.copyText(s)
        if toast {
            beep()
            CaptureHUD.shared.show(CaptureToast(title: "Copied \(s)", detail: format.title, swatch: c.color, duration: 2.5))
        }
    }

    // MARK: Sound

    private func beep(shutter: Bool = false) {
        guard CapturePrefs.playSound else { return }
        if shutter {
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
            if FileManager.default.fileExists(atPath: path), let s = NSSound(contentsOfFile: path, byReference: true) {
                s.play(); return
            }
        }
        NSSound(named: "Tink")?.play()
    }
}

// MARK: - Menu bar item

@MainActor
final class CaptureMenuBar: NSObject {
    static let shared = CaptureMenuBar()
    private var item: NSStatusItem?

    func set(visible: Bool) {
        if visible, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let b = it.button {
                let img = NSImage(systemSymbolName: SymbolKit.firstAvailable(["camera.viewfinder", "viewfinder"]),
                                  accessibilityDescription: "Capture")
                img?.isTemplate = true
                b.image = img
            }
            it.menu = makeMenu()
            item = it
        } else if !visible, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ symbol: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: SymbolKit.resolve(symbol), accessibilityDescription: nil)
            m.addItem(mi)
        }
        add("Capture Text", "text.viewfinder", #selector(text))
        add("Scan QR or Barcode", "qrcode.viewfinder", #selector(code))
        add("Pick Color", "eyedropper", #selector(color))
        add("Screenshot Region", "camera.viewfinder", #selector(shot))
        add("Pin Last Screenshot", "pin", #selector(pin))
        m.addItem(.separator())
        add("Capture Settings…", "gearshape", #selector(settings))
        return m
    }

    /// The menu has just closed; give the screen a moment to redraw before freezing it.
    private func later(_ a: CaptureAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { CaptureEngine.shared.run(a) }
        }
    }

    @objc private func text() { later(.text) }
    @objc private func code() { later(.code) }
    @objc private func color() { later(.color) }
    @objc private func shot() { later(.shot) }
    @objc private func pin() { later(.pin) }
    @objc private func settings() { MainWindow.show(section: .capture) }
}
