import AppKit
import SwiftUI

// MARK: - Window

/// Key-capable (so Escape works) but non-activating: opening the list never steals focus from the front app.
private final class MenuBarManagerDropdownNSPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
@Observable
final class MenuBarManagerDropdownModel {
    var appeared = false
    var maxListHeight: CGFloat = 480
    var onSettings: (() -> Void)?
}

private struct MenuBarManagerDropdownSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Floating glass list of every menu bar item. Works over full-screen apps and every Space; closes on an outside
/// click, Escape, a Space change or another app coming forward.
@MainActor
final class MenuBarManagerDropdownController {
    static let width: CGFloat = 340

    let model = MenuBarManagerDropdownModel()
    private var panel: MenuBarManagerDropdownNSPanel?
    private var host: NSHostingView<MenuBarManagerDropdownView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var anchorX: CGFloat = 0
    private var screen: NSScreen?
    private var hideTask: Task<Void, Never>?
    private(set) var isVisible = false
    var frame: NSRect? { isVisible ? panel?.frame : nil }
    /// Clicks in this window (our toggle) don't dismiss; the toggle's own action handles them.
    weak var ignoredWindow: NSWindow?
    var onSettings: (() -> Void)? {
        get { model.onSettings }
        set { model.onSettings = newValue }
    }

    /// `anchor` is the toggle's frame in AppKit coordinates.
    func show(anchor: CGRect, on screen: NSScreen) {
        hideTask?.cancel()
        self.screen = screen
        anchorX = anchor.midX
        model.maxListHeight = max(220, (screen.visibleFrame.height - 70) * 0.7)
        if panel == nil { build() }
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        // Always place before showing; an unmeasured panel would sit at the screen origin.
        resize(fit.width > 20 && fit.height > 20 ? fit : CGSize(width: Self.width + 20, height: 140), force: true)
        if !isVisible {
            model.appeared = false
            panel.orderFrontRegardless()
            panel.makeKey()
            installMonitors()
            isVisible = true
            DispatchQueue.main.async { [model] in model.appeared = true }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        model.appeared = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func build() {
        let p = MenuBarManagerDropdownNSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + 20, height: 140),
                                              styleMask: [.borderless, .nonactivatingPanel],
                                              backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // SwiftUI content draws its own
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Over full-screen apps and on whichever Space is active.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.onEscape = { [weak self] in self?.hide() }
        let view = MenuBarManagerDropdownView(model: model, manager: MenuBarManager.shared) { [weak self] size in
            self?.resize(CGSize(width: size.width + 20, height: size.height + 20))
        }
        let h = NSHostingView(rootView: view)
        h.sizingOptions = []
        p.contentView = h
        panel = p
        host = h
    }

    private func resize(_ size: CGSize, force: Bool = false) {
        guard let panel, let screen, size.width > 20, size.height > 20 else { return }
        if !force && panel.frame.size == size { return }
        let top = screen.frame.maxY - MenuBarManagerGeometry.stripHeight(of: screen) + 4
        let minX = screen.frame.minX + 4, maxX = screen.frame.maxX - size.width - 4
        let x = min(max(anchorX - size.width / 2, minX), max(minX, maxX))
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide(); return nil }
                return event
            }
            if event.window !== self.panel, event.window !== self.ignoredWindow { self.hide() }
            return event
        }
        // Escape while another app is active (the panel is non-activating, so it may not be key).
        keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.hide() } }
        }
        let ws = NSWorkspace.shared.notificationCenter
        let me = ProcessInfo.processInfo.processIdentifier
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != me else { return }
            Task { @MainActor in self?.hide() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        })
    }

    private func removeMonitors() {
        for m in [globalMonitor, localMonitor, keyGlobalMonitor] { if let m { NSEvent.removeMonitor(m) } }
        globalMonitor = nil; localMonitor = nil; keyGlobalMonitor = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
    }
}

// MARK: - Views

/// One icon in the tray grid: hover highlight, click opens its menu, drag moves it between the two sections.
struct MenuBarManagerFlyoutCell: View {
    let tile: MenuBarManagerTile
    let onHover: (Bool) -> Void
    private let manager = MenuBarManager.shared
    @State private var hover = false

