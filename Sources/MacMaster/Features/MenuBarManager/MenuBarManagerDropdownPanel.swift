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
    /// Option-click on the toggle: the always-hidden icons show too.
    var includeAlwaysHidden = false
    /// A ⌘-drag from the bar is over (or heading for) the flyout: highlight it as the drop target.
    var dropTarget = false
    /// The icon ghost being dragged out is over the menu bar (release shows it again).
    var ghostOverBar = false
}

private struct MenuBarManagerDropdownSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The flyout under the menu bar: only the hidden items, in a menu-material strip. Works over full-screen apps and
/// every Space; closes on an outside click, Escape, a Space change or another app coming forward.
@MainActor
final class MenuBarManagerDropdownController {
    static let maxRowWidth: CGFloat = 320

    let model = MenuBarManagerDropdownModel()
    private var panel: MenuBarManagerDropdownNSPanel?
    private var host: NSHostingView<MenuBarManagerDropdownView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var ghost: NSPanel?
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

    /// `anchor` is the toggle's frame in AppKit coordinates. `focus` false (a drag is in progress) keeps the panel from
    /// becoming key.
    func show(anchor: CGRect, on screen: NSScreen, includeAlwaysHidden: Bool = false, focus: Bool = true) {
        hideTask?.cancel()
        self.screen = screen
        anchorX = anchor.midX
        model.includeAlwaysHidden = includeAlwaysHidden
        model.maxListHeight = max(220, (screen.visibleFrame.height - 70) * 0.7)
        if panel == nil { build() }
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        // Always place before showing; an unmeasured panel would sit at the screen origin.
        resize(fit.width > 20 && fit.height > 20 ? fit : CGSize(width: 180, height: 60), force: true)
        if !isVisible {
            model.appeared = false
            panel.orderFrontRegardless()
            if focus { panel.makeKey() }
            installMonitors()
            isVisible = true
            DispatchQueue.main.async { [model] in model.appeared = true }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        endGhost()
        model.appeared = false
        model.dropTarget = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func build() {
        let p = MenuBarManagerDropdownNSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
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

    // MARK: Drag helpers

    /// Pointer inside the flyout itself (not its shadow margin).
    func contains(_ p: NSPoint) -> Bool { frame?.insetBy(dx: 10, dy: 10).contains(p) ?? false }

    /// Pointer in the menu bar strip of some screen.
    func isOverBar(_ p: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(p) && p.y >= $0.frame.maxY - MenuBarManagerGeometry.stripHeight(of: $0) }
    }

    /// A small floating copy of the icon that follows the pointer while it's dragged out of the flyout.
    func beginGhost(_ tile: MenuBarManagerTile) {
        endGhost()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let h = NSHostingView(rootView: MenuBarManagerGhostView(tile: tile, model: model))
        h.layoutSubtreeIfNeeded()
        let fit = h.fittingSize
        p.setContentSize(fit.width > 10 ? fit : CGSize(width: 60, height: 40))
        p.contentView = h
        ghost = p
        moveGhost()
        p.orderFrontRegardless()
    }

    func moveGhost() {
        guard let ghost else { return }
        let m = NSEvent.mouseLocation
        ghost.setFrameOrigin(NSPoint(x: m.x - ghost.frame.width / 2, y: m.y - ghost.frame.height / 2))
        let over = isOverBar(m)
        if model.ghostOverBar != over { model.ghostOverBar = over }
    }

    func endGhost() {
        ghost?.orderOut(nil)
        ghost = nil
        model.ghostOverBar = false
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

private enum MenuBarManagerFlyoutSpace { static let name = "mmFlyout" }

private struct MenuBarManagerFlyoutFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Where a dragged tile would land: a zone and the tile it goes before (nil: at the end).
private struct MenuBarManagerFlyoutTarget: Equatable {
    var zone: MenuBarManagerZone
    var before: String?
}

/// Rows of icons that wrap at `maxWidth`, like a tray overflow.
private struct MenuBarManagerFlowLayout: Layout {
    var maxWidth: CGFloat = MenuBarManagerDropdownController.maxRowWidth
    var spacing: CGFloat = 2

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, right: CGFloat = 0
        var frames: [CGRect] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: sz.width, height: sz.height))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            right = max(right, x - spacing)
        }
        return (frames, CGSize(width: right, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: min(proposal.width ?? maxWidth, maxWidth)).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, width: min(bounds.width, maxWidth))
        for (s, f) in zip(subviews, r.frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// Behind-window menu material: the same blur and tint as a real menu.
private struct MenuBarManagerMenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// An icon at (about) its menu bar size. Captured pixels when we have them, otherwise the app icon.
struct MenuBarManagerFlyoutGlyph: View {
    let tile: MenuBarManagerTile
    static let maxHeight: CGFloat = 26

    var body: some View {
        // Reading the version makes the glyph redraw when new captures land.
        let _ = MenuBarManager.shared.captureVersion
        if let cap = tile.capture {
            let s = cap.image.size
            let k = s.height > Self.maxHeight ? Self.maxHeight / s.height : 1
            MenuBarManagerCaptureView(capture: cap)
                .frame(width: min(max(14, s.width * k), 140), height: s.height * k)
        } else if let icon = tile.appIcon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18).frame(minWidth: 22)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 16)).foregroundStyle(.tertiary).frame(minWidth: 22)
        }
    }
}

