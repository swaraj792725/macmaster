import SwiftUI
import AppKit
import ImageIO

/// Menu bar icon for clipboard history. Click opens a popover with search, pins and quick copy/paste.
@MainActor
final class ToolsClipboardMenuBar: NSObject, NSPopoverDelegate {
    static let shared = ToolsClipboardMenuBar()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var previousApp: NSRunningApplication?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Creates or removes the status item to match the setting. Idempotent.
    func update() {
        let show = ToolsClipboard.shared.showInMenuBar
        if show, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let b = it.button {
                let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard history")
                img?.isTemplate = true
                b.image = img
                b.target = self
                b.action = #selector(toggle)
            }
            item = it
        } else if !show, let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.contentViewController = NSHostingController(rootView: ToolsClipboardPopoverView(bar: self))
        popover.showFromStatusItem(button)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func close() { popover.performClose(nil) }

    // MARK: Actions

    func copy(_ item: ToolsClipboardItem) {
        ToolsClipboard.shared.copyBack(item)
        close()
    }

    /// Copies, then sends ⌘V to the app that was frontmost (needs Accessibility; otherwise just copies).
    func paste(_ item: ToolsClipboardItem) {
        ToolsClipboard.shared.copyBack(item)
        close()
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        let target = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                target?.activate(options: [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.sendCommandV() }
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Thumbnails

@MainActor
private enum ToolsClipboardThumbs {
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

// MARK: - Popover view

private struct ToolsClipboardPopoverView: View {
    let bar: ToolsClipboardMenuBar
    private let clip = ToolsClipboard.shared
    @State private var query = ""
    @State private var selected: UUID?
    @FocusState private var searchFocused: Bool

    private var visible: [ToolsClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? clip.items : clip.items.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    var body: some View {
        let list = visible
        VStack(spacing: 0) {
            searchBar(list)
            Divider()
            if !clip.isEnabled { enableBanner }
            if list.isEmpty {
                ToolsEmptyHint(symbol: clip.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                               text: clip.items.isEmpty ? (clip.isEnabled ? "Copy something to see it here." : "Turn on recording to keep your copy history.") : "No matches.")
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let pinned = list.filter(\.pinned), recent = list.filter { !$0.pinned }
                            if !pinned.isEmpty {
                                sectionTitle("Pinned")
                                ForEach(pinned) { row($0) }
                            }
                            if !recent.isEmpty {
                                sectionTitle("Recent")
                                ForEach(recent) { row($0) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selected) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 340, height: 460)
        .task { searchFocused = true }
        .onChange(of: query) { _, _ in selected = visible.first?.id }
    }

    // MARK: Pieces

    private func searchBar(_ list: [ToolsClipboardItem]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clipboard", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                .onSubmit {
                    guard let it = list.first(where: { $0.id == selected }) ?? list.first else { return }
                    if NSEvent.modifierFlags.contains(.option) { bar.paste(it) } else { bar.copy(it) }
                }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func move(_ delta: Int, in list: [ToolsClipboardItem]) {
        guard !list.isEmpty else { return }
        let cur = list.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : list.count)
        selected = list[max(0, min(list.count - 1, cur + delta))].id
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private var enableBanner: some View {
        HStack {
            Text("History is off").font(.callout)
            Spacer()
            Toggle("Record", isOn: Binding(get: { clip.isEnabled }, set: { clip.isEnabled = $0 }))
                .toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if clip.isEnabled {
                Toggle("Record", isOn: Binding(get: { clip.isEnabled }, set: { clip.isEnabled = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            Spacer()
            Text("⌥ click pastes").font(.caption2).foregroundStyle(.tertiary)
            Button("Clear history") { clip.clearUnpinned() }
                .buttonStyle(.mmGhost)
                .disabled(clip.items.allSatisfy(\.pinned))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func row(_ item: ToolsClipboardItem) -> some View {
        ToolsClipboardPopoverRow(item: item, selected: selected == item.id, bar: bar)
            .id(item.id)
    }
}

private struct ToolsClipboardPopoverRow: View {
    let item: ToolsClipboardItem
    let selected: Bool
    let bar: ToolsClipboardMenuBar
    private let clip = ToolsClipboard.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            preview
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 8) {
                    Button { bar.paste(item) } label: { Image(systemName: "arrow.down.doc") }
                        .help(AXIsProcessTrusted() ? "Paste into the frontmost app" : "Copy (grant Accessibility to paste)")
                    Button { clip.remove(item) } label: { Image(systemName: "trash") }.help("Delete")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button { clip.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.pinned ? Color.orange : Color.secondary.opacity(hover ? 1 : 0.4))
            }
            .buttonStyle(.plain).help(item.pinned ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.12 : (hover ? 0.07 : 0))))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { bar.paste(item) } else { bar.copy(item) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text(let s):
            Text(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
                .font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let d):
            HStack(spacing: 8) {
                if let img = ToolsClipboardThumbs.image(for: item, data: d) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 52, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text("Image").font(.callout).foregroundStyle(.secondary)
            }
        case .files(let urls):
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "")).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")).font(.callout).lineLimit(1)
                    if urls.count > 2 { Text("+ \(urls.count - 2) more").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