    var body: some View {
        let shown = tile.zone == .shown
        Button {
            guard let e = tile.entry else { return }
            manager.activateDropdownEntry(e, kind: NSEvent.modifierFlags.contains(.option) ? .option : .primary)
        } label: {
            MenuBarManagerTileGlyph(tile: tile, maxCaptureWidth: 46)
                .opacity(shown || !tile.forcedOverflow ? 1 : 0.85)
                .frame(width: 54, height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.14 : 0)))
                .scaleEffect(hover ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover = h
            onHover(h)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hover)
        .help([tile.name, tile.detail].compactMap { $0 }.joined(separator: " · "))
        .modifier(MenuBarManagerTileDrag(tile: tile))
        .modifier(MenuBarManagerTileReorderDrop(tile: tile, enabled: tile.zone == .overflow) { manager.showDropdownMessage($0) })
        .contextMenu {
            if let e = tile.entry {
                Button("Open") { manager.activateDropdownEntry(e) }
                Button("Open Alternate Menu") { manager.activateDropdownEntry(e, kind: .secondary) }
            }
            if !tile.locked {
                Divider()
                if tile.zone == .overflow {
                    Button("Show in Menu Bar") { move(.shown) }
                        .disabled(tile.forcedOverflow)
                } else {
                    Button("Move to « Panel") { move(.overflow) }
                }
                Button("Hide from Panel") { move(.alwaysHidden) }
            }
        }
    }

    private func move(_ zone: MenuBarManagerZone) {
        withAnimation(.smooth(duration: 0.25)) {
            manager.dropTiles([tile.payload], into: zone) { manager.showDropdownMessage($0) }
        }
    }
}

/// Windows-tray flyout: a grid of icons in an overflow section on top, the icons still in the bar below.
struct MenuBarManagerDropdownView: View {
    let model: MenuBarManagerDropdownModel
    let manager: MenuBarManager
    let onSize: (CGSize) -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var hoverName: String?
    @State private var targeted: MenuBarManagerZone?

    private let columns = [GridItem(.adaptive(minimum: 54, maximum: 60), spacing: 4, alignment: .top)]

    var body: some View {
        let zones = manager.zoneTiles(includeSystem: MenuBarManagerPrefs.showSystemItems)
        let overflow = zones[.overflow] ?? [], shown = zones[.shown] ?? []
        let isEmpty = overflow.isEmpty && shown.isEmpty
        VStack(spacing: 0) {
            header
            if !Permissions.isGranted(.accessibility) {
                banner("Accessibility is needed to list and open menu bar items.", button: "Grant") {
                    Permissions.request(.accessibility)
                }
            } else if let msg = manager.dropdownMessage {
                banner(msg, button: nil, action: {})
            }
            if isEmpty {
                Text(manager.dropdownScanning ? "Looking for menu bar items..." : "No menu bar items found.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        grid(.overflow, "Overflow", overflow, hint: "Drag icons here to tuck them away")
                        grid(.shown, "In the menu bar", shown, hint: "Drag an icon here to show it in the bar")
                    }
                    .padding(.horizontal, 8).padding(.bottom, 6)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in contentHeight = h }
                    })
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(contentHeight, 40), model.maxListHeight))
                caption
            }
            if !Permissions.isGranted(.screenRecording) && !isEmpty {
                Text("Grant Screen Recording to show the real icons.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 6)
            }
        }
        .frame(width: MenuBarManagerDropdownController.width)
        .modifier(MenuBarManagerGlassModifier(radius: 16))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .background(GeometryReader { g in
            Color.clear.preference(key: MenuBarManagerDropdownSizeKey.self, value: g.size)
        })
        .onPreferenceChange(MenuBarManagerDropdownSizeKey.self) { onSize($0) }
        .padding(10) // room for the window shadow
        .scaleEffect(model.appeared ? 1 : 0.92, anchor: .top)
        .opacity(model.appeared ? 1 : 0)
        .offset(y: model.appeared ? 0 : -10)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.appeared)
        .animation(.smooth(duration: 0.25), value: overflow.map(\.id))
        .animation(.smooth(duration: 0.25), value: shown.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Menu Bar").font(.system(size: 12, weight: .semibold))
            if manager.dropdownScanning { ProgressView().controlSize(.mini) }
            Spacer()
            Button {
                Task { await manager.refreshDropdownInventory(force: true) }
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan")
            Button {
                manager.dropdown.hide()
                model.onSettings?()
            } label: { Image(systemName: "gearshape") }
                .help("Menu bar settings")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
    }

    /// Hovered icon's name, or a hint.
    private var caption: some View {
        Text(hoverName ?? "Click to open · drag between sections · right-click for more")
            .font(.system(size: 10.5, weight: hoverName == nil ? .regular : .medium))
            .foregroundStyle(hoverName == nil ? .tertiary : .secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 2)
    }

    private func banner(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func grid(_ zone: MenuBarManagerZone, _ title: String, _ tiles: [MenuBarManagerTile], hint: String) -> some View {
        let on = targeted == zone
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            if tiles.isEmpty {
                Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(tiles) { t in
                        MenuBarManagerFlyoutCell(tile: t) { h in hoverName = h ? t.name : (hoverName == t.name ? nil : hoverName) }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(6)
        .background(shape.fill(Color.primary.opacity(on ? 0.12 : 0.04)))
        .overlay(shape.strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .dropDestination(for: String.self) { items, _ in
            manager.dropTiles(items, into: zone) { manager.showDropdownMessage($0) }
        } isTargeted: { t in
            if t { targeted = zone } else if targeted == zone { targeted = nil }
        }
        .animation(.smooth(duration: 0.18), value: on)
    }
}