/// What follows the pointer while an icon is dragged out. Ringed when releasing would put it back in the bar.
private struct MenuBarManagerGhostView: View {
    let tile: MenuBarManagerTile
    let model: MenuBarManagerDropdownModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        MenuBarManagerFlyoutGlyph(tile: tile)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(shape.fill(.regularMaterial))
            .overlay(shape.strokeBorder(model.ghostOverBar ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: model.ghostOverBar ? 1.5 : 0.5))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(10)
    }
}

/// One icon in the flyout: hover highlight, click opens its menu, drag out (or onto another icon) moves it.
private struct MenuBarManagerFlyoutCell: View {
    let tile: MenuBarManagerTile
    let dragging: Bool
    let markLeading: Bool
    let markTrailing: Bool
    let onDrag: (MenuBarManagerTile, DragGesture.Value, Bool) -> Void
    private let manager = MenuBarManager.shared
    @State private var hover = false

    var body: some View {
        let lit = hover && !dragging
        MenuBarManagerFlyoutGlyph(tile: tile)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(lit ? 0.14 : 0)))
            .opacity(dragging ? 0.3 : (tile.forcedOverflow ? 0.85 : 1))
            .overlay(alignment: .leading) { mark.offset(x: -1.5).opacity(markLeading ? 1 : 0) }
            .overlay(alignment: .trailing) { mark.offset(x: 1.5).opacity(markTrailing ? 1 : 0) }
            .contentShape(Rectangle())
            .background(GeometryReader { g in
                Color.clear.preference(key: MenuBarManagerFlyoutFramesKey.self,
                                       value: [tile.id: g.frame(in: .named(MenuBarManagerFlyoutSpace.name))])
            })
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: lit)
            .onTapGesture {
                guard let e = tile.entry else { return }
                manager.activateDropdownEntry(e, kind: NSEvent.modifierFlags.contains(.option) ? .option : .primary)
            }
            .modifier(FlyoutDrag(tile: tile, onDrag: onDrag))
            .help([tile.name, tile.detail].compactMap { $0 }.joined(separator: " · "))
            .contextMenu {
                if let e = tile.entry {
                    Button("Open") { manager.activateDropdownEntry(e) }
                    Button("Open Alternate Menu") { manager.activateDropdownEntry(e, kind: .secondary) }
                }
                if !tile.locked {
                    Divider()
                    Button("Show in Menu Bar") { move(.shown) }.disabled(tile.forcedOverflow)
                    if tile.zone == .alwaysHidden { Button("Move to « Panel") { move(.overflow) } }
                    else { Button("Always Hide") { move(.alwaysHidden) } }
                }
            }
    }

    private var mark: some View {
        Capsule().fill(Color.accentColor).frame(width: 2.5).padding(.vertical, 3)
    }

    private func move(_ zone: MenuBarManagerZone) {
        withAnimation(.smooth(duration: 0.25)) {
            _ = manager.dropTiles([tile.payload], into: zone) { manager.showDropdownMessage($0) }
        }
    }

    private struct FlyoutDrag: ViewModifier {
        let tile: MenuBarManagerTile
        let onDrag: (MenuBarManagerTile, DragGesture.Value, Bool) -> Void
        func body(content: Content) -> some View {
            if tile.locked {
                content
            } else {
                content.gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(MenuBarManagerFlyoutSpace.name))
                    .onChanged { onDrag(tile, $0, false) }
                    .onEnded { onDrag(tile, $0, true) })
            }
        }
    }
}

