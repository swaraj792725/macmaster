import SwiftUI

// MARK: - Shared tile pieces

/// The icon image: the captured menu bar pixels when we have them, otherwise the owning app's icon.
struct MenuBarManagerTileGlyph: View {
    let tile: MenuBarManagerTile
    var maxCaptureWidth: CGFloat = 44

    var body: some View {
        // Reading the version makes the glyph redraw when new captures land.
        let _ = MenuBarManager.shared.captureVersion
        if let cap = tile.capture {
            MenuBarManagerCaptureView(capture: cap)
                .frame(height: 20)
                .frame(maxWidth: maxCaptureWidth)
        } else if let icon = tile.appIcon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 20)).foregroundStyle(.tertiary)
        }
    }
}

/// Makes a tile draggable (locked ones stay put).
struct MenuBarManagerTileDrag: ViewModifier {
    let tile: MenuBarManagerTile

    func body(content: Content) -> some View {
        if tile.locked {
            content
        } else {
            content.draggable(tile.payload) {
                MenuBarManagerTileGlyph(tile: tile)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
            }
        }
    }
}

/// Dropping on a tile inserts before it (overflow zone in Dropdown mode only).
struct MenuBarManagerTileReorderDrop: ViewModifier {
    let tile: MenuBarManagerTile
    let enabled: Bool
    let report: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        if enabled && !tile.locked {
            content
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor).frame(width: 2.5)
                        .padding(.vertical, 4).offset(x: -3)
                        .opacity(targeted ? 1 : 0)
                }
                .dropDestination(for: String.self) { items, _ in
                    MenuBarManager.shared.dropTiles(items, into: .overflow, before: tile.id, report: report)
                } isTargeted: { targeted = $0 }
                .animation(.smooth(duration: 0.15), value: targeted)
        } else {
            content
        }
    }
}

// MARK: - Page: the three zones

/// Windows-tray style arranging: drag icons between the menu bar strip, the « panel and the always-hidden zone.
struct MenuBarManagerZonesView: View {
    private let manager = MenuBarManager.shared

