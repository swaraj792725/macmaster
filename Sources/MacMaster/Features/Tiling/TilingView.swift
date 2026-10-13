import AppKit
import SwiftUI

/// Root screen of the Window Tiling feature.
struct TilingView: View {
    private let engine = TilingEngine.shared
    private let shortcuts = TilingShortcutStore.shared

    @AppStorage(TilingSettings.Key.enabled) private var enabled = true
    @AppStorage(TilingSettings.Key.snapEnabled) private var snapEnabled = true
    @AppStorage(TilingSettings.Key.snapHalves) private var snapHalves = true
    @AppStorage(TilingSettings.Key.snapTop) private var snapTop = true
    @AppStorage(TilingSettings.Key.snapCorners) private var snapCorners = true
    @AppStorage(TilingSettings.Key.snapThirds) private var snapThirds = true
    @AppStorage(TilingSettings.Key.sensitivity) private var sensitivity = 12.0
    @AppStorage(TilingSettings.Key.restoreOnDrag) private var restoreOnDrag = true
    @AppStorage(TilingSettings.Key.gap) private var gap = 0.0
    @AppStorage(TilingSettings.Key.snapLayouts) private var snapLayouts = true
    @AppStorage(TilingSettings.Key.hotkeys) private var hotkeys = true
    @AppStorage(TilingSettings.Key.modDrag) private var modDrag = true
    @AppStorage(TilingSettings.Key.modDragModifier) private var modifierRaw = TilingModifierChoice.ctrlCmd.rawValue
    @AppStorage(TilingSettings.Key.focusFollows) private var focusFollows = false
    @AppStorage(TilingSettings.Key.focusDelay) private var focusDelay = 0.35
    @AppStorage(TilingSettings.Key.titleDoubleClick) private var titleDoubleClick = false

    @State private var hoveredLayout: TilingLayout?
    @State private var nativeOn = false
    @State private var newName = ""