/// Windows-tray flyout: only the hidden icons, in a menu-material strip under the menu bar. Click opens an icon,
/// drag one out onto the bar to show it again, ⌘-drag one from the bar onto the flyout to hide it.
struct MenuBarManagerDropdownView: View {
    let model: MenuBarManagerDropdownModel
    let manager: MenuBarManager
    let onSize: (CGSize) -> Void
    @State private var contentSize: CGSize = .zero
    @State private var frames: [String: CGRect] = [:]
    @State private var dragID: String?
    @State private var target: MenuBarManagerFlyoutTarget?

    var body: some View {
        let zones = manager.zoneTiles(includeSystem: MenuBarManagerPrefs.showSystemItems)
        let overflow = zones[.overflow] ?? []
        let always = model.includeAlwaysHidden ? (zones[.alwaysHidden] ?? []) : []
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            if !Permissions.isGranted(.accessibility) {
                note("Accessibility is needed to list and open menu bar items.", button: "Grant") {
                    Permissions.request(.accessibility)
                }
            } else if let msg = manager.dropdownMessage {
                note(msg, button: nil) {}
            }
            if overflow.isEmpty && always.isEmpty {
                Text(manager.dropdownScanning ? "Looking for menu bar items..." : "Nothing hidden. ⌘-drag a menu bar icon here.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 7)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        flow(overflow)
                        if !always.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill").font(.system(size: 8.5))
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
                            }
                            .foregroundStyle(.tertiary).padding(.horizontal, 4).padding(.vertical, 2)
                            flow(always)
                        }
                    }
                    .coordinateSpace(name: MenuBarManagerFlyoutSpace.name)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentSize = g.size }.onChange(of: g.size) { _, s in contentSize = s }
                    })
                }
                .scrollIndicators(.never)
                .frame(width: contentSize.width > 0 ? contentSize.width : nil,
                       height: contentSize.height > 0 ? min(contentSize.height, model.maxListHeight) : nil)
                .onPreferenceChange(MenuBarManagerFlyoutFramesKey.self) { frames = $0 }
            }
            if manager.hidingUnsupported && !(overflow.isEmpty && always.isEmpty) {
                // macOS 27: apps can't move other apps' icons, so a dropped icon stays in the bar too.
                note("macOS keeps these in the menu bar too. Hide them in System Settings › Menu Bar.", button: "Open") {
                    manager.dropdown.hide()
                    manager.openSystemMenuBarSettings()
                }
            }
            if !Permissions.isGranted(.screenRecording) && !(overflow.isEmpty && always.isEmpty) {
                Text("Grant Screen Recording to show the real icons.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.bottom, 2)
            }
        }
        .padding(4)
        .fixedSize()
        .background(MenuBarManagerMenuMaterial().clipShape(shape))
        .overlay(shape.fill(Color.accentColor.opacity(model.dropTarget ? 0.14 : 0)))
        .overlay(shape.strokeBorder(model.dropTarget ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: model.dropTarget ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .contextMenu {
            Button("Rescan") { Task { await manager.refreshDropdownInventory(force: true) } }
            Button("Menu Bar Settings...") {
                manager.dropdown.hide()
                model.onSettings?()
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: MenuBarManagerDropdownSizeKey.self, value: g.size)
        })
        .onPreferenceChange(MenuBarManagerDropdownSizeKey.self) { onSize($0) }
        .padding(10) // room for the window shadow
        .scaleEffect(model.appeared ? 1 : 0.94, anchor: .top)
        .opacity(model.appeared ? 1 : 0)
        .offset(y: model.appeared ? 0 : -8)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.appeared)
        .animation(.smooth(duration: 0.2), value: overflow.map(\.id))
        .animation(.smooth(duration: 0.2), value: always.map(\.id))
        .animation(.easeOut(duration: 0.15), value: model.dropTarget)
    }

    private func flow(_ tiles: [MenuBarManagerTile]) -> some View {
        MenuBarManagerFlowLayout {
            ForEach(tiles) { t in
                MenuBarManagerFlyoutCell(
                    tile: t, dragging: dragID == t.id,
                    markLeading: target?.before == t.id && target?.zone == t.zone,
                    markTrailing: target?.before == nil && target?.zone == t.zone && target != nil && tiles.last?.id == t.id,
                    onDrag: drag)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }

    private func note(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 260, alignment: .leading)
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    // MARK: Drag out / reorder

    /// Insertion spot under `p` (flyout space): before/after the icon there, else the end of the row it's in.
    private func landing(at p: CGPoint, tiles: [MenuBarManagerTile]) -> MenuBarManagerFlyoutTarget? {
        if let i = tiles.firstIndex(where: { frames[$0.id]?.insetBy(dx: -2, dy: -2).contains(p) ?? false }) {
            let t = tiles[i], f = frames[t.id]!
            if p.x < f.midX { return .init(zone: t.zone, before: t.id) }
            let same = tiles.suffix(from: i + 1).first { $0.zone == t.zone }
            return .init(zone: t.zone, before: same?.id)
        }
        let ahTop = tiles.filter { $0.zone == .alwaysHidden }.compactMap { frames[$0.id]?.minY }.min()
        return .init(zone: ahTop.map { p.y >= $0 - 4 } == true ? .alwaysHidden : .overflow, before: nil)
    }

    private func drag(_ tile: MenuBarManagerTile, _ v: DragGesture.Value, _ ended: Bool) {
        let ctl = manager.dropdown
        let zones = manager.zoneTiles(includeSystem: MenuBarManagerPrefs.showSystemItems)
        let tiles = (zones[.overflow] ?? []) + (model.includeAlwaysHidden ? (zones[.alwaysHidden] ?? []) : [])
        let mouse = NSEvent.mouseLocation
        if !ended {
            if dragID == nil { dragID = tile.id; ctl.beginGhost(tile) }
            ctl.moveGhost()
            let next = ctl.contains(mouse) ? landing(at: v.location, tiles: tiles) : nil
            if next != target { target = next }
            return
        }
        defer { dragID = nil; target = nil; ctl.endGhost() }
        guard dragID != nil else { return }
        let report: (String) -> Void = { manager.showDropdownMessage($0) }
        withAnimation(.smooth(duration: 0.25)) {
            if ctl.contains(mouse) {
                guard let t = landing(at: v.location, tiles: tiles) else { return }
                _ = manager.dropTiles([tile.payload], into: t.zone, before: t.before, report: report)
            } else if ctl.isOverBar(mouse) {
                _ = manager.dropTiles([tile.payload], into: .shown, report: report)
            }
        }
    }
}
