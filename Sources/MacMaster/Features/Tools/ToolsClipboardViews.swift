import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shared helpers

/// App name and icon lookups for the source-app badge and the exclusion list. Cached.
@MainActor
enum ToolsClipboardApps {
    private static let icons = NSCache<NSString, NSImage>()
    private static var missing = Set<String>()
    private static var names: [String: String] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !missing.contains(bundleID) else { return nil }
        if let c = icons.object(forKey: bundleID as NSString) { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID); return nil
        }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 32, height: 32)
        icons.setObject(img, forKey: bundleID as NSString)
        return img
    }

    static func name(_ bundleID: String) -> String {
        if let n = names[bundleID] { return n }
        var n = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleID] = n
        return n
    }

    /// Regular running apps that are not already excluded, for the "Add app" menu.
    static func runningCandidates(excluding: [String]) -> [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  !excluding.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }),
                  seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Lets the user pick any installed app and returns its bundle id.
    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to ignore"
        panel.prompt = "Ignore"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// Small downscaled previews so lists never decode full-size images.
@MainActor
enum ToolsClipboardThumbs {
    private static let cache = NSCache<NSUUID, NSImage>()

    static func image(for item: ToolsClipboardItem, data: Data) -> NSImage? {
        let key = item.id as NSUUID
        if let c = cache.object(forKey: key) { return c }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(img, forKey: key)
        return img
    }
}

/// What one history item looks like: text, link (domain), color swatch, image thumbnail or file.
struct ToolsClipboardPreview: View {
    let item: ToolsClipboardItem
    var lines = 2
    var thumb = CGSize(width: 52, height: 38)