    var body: some View {
        Page(jump: enabled ? [PageJump("tiling.snap", "Drag to Snap"), PageJump("tiling.layouts", "Snap Layouts"),
                              PageJump("tiling.keys", "Shortcuts"), PageJump("tiling.modifier", "Modifier Drag"),
                              PageJump("tiling.extras", "Extras"), PageJump("tiling.saved", "Saved Layouts")] : []) {
            PageHeader(title: "Window Tiling",
                       subtitle: "Snap, tile and move windows with the mouse or the keyboard",
                       symbol: "rectangle.split.2x2.fill", colors: Theme.Palette.windows) {
                HStack(spacing: 10) {
                    if let s = engine.status { StatusPill(text: s, color: .green).transition(.opacity) }
                    Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
            }

            PermissionBanner(permission: .accessibility,
                             reason: "Window Tiling moves and resizes other apps' windows through the Accessibility API.")

            if enabled {
                if nativeOn && snapEnabled { nativeNotice }
                hero
                dragToSnap.searchAnchor("tiling.snap")
                snapLayoutsGroup.searchAnchor("tiling.layouts")
                keyboardGroup.searchAnchor("tiling.keys")
                modifierGroup.searchAnchor("tiling.modifier")
                extrasGroup.searchAnchor("tiling.extras")
                savedLayoutsGroup.searchAnchor("tiling.saved")
            } else {
                EmptyStateView(symbol: "rectangle.split.2x2", title: "Window Tiling is off",
                               message: "Turn it on to snap windows to screen edges, use layout shortcuts and more.")
            }
        }
        .animation(.smooth(duration: 0.25), value: enabled)
        .animation(.smooth(duration: 0.25), value: engine.savedLayouts)
        .animation(.smooth(duration: 0.25), value: engine.status)
        .onAppear {
            TilingSettings.registerDefaults()
            nativeOn = TilingNative.anyEnabled
        }
    }

    // MARK: Native tiling notice

    private var nativeNotice: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill", colors: Theme.Palette.orange, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS tiling is also on").font(.headline)
                Text("Dragging to an edge would be snapped twice. Turn off macOS's own edge tiling, or keep it and disable drag-to-snap here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { TilingNative.openSettings() }.buttonStyle(.mmSecondary)
            Button("Turn Off macOS Tiling") {
                Task {
                    await TilingNative.disable()
                    nativeOn = TilingNative.anyEnabled
                }
            }
            .buttonStyle(.mmPrimary)
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFF9F0A).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Color(hex: 0xFF9F0A).opacity(0.28), lineWidth: 0.5))
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            nativeOn = TilingNative.anyEnabled
        }
    }

    // MARK: Hero

    private var hero: some View {
        let target = engine.targetApplication()?.localizedName
        return VStack(spacing: 14) {
            TilingMiniScreen(onHoverChange: { hoveredLayout = $0 }, onApply: { engine.apply($0) })
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(hoveredLayout?.title ?? "Hover a zone")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .contentTransition(.interpolate)
                Text(target.map { "Click to snap the front window of \($0)" } ?? "Click to snap the last window you used")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .animation(.smooth(duration: 0.15), value: hoveredLayout)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 56, maximum: 80), spacing: 10), count: 8), spacing: 10) {
                ForEach(TilingLayout.gridOrder) { layout in TilingHeroButton(layout: layout) }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)

            HStack {
                Button { engine.apply(.restore) } label: { Label("Restore Window", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.mmSecondary)
                Button { engine.apply(.almostMaximize) } label: { Label("Almost Maximize", systemImage: "rectangle.inset.filled") }
                    .buttonStyle(.mmSecondary)
                Button { engine.apply(.nextDisplay) } label: { Label("Next Display", systemImage: "display") }
                    .buttonStyle(.mmSecondary)
            }
        }
        .card(padding: 20, kind: .glass, radius: Theme.Radius.hero)
    }

    // MARK: Drag to snap

    private var dragToSnap: some View {
        GroupedSection("Drag to Snap", symbol: "arrow.up.left.and.arrow.down.right",
                       footer: "Drag a window's title bar to a screen edge: sides make halves, the top maximizes, corners make quarters and the bottom edge makes thirds. A highlight previews where the window will land.") {
            SettingsRow(title: "Snap windows by dragging", subtitle: "Show a preview and snap on release",
                        symbol: "cursorarrow.motionlines", colors: Theme.Palette.blue) {
                Toggle("", isOn: $snapEnabled).toggleStyle(.switch).labelsHidden()
            }
            if snapEnabled {
                HStack {
                    Spacer()
                    TilingZoneMap().frame(width: 260)
                    Spacer()
                }
                .padding(.vertical, 4)
                SettingsRow(title: "Left & right edges", subtitle: "Half screen") {
                    Toggle("", isOn: $snapHalves).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Top edge", subtitle: "Maximize (like Ubuntu)") {
                    Toggle("", isOn: $snapTop).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Corners", subtitle: "Quarter screen") {
                    Toggle("", isOn: $snapCorners).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Bottom edge", subtitle: "Left, middle and right thirds") {
                    Toggle("", isOn: $snapThirds).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Zone sensitivity", subtitle: "How close to the edge the cursor must be") {
                    sliderValue($sensitivity, range: 4...60, step: 1, unit: "px")
                }
                SettingsRow(title: "Restore size when dragged away",
                            subtitle: "A snapped window gets its previous size back") {
                    Toggle("", isOn: $restoreOnDrag).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsRow(title: "Window gap", subtitle: "Space around and between tiled windows") {
                sliderValue($gap, range: 0...20, step: 1, unit: "px")
            }
        }
    }

    private func sliderValue(_ value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value.snapped(step), in: range).frame(width: 150)
            Text("\(Int(value.wrappedValue)) \(unit)")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    // MARK: Snap layouts

    private var snapLayoutsGroup: some View {
        GroupedSection("Snap Layouts", symbol: "square.grid.3x2.fill",
                       footer: "Rest the pointer on a window's green button for half a second to pick a layout, Windows 11 style. The picker opens to the right of the button so it stays clear of macOS's own menu.") {
            SettingsRow(title: "Show layouts on green button hover", subtitle: "Halves, thirds, two-thirds, quarters, maximize and center",
                        symbol: "square.grid.3x2.fill", colors: Theme.Palette.teal) {
                Toggle("", isOn: $snapLayouts).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    // MARK: Keyboard

    private var keyboardGroup: some View {
        GroupedSection("Keyboard Shortcuts", symbol: "keyboard",
                       footer: "Press a half shortcut repeatedly to cycle 1/2, 2/3 and 1/3. Click a field and type a new combination; Delete clears it.") {
            SettingsRow(title: "Global shortcuts", subtitle: "Work in any app, no permission needed to register",
                        symbol: "command", colors: Theme.Palette.indigo) {
                Toggle("", isOn: $hotkeys).toggleStyle(.switch).labelsHidden()
            }
            if hotkeys {
                ForEach(TilingShortcutStore.listed) { layout in
                    SettingsRow(title: layout.title) {
                        TilingShortcutRecorder(layout: layout)
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { shortcuts.reset() }
                        .buttonStyle(.mmSecondary)
                        .disabled(!shortcuts.isCustomized)
                }
            }
        }
    }

    // MARK: Modifier drag

    private var modifierGroup: some View {
        let mod = TilingModifierChoice(rawValue: modifierRaw) ?? .ctrlCmd
        return GroupedSection("Modifier Drag", symbol: "hand.draw.fill",
                              footer: "Hold \(mod.shortTitle) and left-drag anywhere in a window to move it. Right-drag to resize from the nearest corner. The clicks are only intercepted while the modifiers are held.") {
            SettingsRow(title: "Move and resize with a modifier", subtitle: "Linux-style window dragging",
                        symbol: "hand.draw.fill", colors: Theme.Palette.orange) {
                Toggle("", isOn: $modDrag).toggleStyle(.switch).labelsHidden()
            }
            if modDrag {
                SettingsRow(title: "Modifier keys") {
                    Picker("", selection: $modifierRaw) {
                        ForEach(TilingModifierChoice.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    // MARK: Extras

    private var extrasGroup: some View {
        GroupedSection("Extras", symbol: "sparkles",
                       footer: "Double-click maximize works best when System Settings › Desktop & Dock › \"Double-click a window's title bar to\" is set to Do Nothing.") {
            SettingsRow(title: "Focus follows mouse", subtitle: "Raise the window under the pointer after a short pause",
                        symbol: "cursorarrow.rays", colors: Theme.Palette.pink) {
                Toggle("", isOn: $focusFollows).toggleStyle(.switch).labelsHidden()
            }
            if focusFollows {
                SettingsRow(title: "Delay") {
                    HStack(spacing: 8) {
                        Slider(value: $focusDelay.snapped(0.05), in: 0.1...1.5).frame(width: 150)
                        Text(String(format: "%.2f s", focusDelay))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            }
            SettingsRow(title: "Double-click title bar to maximize", subtitle: "Double-click again to restore",
                        symbol: "rectangle.topthird.inset.filled", colors: Theme.Palette.purple) {
                Toggle("", isOn: $titleDoubleClick).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Tile all windows", subtitle: "Arrange the visible windows on this screen in a grid",
                        symbol: "square.grid.2x2.fill", colors: Theme.Palette.green) {
                Button("Tile All") { engine.tileAll() }.buttonStyle(.mmPrimary)
            }
        }
    }

    // MARK: Saved layouts

    private var savedLayoutsGroup: some View {
        GroupedSection("Saved Layouts", symbol: "tray.full.fill",
                       footer: "Saves every open window's app, title and position. Restore moves matching windows back; apps that are not running are skipped.") {
            HStack(spacing: 10) {
                TextField("Layout name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save Current Layout", action: save).buttonStyle(.mmPrimary)
            }
            if engine.savedLayouts.isEmpty {
                Text("No saved layouts yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(engine.savedLayouts) { layout in
                    SettingsRow(title: layout.name,
                                subtitle: "\(layout.windows.count) windows · \(layout.date.formatted(date: .abbreviated, time: .shortened))") {
                        HStack(spacing: 8) {
                            Button("Restore") { engine.restoreLayout(layout) }.buttonStyle(.mmSecondary)
                            Button { engine.deleteLayout(layout) } label: { Image(systemName: "trash") }
                                .buttonStyle(.mmGhost)
                                .help("Delete layout")
                        }
                    }
                }
            }
        }
    }

    private func save() {
        engine.saveCurrentLayout(name: newName)
        newName = ""
    }
}

private struct TilingHeroButton: View {
    let layout: TilingLayout
    @State private var hover = false

    var body: some View {
        Button { TilingEngine.shared.apply(layout) } label: {
            VStack(spacing: 5) {
                TilingLayoutDiagram(layout: layout, highlighted: hover)
                    .frame(height: 36)
                Text(layout.shortTitle).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(layout.title)
        .animation(.smooth(duration: 0.12), value: hover)
    }
}