    var body: some View {
        let real = manager.zonesAreReal
        let zones = manager.zoneTiles()
        let total = zones.values.reduce(0) { $0 + $1.count }
        let anyLocked = zones.values.contains { $0.contains { $0.locked } }
        VStack(alignment: .leading, spacing: 14) {
            header(real: real)

            if total == 0 {
                if manager.inventoryNeedsAccessibility {
                    EmptyStateView(symbol: "lock.shield", title: "Grant Accessibility to list menu bar icons",
                                   message: "macOS only exposes other apps' menu bar icons through Accessibility. Grant it above, then they appear here.")
                } else {
                    EmptyStateView(symbol: "menubar.arrow.up.rectangle",
                                   title: manager.dropdownScanning ? "Scanning the menu bar…" : "No menu bar icons found",
                                   message: "Icons from other apps will show up here to drag around.")
                }
            } else {
                MenuBarManagerZoneBox(zone: .shown, tiles: zones[.shown] ?? [], real: real)
                MenuBarManagerZoneBox(zone: .overflow, tiles: zones[.overflow] ?? [], real: real)
                if !real || manager.alwaysHiddenEnabled {
                    MenuBarManagerZoneBox(zone: .alwaysHidden, tiles: zones[.alwaysHidden] ?? [], real: real)
                }
            }

            status
            footer(real: real, anyLocked: anyLocked, forced: manager.dropdownNotShowingCount)
        }
        .card(padding: 18)
        .animation(.smooth(duration: 0.25), value: manager.isMoving)
        .animation(.smooth(duration: 0.25), value: manager.statusMessage)
        .task { if !real { await manager.refreshDropdownInventory() } }
        // Event-driven refresh (e.g. after granting Accessibility in System Settings); no timer.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !real { Task { await manager.refreshDropdownInventory(force: true) } }
        }
    }

    private func header(real: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw").foregroundStyle(.secondary)
                    Text("Arrange icons").font(.system(size: 15, weight: .semibold))
                }
                Text(real
                     ? "Drag an icon to another zone. A drop performs a real ⌘-drag in your menu bar, so keep the mouse still until it finishes. Right-click an icon for the same moves as a menu."
                     : "Drag an icon to another zone to choose what the « panel lists. Your real menu bar isn't touched. Right-click an icon for the same moves as a menu.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !real {
                Button {
                    Task { await manager.refreshDropdownInventory(force: true) }
                } label: {
                    Label(manager.dropdownScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.mmSecondary)
                .disabled(manager.dropdownScanning || !manager.isRunning)
            }
        }
    }

    /// Honest progress / failure line for the last drop.
    @ViewBuilder
    private var status: some View {
        if manager.isMoving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Moving the icon with a simulated ⌘-drag. This takes a few seconds, don't touch the mouse.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        } else if let m = manager.statusMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.Palette.orange[1])
                Text(m).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func footer(real: Bool, anyLocked: Bool, forced: Int) -> some View {
        let lines: [String] = [
            real ? nil : "Real icons stay where macOS put them on this version. Icons macOS already pushed out of the bar (behind the notch or dropped) are always in the « panel.",
        ].compactMap { $0 }
        if anyLocked { MenuBarManagerAppleItemsBox() }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

// MARK: - One zone

private struct MenuBarManagerZoneBox: View {
    let zone: MenuBarManagerZone
    let tiles: [MenuBarManagerTile]
    let real: Bool
    private let manager = MenuBarManager.shared
    @State private var targeted = false
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.adaptive(minimum: 68, maximum: 84), spacing: 8, alignment: .top)]

    private var subtitle: String {
        switch zone {
        case .shown: real ? "Visible in the bar right now" : "Icons in your real menu bar"
        case .overflow: real ? "Tucked behind the « toggle" : "Listed in the « panel"
        case .alwaysHidden: real ? "Only Option-click on « reveals these" : "Kept out of the « panel"
        }
    }

    private func report(_ m: String) { manager.statusMessage = m }

    var body: some View {
        let tint = zone.colors[1]
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: SymbolKit.resolve(zone.symbol)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(zone.title).font(.system(size: 13, weight: .semibold))
                Text("\(tiles.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if tiles.isEmpty {
                Text("Drop icons here")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tiles) { t in
                        MenuBarManagerZoneTile(tile: t, real: real)
                            .modifier(MenuBarManagerTileReorderDrop(tile: t, enabled: !real && zone == .overflow, report: report))
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(background(shape: shape, tint: tint))
        .overlay(border(shape: shape, tint: tint))
        .environment(\.colorScheme, zone == .shown ? .dark : scheme)
        .scaleEffect(targeted ? 1.008 : 1)
        .dropDestination(for: String.self) { items, _ in
            manager.dropTiles(items, into: zone, report: report)
        } isTargeted: { targeted = $0 }
        .animation(.smooth(duration: 0.2), value: targeted)
        .animation(.smooth(duration: 0.28), value: tiles.map(\.id))
    }

    @ViewBuilder
    private func background(shape: RoundedRectangle, tint: Color) -> some View {
        ZStack {
            switch zone {
            case .shown:
                shape.fill(LinearGradient(colors: [Color(hex: 0x3A3C46), Color(hex: 0x24262D)], startPoint: .top, endPoint: .bottom))
            case .overflow:
                shape.fill(.regularMaterial)
            case .alwaysHidden:
                shape.fill(Theme.cardFill)
            }
            shape.fill(tint.opacity(targeted ? 0.18 : 0))
        }
    }

    @ViewBuilder
    private func border(shape: RoundedRectangle, tint: Color) -> some View {
        if targeted {
            shape.strokeBorder(tint, lineWidth: 2)
        } else if zone == .alwaysHidden {
            shape.strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        } else {
            shape.strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - One tile

private struct MenuBarManagerZoneTile: View {
    let tile: MenuBarManagerTile
    let real: Bool
    private let manager = MenuBarManager.shared
    private let settings = ControlCenterSettings.shared
    @State private var hover = false

    private var target: AppleItemRedirect.Target? {
        MenuBarManager.appleTarget(name: tile.name, identifier: tile.item?.title ?? tile.entry?.identifier ?? "")
    }
    private var redirected: Bool {
        switch target {
        case .controlCenter: settings.redirectControlCenter
        case .clock: settings.redirectClock
        case nil: false
        }
    }

    var body: some View {
        let busy = real && tile.item.map { manager.busyItemID == $0.id } == true
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hover && !tile.locked ? 0.16 : 0.08))
                MenuBarManagerTileGlyph(tile: tile)
                    .opacity(busy ? 0.35 : 1)
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(width: 56, height: 40)
            .overlay(alignment: .topTrailing) {
                if redirected {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accentColor).padding(4)
                } else if tile.locked {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary).padding(4)
                }
            }
            Text(tile.name).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tile.detail != nil ? Theme.Palette.orange[1] : .primary)
                .lineLimit(1).frame(width: 68)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .scaleEffect(hover && !tile.locked ? 1.04 : 1)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hover)
        .help([tile.name, tile.detail, redirected ? "Click opens MacMaster's \(target == .clock ? "Clock" : "dropdown")" : nil,
               tile.locked ? "Pinned by macOS" : nil].compactMap { $0 }.joined(separator: " · "))
        .modifier(MenuBarManagerTileDrag(tile: tile))
        .contextMenu {
            Button { manager.openTile(tile) } label: { Label("Open Its Menu", systemImage: "cursorarrow.click") }
            if let target {
                Divider()
                Toggle(target == .clock ? "Click Opens MacMaster's Clock" : "Click Opens MacMaster's Dropdown",
                       isOn: MenuBarManagerAppleItemsBox.binding(target))
                Button("Control Center & Clock Settings…") { MainWindow.show(section: .controlcenter) }
            } else if tile.locked {
                Text("Locked by macOS")
            } else {
                Divider()
                ForEach(MenuBarManagerZone.allCases.filter { z in
                    z != tile.zone && (z != .alwaysHidden || !real || manager.alwaysHiddenEnabled)
                }) { z in
                    Button {
                        manager.dropTiles([tile.payload], into: z) { manager.statusMessage = $0 }
                    } label: { Label("Move to \(z.title)", systemImage: SymbolKit.resolve(z.symbol)) }
                }
            }
        }
    }
}

