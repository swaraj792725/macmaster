import SwiftUI
import AppKit

struct CaptureView: View {
    @State private var engine = CaptureEngine.shared

    @AppStorage(CapturePrefs.keepLineBreaks) private var keepLineBreaks = true
    @AppStorage(CapturePrefs.detectCodes) private var detectCodes = false
    @AppStorage(CapturePrefs.sound) private var playSound = true
    @AppStorage(CapturePrefs.languageMode) private var languageMode = "auto"
    @AppStorage(CapturePrefs.saveFolder) private var saveFolder = ""
    @AppStorage(CapturePrefs.afterShot) private var afterShot = AfterShot.copy.rawValue
    @AppStorage(CapturePrefs.menuBar) private var menuBar = false
    @AppStorage(CapturePrefs.colorFormat) private var colorFormat = ColorFormat.hex.rawValue
    @AppStorage(CapturePrefs.contrastText) private var contrastText = "#000000"
    @AppStorage(CapturePrefs.contrastBackground) private var contrastBackground = "#FFFFFF"

    @State private var selected: PickedColor?
    @State private var note: String?

    private var format: ColorFormat { ColorFormat(rawValue: colorFormat) ?? .hex }

    var body: some View {
        Page {
            PageHeader(title: AppSection.capture.title, subtitle: AppSection.capture.blurb,
                       symbol: AppSection.capture.symbol, colors: AppSection.capture.colors) {
                if engine.hasPin {
                    Button { engine.closeAllPins() } label: { Label("Close pins", systemImage: "pin.slash") }
                        .buttonStyle(.mmSecondary)
                }
            }

            PermissionBanner(permission: .screenRecording,
                             reason: "Capture Text, Scan Code and Screenshot freeze the screen first. Pick Color works without it.")

            actions
            recent
            colorsCard
            contrastCard
            settings
        }
    }