    var body: some View {
        switch item.kind {
        case .text(let s):
            if let url = item.linkURL {
                HStack(spacing: 10) {
                    glyph("link", Theme.Palette.blue.last ?? .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.domain(url)).font(.callout.weight(.medium)).lineLimit(1)
                        Text(s.trimmingCharacters(in: .whitespacesAndNewlines)).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let rgba = item.colorRGBA, rgba.count == 4 {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]))
                        .frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.colorLabel ?? s).font(.system(.callout, design: .monospaced))
                        Text("Color").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    glyph(item.rtf == nil ? "text.alignleft" : "textformat", .secondary)
                    Text(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)))
                        .font(.callout).lineLimit(lines).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .image(let d):
            HStack(spacing: 10) {
                if let img = ToolsClipboardThumbs.image(for: item, data: d) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: thumb.width, height: thumb.height)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                } else {
                    glyph("photo", .secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Image").font(.callout)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .files(let urls):
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "")).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")).font(.callout).lineLimit(1)
                    Text(urls.count > 2 ? "+ \(urls.count - 2) more" : (urls.first?.deletingLastPathComponent().path.abbreviatingHome ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(color).frame(width: 22, height: 22)
    }

    static func domain(_ url: URL) -> String {
        let h = url.host ?? url.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Source app icon + relative time, shown at the right of a row.
struct ToolsClipboardMeta: View {
    let item: ToolsClipboardItem
    var body: some View {
        HStack(spacing: 5) {
            if let icon = ToolsClipboardApps.icon(item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    .help(item.sourceName.map { "Copied from \($0)" } ?? "")
            }
            Text(ToolsFormat.relative(item.date)).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tool view

struct ToolsClipboardView: View {
    private enum Tab: String { case history = "History", settings = "Settings" }
    @Bindable private var clip = ToolsClipboard.shared
    @State private var tab: Tab = .history
    @State private var query = ""
    @State private var filter: ToolsClipboardFilter = .all
    @State private var confirmClear = false

    private var filtered: [ToolsClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = clip.items.filter { filter.matches($0) && (q.isEmpty || $0.searchText.localizedCaseInsensitiveContains(q)) }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch tab {
            case .history: historyTab
            case .settings: settingsTab
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $tab) {
                Text("History").tag(Tab.history)
                Text("Settings").tag(Tab.settings)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Spacer()
            StatusPill(text: clip.isEnabled ? "Recording" : "Paused", color: clip.isEnabled ? .green : .gray)
            Toggle("", isOn: $clip.isEnabled).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
    }

    // MARK: History

    private var historyTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search history", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                Button("Clear history") { confirmClear = true }
                    .buttonStyle(.mmSecondary)
                    .disabled(clip.items.allSatisfy(\.pinned))
                    .confirmationDialog("Clear all unpinned items?", isPresented: $confirmClear) {
                        Button("Clear history", role: .destructive) { clip.clearUnpinned() }
                    } message: { Text("Pinned items stay.") }
            }
            .padding(.horizontal, Theme.pagePadding)

            chips.padding(.horizontal, Theme.pagePadding).padding(.vertical, 10)

            let list = filtered
            if !clip.isEnabled && clip.items.isEmpty {
                ToolsEmptyHint(symbol: "doc.on.clipboard",
                               text: "Turn on recording to keep your recent copies.\nPasswords from password managers are never recorded, and history stays in memory only.")
                Spacer()
            } else if list.isEmpty {
                ToolsEmptyHint(symbol: "magnifyingglass",
                               text: clip.items.isEmpty ? "Copy something to see it here." : "No matches.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list) { item in ToolsClipboardRow(item: item) }
                    }
                    .padding(.horizontal, Theme.pagePadding).padding(.bottom, 14)
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(ToolsClipboardFilter.allCases) { f in
                let on = filter == f
                Button { filter = f } label: {
                    Text(f.title).font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(filtered.count) item\(filtered.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Settings

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                GroupedSection("General", symbol: "gearshape.fill") {
                    SettingsRow(title: "Show in menu bar", subtitle: "A clipboard icon with your recent copies.", symbol: "menubar.rectangle",
                                colors: Theme.Palette.blue) {
                        Toggle("", isOn: Binding(get: { clip.showInMenuBar }, set: { clip.showInMenuBar = $0 }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow(title: "History size", subtitle: "Pinned items don't count.", symbol: "list.number", colors: Theme.Palette.indigo) {
                        Picker("", selection: $clip.maxItems) {
                            ForEach(ToolsClipboard.historySizes, id: \.self) { Text("\($0) items").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }

                privacyGroup

                GroupedSection("Cleanup", symbol: "clock.arrow.circlepath",
                               footer: "History is kept in memory only. Closing MacMaster clears everything except pinned items.") {
                    SettingsRow(title: "Remove old items", subtitle: "Unpinned items older than this are deleted.", symbol: "calendar.badge.clock",
                                colors: Theme.Palette.orange) {
                        Picker("", selection: $clip.expireDays) {
                            ForEach(ToolsClipboard.expiryOptions, id: \.days) { Text($0.label).tag($0.days) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    SettingsRow(title: "Clear history when the screen locks", subtitle: "Unpinned items are removed.", symbol: "lock.fill",
                                colors: Theme.Palette.purple) {
                        Toggle("", isOn: $clip.clearOnLock).labelsHidden().toggleStyle(.switch)
                    }
                }

                pasteGroup
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.pagePadding)
        }
    }

    private var privacyGroup: some View {
        let excluded = clip.excludedApps
        return VStack(alignment: .leading, spacing: Theme.spacing) {
            GroupedSection("Privacy", symbol: "hand.raised.fill",
                           footer: "Copies from these apps are never recorded, and the clipboard can be wiped after a secret is copied.") {
                SettingsRow(title: "Skip passwords and secrets", subtitle: "Ignores items that password managers and other apps mark as concealed or temporary.",
                            symbol: "key.fill", colors: Theme.Palette.red) {
                    Toggle("", isOn: $clip.skipSensitive).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Clear a copied secret", subtitle: "Wipes the clipboard after copying from a password manager or an ignored app.",
                            symbol: "timer", colors: Theme.Palette.orange) {
                    Picker("", selection: $clip.autoClearSeconds) {
                        ForEach(ToolsClipboard.autoClearOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            GroupedSection("Ignored apps", symbol: "app.badge.fill") {
                ForEach(excluded, id: \.self) { id in
                    HStack(spacing: 10) {
                        if let icon = ToolsClipboardApps.icon(id) {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ToolsClipboardApps.name(id)).font(.body)
                            if ToolsClipboardApps.name(id) != id { Text(id).font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Button { clip.includeApp(id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Stop ignoring")
                    }
                }
                HStack {
                    Menu {
                        let running = ToolsClipboardApps.runningCandidates(excluding: excluded)
                        ForEach(running, id: \.id) { app in Button(app.name) { clip.excludeApp(app.id) } }
                        if !running.isEmpty { Divider() }
                        Button("Choose app…") { if let id = ToolsClipboardApps.chooseApp() { clip.excludeApp(id) } }
                    } label: { Label("Add app", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Button("Reset to defaults") { clip.resetExcludedApps() }.buttonStyle(.mmGhost)
                }
            }
        }
    }

    private var pasteGroup: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PermissionBanner(permission: .accessibility,
                             reason: "Needed to paste for you (⌘V) from the quick paste panel and the plain text shortcut.")
            GroupedSection("Paste", symbol: "doc.on.clipboard.fill",
                           footer: "Both shortcuts are off until you set one. Quick paste shows your history next to the cursor; ↑↓ to choose, ⏎ to paste, ⌥⏎ for plain text, ⌘1–9 for quick picks, ⌘P to pin.") {
                SettingsRow(title: "Paste as plain text", subtitle: "Strips formatting from what's on the clipboard, pastes it, then restores the original.",
                            symbol: "textformat", colors: Theme.Palette.teal) {
                    HotKeyField(defaultsKey: ToolsClipboard.plainHotKeyKey) { _ in clip.registerHotKeys() }
                        .frame(width: 150)
                }
                SettingsRow(title: "Quick paste panel", subtitle: "Search and paste from your history without leaving the keyboard.",
                            symbol: "rectangle.and.text.magnifyingglass", colors: Theme.Palette.blue) {
                    HotKeyField(defaultsKey: ToolsClipboard.quickHotKeyKey) { _ in clip.registerHotKeys() }
                        .frame(width: 150)
                }
                SettingsRow(title: "Always paste history items as plain text", subtitle: "Applies when you click or press ⏎ on an item.",
                            symbol: "text.alignleft", colors: Theme.Palette.gray) {
                    Toggle("", isOn: $clip.plainAlways).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Clean tracking from copied links", subtitle: clip.cleanLinks
                            ? "Cleaned \(clip.cleanedCount) link\(clip.cleanedCount == 1 ? "" : "s") so far. Removes utm_*, fbclid, gclid and similar from copied web links."
                            : "Removes utm_*, fbclid, gclid and similar from copied web links. Needs recording on.",
                            symbol: "link.badge.plus", colors: Theme.Palette.green) {
                    Toggle("", isOn: $clip.cleanLinks).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

// MARK: - Row

private struct ToolsClipboardRow: View {
    let item: ToolsClipboardItem
    private let clip = ToolsClipboard.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            ToolsClipboardPreview(item: item, lines: 3, thumb: CGSize(width: 56, height: 42))
            Spacer(minLength: 8)
            if clip.copiedID == item.id {
                StatusPill(text: "Copied", color: .green)
            } else {
                ToolsClipboardMeta(item: item)
            }
            HStack(spacing: 8) {
                if hover {
                    Button { DropShelf.shared.add(clipboard: item.kind) } label: { Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Add to Shelf")
                }
                Button { clip.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.pinned ? Color.orange : Color.secondary.opacity(hover ? 1 : 0.35))
                }
                .buttonStyle(.plain).help(item.pinned ? "Unpin" : "Pin")
                if hover {
                    Button { clip.remove(item) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("Remove")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(hover ? Color.accentColor.opacity(0.4) : Theme.hairline, lineWidth: hover ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { clip.copyBack(item) }
        .contextMenu {
            Button("Copy") { clip.copyBack(item) }
            if item.isText { Button("Copy as plain text") { clip.copyBack(item, plain: true) } }
            Button(item.pinned ? "Unpin" : "Pin") { clip.togglePin(item) }
            Button("Add to Shelf") { DropShelf.shared.add(clipboard: item.kind) }
            Divider()
            Button("Delete", role: .destructive) { clip.remove(item) }
        }
    }
}