// MARK: - Apple's pinned items

/// Control Center and Clock can't be dragged (macOS pins them), but what a click on them does is ours to choose.
struct MenuBarManagerAppleItemsBox: View {
    @State private var settings = ControlCenterSettings.shared
    @State private var redirect = AppleItemRedirect.shared

    static func binding(_ target: AppleItemRedirect.Target) -> Binding<Bool> {
        let s = ControlCenterSettings.shared
        return Binding(get: { target == .clock ? s.redirectClock : s.redirectControlCenter },
                       set: { if target == .clock { s.redirectClock = $0 } else { s.redirectControlCenter = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Text("Control Center and Clock are pinned by macOS, so they can't be dragged. You can choose what clicking them does:")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Apple's Control Center opens MacMaster's dropdown", isOn: $settings.redirectControlCenter)
            Toggle("Apple's clock opens MacMaster's Clock", isOn: $settings.redirectClock)
            HStack(spacing: 8) {
                if settings.redirectControlCenter || settings.redirectClock {
                    Text(note).font(.caption).foregroundStyle(redirect.status == .active ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("More Settings…") { MainWindow.show(section: .controlcenter) }.buttonStyle(.mmGhost)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var note: String {
        switch redirect.status {
        case .active: "On: MacMaster's own matching icon is hidden. Shift/Option/Command/Control-click reaches Apple's."
        case .needsAccessibility: "Needs Accessibility access (More Settings)."
        case .notFound: "Apple's icon wasn't found in the menu bar yet."
        case .failed: "Couldn't start the click listener (More Settings)."
        case .off: ""
        }
    }
}