    // MARK: Actions

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 12, alignment: .top)], spacing: 12) {
            ActionCard(action: .text, blurb: "Select text on screen and copy it", symbol: "text.viewfinder",
                       colors: Theme.Palette.purple, engine: engine)
            ActionCard(action: .code, blurb: "Read a QR code or barcode", symbol: "qrcode.viewfinder",
                       colors: Theme.Palette.blue, engine: engine)
            ActionCard(action: .color, blurb: "Pick any color on screen", symbol: "eyedropper",
                       colors: Theme.Palette.pink, engine: engine)
            ActionCard(action: .shot, blurb: "Copy, save or pin a region", symbol: "camera.viewfinder",
                       colors: Theme.Palette.orange, engine: engine)
        }
        .searchAnchor("capture.actions")
    }

    // MARK: Recent

    private var recent: some View {
        GroupedSection("Recent", symbol: "clock.arrow.circlepath",
                       footer: engine.recents.isEmpty ? nil : "Kept only until MacMaster quits.") {
            if engine.recents.isEmpty {
                SettingsRow(title: "Nothing captured yet", subtitle: "Text and codes you copy show up here.",
                            symbol: "tray", colors: Theme.Palette.gray)
            } else {
                ForEach(engine.recents.prefix(5)) { item in
                    SettingsRow(title: item.preview, subtitle: item.kind == .code ? "Code" : "Text",
                                symbol: item.kind == .code ? "qrcode" : "text.viewfinder",
                                colors: item.kind == .code ? Theme.Palette.blue : Theme.Palette.purple) {
                        HStack(spacing: 6) {
                            if let url = CaptureRecent.url(from: item.text) {
                                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.mmGhost)
                            }
                            Button("Copy") {
                                CaptureEngine.copyText(item.text)
                                flash("Copied")
                            }
                            .buttonStyle(.mmSecondary)
                        }
                    }
                }
            }
        }
        .searchAnchor("capture.recent")
    }

    // MARK: Colors

    private var colorsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionTitle(text: "Colors", symbol: "paintpalette")
                if let note { Text(note).font(.caption.weight(.medium)).foregroundStyle(.green).transition(.opacity) }
                Spacer()
                Picker("Copy as", selection: $colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Button { engine.pickColor() } label: { Label("Pick", systemImage: "eyedropper") }
                    .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF2D55)))
            }

            if engine.colors.isEmpty {
                Text("Pick a color and it will be saved here. Click a swatch to copy it as \(format.title).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 44), spacing: 8)], spacing: 8) {
                    ForEach(engine.colors) { c in swatch(c) }
                }
                if let sel = selected ?? engine.colors.first {
                    HairlineDivider()
                    VStack(spacing: 0) {
                        ForEach(ColorFormat.allCases) { f in
                            HStack {
                                Text(f.title).font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                Text(sel.string(f)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                                Spacer()
                                Button { engine.copyColor(sel, format: f); flash("Copied \(f.title)") } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.mmGhost).help("Copy \(f.title)")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear history") { engine.clearColors(); selected = nil }.buttonStyle(.mmGhost)
                }
            }
        }
        .card()
        .animation(.smooth(duration: 0.2), value: note)
        .searchAnchor("capture.colors")
    }

    private func swatch(_ c: PickedColor) -> some View {
        let isSel = (selected ?? engine.colors.first) == c
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(c.color)
            .frame(height: 36)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(isSel ? 1 : 0))
            .contentShape(Rectangle())
            .help(c.hex)
            .onTapGesture {
                selected = c
                engine.copyColor(c, format: format)
                flash("Copied \(c.string(format))")
            }
            .contextMenu {
                ForEach(ColorFormat.allCases) { f in
                    Button("Copy \(f.title)") { engine.copyColor(c, format: f); flash("Copied \(f.title)") }
                }
                Divider()
                Button("Use as text color") { contrastText = c.hex }
                Button("Use as background color") { contrastBackground = c.hex }
                Divider()
                Button("Remove", role: .destructive) { engine.removeColor(c); if selected == c { selected = nil } }
            }
    }

    // MARK: Contrast

    private var contrastCard: some View {
        let fg = PickedColor(hex: contrastText) ?? PickedColor(r: 0, g: 0, b: 0)
        let bg = PickedColor(hex: contrastBackground) ?? PickedColor(r: 255, g: 255, b: 255)
        let ratio = PickedColor.contrast(fg, bg)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Contrast checker", symbol: "circle.lefthalf.filled")
            HStack(alignment: .top, spacing: 14) {
                colorSlot("Text", color: fg) { engine.pickColor(copy: false) { contrastText = $0.hex } }
                Button {
                    let t = contrastText; contrastText = contrastBackground; contrastBackground = t
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.mmGhost).help("Swap").padding(.top, 22)
                colorSlot("Background", color: bg) { engine.pickColor(copy: false) { contrastBackground = $0.hex } }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f : 1", ratio))
                        .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(ratio >= 7 ? "Excellent" : ratio >= 4.5 ? "Good" : ratio >= 3 ? "Large text only" : "Poor")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                level("AA text", ratio >= 4.5)
                level("AA large", ratio >= 3)
                level("AAA text", ratio >= 7)
                level("AAA large", ratio >= 4.5)
            }
            HStack(spacing: 12) {
                Text("Aa").font(.system(size: 28, weight: .bold))
                Text("The quick brown fox jumps over the lazy dog.").font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg.color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("Pick two colors, or right-click a swatch above and choose it as text or background.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card()
        .searchAnchor("capture.contrast")
    }

    private func colorSlot(_ title: String, color: PickedColor, pick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.color).frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(color.hex).font(.system(.callout, design: .monospaced))
                    Button("Pick", action: pick).buttonStyle(.mmGhost).font(.caption)
                }
            }
        }
    }

    private func level(_ title: String, _ pass: Bool) -> some View {
        StatusPill(text: "\(title) \(pass ? "pass" : "fail")", color: pass ? .green : .red)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            GroupedSection("Text recognition", symbol: "text.viewfinder") {
                SettingsRow(title: "Keep line breaks", subtitle: "Off joins the lines into one paragraph.",
                            symbol: "text.alignleft", colors: Theme.Palette.purple) {
                    Toggle("", isOn: $keepLineBreaks).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Also detect QR codes and barcodes", subtitle: "Capture Text copies a code if it finds one.",
                            symbol: "qrcode", colors: Theme.Palette.blue) {
                    Toggle("", isOn: $detectCodes).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Language", subtitle: languageSubtitle, symbol: "globe", colors: Theme.Palette.teal) {
                    Picker("", selection: $languageMode) {
                        Text("Automatic").tag("auto")
                        Text("My preferred languages").tag("preferred")
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .searchAnchor("capture.ocr")

            GroupedSection("Screenshots", symbol: "camera.viewfinder",
                           footer: "Click a window instead of dragging to capture just that window. Pinned images float above everything: scroll to resize, hold ⌥ and scroll to fade, double-click or press Esc to close.") {
                SettingsRow(title: "After capture", subtitle: "What a screenshot does as soon as you let go.",
                            symbol: "bolt.fill", colors: Theme.Palette.orange) {
                    Picker("", selection: $afterShot) {
                        ForEach(AfterShot.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Save folder", subtitle: folderDisplay, symbol: "folder.fill", colors: Theme.Palette.blue) {
                    HStack(spacing: 6) {
                        Button("Reveal") { NSWorkspace.shared.open(CapturePrefs.saveFolderURL) }.buttonStyle(.mmGhost)
                        Button("Choose…") { chooseFolder() }.buttonStyle(.mmSecondary)
                    }
                }
                SettingsRow(title: "Pin last screenshot", subtitle: engine.canPinLast ? "Shortcut for the most recent capture." : "Shortcut. Take a screenshot first.",
                            symbol: "pin.fill", colors: Theme.Palette.red) {
                    CaptureHotKeyField(action: .pin, engine: engine)
                }
            }
            .searchAnchor("capture.screenshots")

            GroupedSection("General", symbol: "gearshape.fill") {
                SettingsRow(title: "Play sound", subtitle: "A soft tick when something is copied.",
                            symbol: "speaker.wave.2.fill", colors: Theme.Palette.gray) {
                    Toggle("", isOn: $playSound).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Capture in the menu bar", subtitle: "A menu with every action.",
                            symbol: "menubar.rectangle", colors: Theme.Palette.indigo) {
                    Toggle("", isOn: $menuBar).labelsHidden().toggleStyle(.switch)
                        .onChange(of: menuBar) { _, _ in engine.updateMenuBar() }
                }
            }
            .searchAnchor("capture.general")
        }
    }

    private var languageSubtitle: String {
        guard languageMode == "preferred" else { return "Detects the language for you." }
        let names = Locale.preferredLanguages.prefix(3).compactMap { Locale.current.localizedString(forIdentifier: $0) }
        return names.isEmpty ? "Uses your system languages." : names.joined(separator: ", ")
    }

    private var folderDisplay: String {
        (CapturePrefs.saveFolderURL.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.directoryURL = CapturePrefs.saveFolderURL
        if p.runModal() == .OK, let url = p.url { saveFolder = url.path }
    }

    private func flash(_ text: String) {
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if note == text { note = nil }
        }
    }
}

// MARK: - Action card

private struct ActionCard: View {
    let action: CaptureAction
    let blurb: String
    let symbol: String
    let colors: [Color]
    let engine: CaptureEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { engine.run(action) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    IconTile(symbol: symbol, colors: colors, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).font(.system(size: 15, weight: .semibold))
                        Text(blurb).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.mmCard)
            HairlineDivider()
            VStack(alignment: .leading, spacing: 3) {
                CaptureHotKeyField(action: action, engine: engine)
                if engine.conflicted.contains(action) {
                    Text("Already used by another app").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .card()
    }
}

/// Click-to-record shortcut for one action; re-registers the hot keys after each change.
private struct CaptureHotKeyField: View {
    let action: CaptureAction
    let engine: CaptureEngine
    @State private var combo: KeyboardCombo?

    var body: some View {
        KeyboardRecorderField(combo: Binding(get: { combo }, set: { new in
            combo = new
            StoredHotKey.save(new, CapturePrefs.hotKeyKey(action))
            engine.registerHotKeys()
        }), requireModifier: true, minWidth: 110)
        .onAppear { combo = StoredHotKey.load(CapturePrefs.hotKeyKey(action)) }
    }
}

// MARK: - Search

extension AppSearchIndex {
    /// Capture settings, added to the global search.
    static let captureEntries: [SearchEntry] = [
        SearchEntry(.capture, crumb: "Actions", "Capture Text (OCR)", "ocr copy text from screen recognize image text vision", anchor: "capture.actions"),
        SearchEntry(.capture, crumb: "Actions", "Scan QR code or barcode", "qr barcode scan code payload url", anchor: "capture.actions"),
        SearchEntry(.capture, crumb: "Actions", "Pick color", "eyedropper color picker hex rgb hsl", anchor: "capture.actions"),
        SearchEntry(.capture, crumb: "Actions", "Screenshot region", "screenshot screen grab region window capture", anchor: "capture.actions"),
        SearchEntry(.capture, crumb: "Actions", "Capture shortcuts", "hotkey shortcut keyboard record capture text color screenshot", anchor: "capture.actions"),
        SearchEntry(.capture, crumb: "Recent", "Recent captures", "history text codes copied", anchor: "capture.recent"),
        SearchEntry(.capture, crumb: "Colors", "Color history", "swatches picked colors copy format swiftui nscolor css", anchor: "capture.colors"),
        SearchEntry(.capture, crumb: "Colors", "Contrast checker", "wcag contrast ratio accessibility aa aaa", anchor: "capture.contrast"),
        SearchEntry(.capture, crumb: "Text recognition", "Keep line breaks", "ocr newline paragraph", anchor: "capture.ocr"),
        SearchEntry(.capture, crumb: "Text recognition", "Also detect QR codes and barcodes", "ocr barcode qr", anchor: "capture.ocr"),
        SearchEntry(.capture, crumb: "Text recognition", "Recognition language", "ocr language automatic preferred", anchor: "capture.ocr"),
        SearchEntry(.capture, crumb: "Screenshots", "After capture action", "copy save pin screenshot clipboard", anchor: "capture.screenshots"),
        SearchEntry(.capture, crumb: "Screenshots", "Screenshot save folder", "desktop folder png save location", anchor: "capture.screenshots"),
        SearchEntry(.capture, crumb: "Screenshots", "Pin to screen", "pin floating image always on top", anchor: "capture.screenshots"),
        SearchEntry(.capture, crumb: "General", "Capture sound", "sound tick audio", anchor: "capture.general"),
        SearchEntry(.capture, crumb: "General", "Show Capture in the menu bar", "menu bar item status", anchor: "capture.general"),
    ]
}
