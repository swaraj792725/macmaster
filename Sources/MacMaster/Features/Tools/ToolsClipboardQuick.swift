import SwiftUI
import AppKit
import Observation

// MARK: - Model

@MainActor @Observable
final class ToolsClipboardQuickModel {
    var query = ""
    var selected: UUID?
    @ObservationIgnored var onChoose: ((ToolsClipboardItem, Bool) -> Void)?

    /// Pinned first, then recent, narrowed by the search text.
    var visible: [ToolsClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = ToolsClipboard.shared.items
        let list = q.isEmpty ? all : all.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
        return Array((list.filter(\.pinned) + list.filter { !$0.pinned }).prefix(200))
    }

    var selectedIndex: Int? { visible.firstIndex { $0.id == selected } }

    func resetSelection() { selected = visible.first?.id }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let cur = selectedIndex ?? (delta > 0 ? -1 : list.count)
        selected = list[max(0, min(list.count - 1, cur + delta))].id
    }

    func chooseSelected(plain: Bool) {
        let list = visible
        guard let item = list.first(where: { $0.id == selected }) ?? list.first else { return }
        onChoose?(item, plain)
    }

    func choose(index: Int, plain: Bool) {
        let list = visible
        guard list.indices.contains(index) else { return }
        onChoose?(list[index], plain)
    }

    func togglePinSelected() {
        guard let i = selectedIndex else { return }
        ToolsClipboard.shared.togglePin(visible[i])
    }

    func deleteSelected() {
        let list = visible
        guard let i = selectedIndex else { return }
        ToolsClipboard.shared.remove(list[i])
        let rest = visible
        selected = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
    }
}

// MARK: - Panel controller

private final class ToolsClipboardQuickWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Floating, searchable clipboard history opened by a global shortcut. Does not activate MacMaster,
/// so the app you were typing in stays in front and receives the paste.
@MainActor
final class ToolsClipboardQuickPanel: NSObject, NSWindowDelegate {
    static let shared = ToolsClipboardQuickPanel()
    private static let size = NSSize(width: 400, height: 460)

    private var panel: ToolsClipboardQuickWindow?
    private var model = ToolsClipboardQuickModel()
    private var target: NSRunningApplication?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? close() : show() }

    func show() {
        // Whatever is in front now gets the paste.
        target = NSWorkspace.shared.frontmostApplication
        let m = ToolsClipboardQuickModel()
        m.onChoose = { [weak self] item, plain in self?.choose(item, plain: plain) }
        m.resetSelection()
        model = m

        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: ToolsClipboardQuickView(model: m))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        p.setFrame(NSRect(origin: Self.origin(for: Self.size), size: Self.size), display: false)
        p.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> ToolsClipboardQuickWindow {
        let p = ToolsClipboardQuickWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        return p
    }

    /// Top-left of the panel just below the cursor, kept fully on the screen the cursor is on.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return NSPoint(x: mouse.x, y: mouse.y - size.height) }
        var x = mouse.x - 24
        var y = mouse.y - size.height - 8
        x = max(vis.minX + 8, min(x, vis.maxX - size.width - 8))
        if y < vis.minY + 8 { y = min(mouse.y + 8, vis.maxY - size.height - 8) }   // no room below: open above the cursor
        y = max(vis.minY + 8, min(y, vis.maxY - size.height - 8))
        return NSPoint(x: x, y: y)
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // MARK: Input

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let ev = e
            let consumed = MainActor.assumeIsolated { self?.handle(ev) ?? false }
            return consumed ? nil : e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil; clickMonitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let panel, e.window === panel else { return false }
        // Let an input method finish composing before we treat ⏎ / ⌫ as commands.
        if let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch e.keyCode {
        case 53: close(); return true
        case 125 where mods.isEmpty: model.move(1); return true
        case 126 where mods.isEmpty: model.move(-1); return true
        case 36, 76: model.chooseSelected(plain: mods.contains(.option)); return true
        case 51, 117:
            if model.query.isEmpty || mods.contains(.command) { model.deleteSelected(); return true }
        default: break
        }
        if mods == .command, let c = e.charactersIgnoringModifiers {
            if let n = Int(c), (1...9).contains(n) { model.choose(index: n - 1, plain: false); return true }
            if c == "p" { model.togglePinSelected(); return true }
        }
        if mods == [.command, .option], let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
            model.choose(index: n - 1, plain: true); return true
        }
        return false
    }

    private func choose(_ item: ToolsClipboardItem, plain: Bool) {
        let app = target
        close()
        ToolsClipboard.shared.paste(item, plain: plain ? true : nil, into: app)
    }
}

// MARK: - View

private struct ToolsClipboardQuickView: View {
    @Bindable var model: ToolsClipboardQuickModel
    private let clip = ToolsClipboard.shared
    @FocusState private var focused: Bool

    var body: some View {
        let list = model.visible
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                if !clip.isEnabled { StatusPill(text: "Recording off", color: .orange) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if list.isEmpty {
                ToolsEmptyHint(symbol: clip.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                               text: clip.items.isEmpty
                               ? (clip.isEnabled ? "Copy something to see it here." : "Turn on recording in Tools › Clipboard History.")
                               : "No matches.")
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                                ToolsClipboardQuickRow(item: item, index: idx, selected: model.selected == item.id)
                                    .id(item.id)
                                    .onTapGesture { model.onChoose?(item, false) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selected) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("⏎ paste   ⌥⏎ plain   ⌘1–9 quick pick   ⌘P pin   ⌫ delete")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 400, height: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.query) { _, _ in model.resetSelection() }
    }
}

private struct ToolsClipboardQuickRow: View {
    let item: ToolsClipboardItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ToolsClipboardPreview(item: item, lines: 2, thumb: CGSize(width: 46, height: 34))
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
            ToolsClipboardMeta(item: item)
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).frame(width: 22)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(selected ? 0.22 : 0)))
        .contentShape(Rectangle())
    }
}
