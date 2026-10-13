import SwiftUI

// MARK: - Behaviour

struct MenuBarManagerBehaviourGroup: View {
    private let manager = MenuBarManager.shared
    @AppStorage(MenuBarManagerPrefs.autoRehideKey) private var autoRehide = MenuBarManagerPrefs.defaultAutoRehide
    @AppStorage(MenuBarManagerPrefs.rehideOnClickKey) private var rehideOnClick = true
    @AppStorage(MenuBarManagerPrefs.rehideOnAppChangeKey) private var rehideOnApp = true
    @AppStorage(MenuBarManagerPrefs.showOnHoverKey) private var showOnHover = false
    @AppStorage(MenuBarManagerPrefs.showOnScrollKey) private var showOnScroll = false
    @AppStorage(MenuBarManagerPrefs.optionClickKey) private var optionClick = true
    @AppStorage(MenuBarManagerPrefs.alwaysHiddenEnabledKey) private var alwaysHidden = true
    @AppStorage(MenuBarManagerPrefs.hotkeyEnabledKey) private var hotkeyEnabled = true
    @State private var hotKey = MenuBarManagerHotKey.stored

    var body: some View {
        GroupedSection("Behaviour", symbol: "slider.horizontal.3",
                       footer: "Hover and scroll triggers watch the pointer globally while the manager is on.") {
            SettingsRow(title: "Auto-rehide", subtitle: "Collapse again after the bar was expanded",
                        symbol: "timer", colors: Theme.Palette.orange) {
                Picker("", selection: $autoRehide) {
                    Text("Never").tag(0)
                    ForEach([3, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
            toggleRow("Rehide when clicking elsewhere", "Collapse after you click outside the menu bar",
                      "cursorarrow.click.2", Theme.Palette.blue, $rehideOnClick)
            toggleRow("Rehide when the frontmost app changes", nil,
                      "square.on.square", Theme.Palette.indigo, $rehideOnApp)
            toggleRow("Show on hover", "Hover the empty menu bar area or the toggle",
                      "cursorarrow.motionlines", Theme.Palette.teal, $showOnHover)
            toggleRow("Show on scroll or swipe", "Scroll over the menu bar to reveal hidden icons",
                      "arrow.up.and.down.and.arrow.left.and.right", Theme.Palette.mint, $showOnScroll)
            toggleRow("Always-hidden section", "A second divider for icons shown only in the dropdown bar",
                      "lock.fill", Theme.Palette.purple, $alwaysHidden)
            toggleRow("Option-click reveals always-hidden", nil,
                      "option", Theme.Palette.gray, $optionClick)
            SettingsRow(title: "Global shortcut", subtitle: hotkeySubtitle,
                        symbol: "keyboard", colors: Theme.Palette.pink) {
                HStack(spacing: 10) {
                    MenuBarManagerHotKeyField(hotKey: $hotKey)
                        .disabled(!hotkeyEnabled)
                        .opacity(hotkeyEnabled ? 1 : 0.5)
                    Toggle("", isOn: $hotkeyEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onChange(of: hotKey) { _, new in new.save() }
    }

    private var hotkeySubtitle: String {
        if let s = manager.hotKeyStatus, hotkeyEnabled { return s }
        return "Toggle hidden icons from anywhere"
    }

    private func toggleRow(_ title: String, _ subtitle: String?, _ symbol: String, _ colors: [Color],
                           _ binding: Binding<Bool>) -> some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, colors: colors) {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }
}

// MARK: - Dropdown mode settings

struct MenuBarManagerDropdownBehaviourGroup: View {
    private let manager = MenuBarManager.shared
    @AppStorage(MenuBarManagerPrefs.showSystemItemsKey) private var showSystem = false
    @AppStorage(MenuBarManagerPrefs.hotkeyEnabledKey) private var hotkeyEnabled = true
    @State private var hotKey = MenuBarManagerHotKey.stored

    var body: some View {
        GroupedSection("Dropdown", symbol: "rectangle.topthird.inset.filled",
                       footer: "Click the menu bar toggle or use the shortcut to open the list. Click an item to open its menu; right-click for its alternate menu or hold ⌥ to forward an option-click. Esc or a click elsewhere closes it.") {
            SettingsRow(title: "Include macOS items", subtitle: "Wi-Fi, Clock, Control Center and other system items",
                        symbol: "apple.logo", colors: Theme.Palette.gray) {
                Toggle("", isOn: $showSystem).toggleStyle(.switch).labelsHidden()
                    .onChange(of: showSystem) { _, _ in Task { await manager.refreshDropdownInventory(force: true) } }
            }
            SettingsRow(title: "Global shortcut", subtitle: hotkeySubtitle,
                        symbol: "keyboard", colors: Theme.Palette.pink) {
                HStack(spacing: 10) {
                    MenuBarManagerHotKeyField(hotKey: $hotKey)
                        .disabled(!hotkeyEnabled)
                        .opacity(hotkeyEnabled ? 1 : 0.5)
                    Toggle("", isOn: $hotkeyEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onChange(of: hotKey) { _, new in new.save() }
    }

    private var hotkeySubtitle: String {
        if let s = manager.hotKeyStatus, hotkeyEnabled { return s }
        return "Open the dropdown from anywhere, including over full-screen apps"
    }
}

// MARK: - Dropdown bar

struct MenuBarManagerDropdownGroup: View {
    private let manager = MenuBarManager.shared
    @AppStorage(MenuBarManagerPrefs.dropdownKey) private var dropdown = true

    var body: some View {
        GroupedSection("Dropdown bar", symbol: "rectangle.topthird.inset.filled",
                       footer: "When on, clicking the arrow while collapsed shows hidden icons in a floating bar under the menu bar instead of expanding the real one. Click an icon there to open its menu.") {
            SettingsRow(title: "Use dropdown bar", subtitle: "Option-click also lists always-hidden icons",
                        symbol: "rectangle.topthird.inset.filled", colors: Theme.Palette.blue) {
                Toggle("", isOn: $dropdown).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Preview", symbol: "eye", colors: Theme.Palette.teal) {
                Button("Show Dropdown Bar") {
                    manager.showDropdown(includeAlwaysHidden: false)
                }
                .buttonStyle(.mmSecondary)
                .disabled(!manager.isRunning)
            }
        }
    }
}

// MARK: - Spacing

struct MenuBarManagerSpacingGroup: View {
    @State private var spacing: Double = Double(MenuBarManagerSpacing.systemDefault)
    @State private var padding: Double = Double(MenuBarManagerSpacing.systemDefault)
    @State private var isCustom = false
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        GroupedSection("Spacing", symbol: "arrow.left.and.right",
                       footer: "Tighter spacing fits more icons before the notch clips them. Apps pick the change up when relaunched, or after you log out. macOS default is 16 for both.") {
            SettingsRow(title: "Item spacing", subtitle: isCustom ? "Custom" : "System default",
                        symbol: "arrow.left.and.right", colors: Theme.Palette.indigo) {
                slider($spacing)
            }
            SettingsRow(title: "Selection padding", symbol: "rectangle.inset.filled", colors: Theme.Palette.teal) {
                slider($padding)
            }
            SettingsRow(title: "Apply", subtitle: note, symbol: "checkmark.circle", colors: Theme.Palette.green) {
                HStack(spacing: 8) {
                    Button("Reset") { Task { await reset() } }.buttonStyle(.mmSecondary)
                    Button("Apply") { Task { await apply() } }.buttonStyle(.mmPrimary)
                }
                .disabled(busy)
            }
            SettingsRow(title: "Restart menu bar services", subtitle: "Relaunches SystemUIServer and Control Center",
                        symbol: "arrow.clockwise", colors: Theme.Palette.orange) {
                Button("Restart…") {
                    Task {
                        if await MenuBarManagerSpacing.confirmAndRelaunch() { note = "Menu bar services restarted." }
                    }
                }
                .buttonStyle(.mmGhost)
                .disabled(busy)
            }
        }
        .task { await load() }
    }

    private func slider(_ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Slider(value: value.snapped(1), in: 0...20).frame(width: 170)
            Text("\(Int(value.wrappedValue))")
                .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func load() async {
        let s = await MenuBarManagerSpacing.read(MenuBarManagerSpacing.spacingKey)
        let p = await MenuBarManagerSpacing.read(MenuBarManagerSpacing.paddingKey)
        spacing = Double(s ?? MenuBarManagerSpacing.systemDefault)
        padding = Double(p ?? MenuBarManagerSpacing.systemDefault)
        isCustom = s != nil || p != nil
    }

    private func apply() async {
        busy = true; defer { busy = false }
        let ok = await MenuBarManagerSpacing.write(spacing: Int(spacing), padding: Int(padding))
        isCustom = ok
        note = ok ? "Saved. Relaunch apps or log out to see it." : "Couldn't write the setting."
    }

    private func reset() async {
        busy = true; defer { busy = false }
        await MenuBarManagerSpacing.reset()
        spacing = Double(MenuBarManagerSpacing.systemDefault)
        padding = Double(MenuBarManagerSpacing.systemDefault)
        isCustom = false
        note = "Reset to the system default. Relaunch apps or log out."
    }
}

// MARK: - Appearance

struct MenuBarManagerAppearanceGroup: View {
    /// Classic has a divider glyph; Dropdown mode has no divider at all.
    var classic = true
    @AppStorage(MenuBarManagerPrefs.glyphKey) private var glyphRaw = MenuBarManagerGlyph.chevron.rawValue
    @AppStorage(MenuBarManagerPrefs.showDividerKey) private var showDivider = true

    var body: some View {
        GroupedSection("Appearance", symbol: "paintbrush") {
            SettingsRow(title: "Toggle glyph", subtitle: "What the menu bar toggle looks like",
                        symbol: "chevron.left.circle", colors: Theme.Palette.indigo) {
                HStack(spacing: 8) {
                    ForEach(MenuBarManagerGlyph.allCases) { g in
                        glyphButton(g)
                    }
                }
            }
            if classic {
                SettingsRow(title: "Show divider glyph", subtitle: "The thin | between hidden and visible icons",
                            symbol: "line.diagonal", colors: Theme.Palette.gray) {
                    Toggle("", isOn: $showDivider).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private func glyphButton(_ g: MenuBarManagerGlyph) -> some View {
        let selected = glyphRaw == g.rawValue
        return Button { withAnimation(.smooth(duration: 0.2)) { glyphRaw = g.rawValue } } label: {
            VStack(spacing: 3) {
                Group {
                    if g == .logo {
                        Image(nsImage: MenuBarIconRenderer.logoImage(size: 15)).renderingMode(.template)
                    } else {
                        Image(systemName: g == .chevron && !classic ? "chevron.down" : g.symbol)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(height: 18)
                Text(g.title).font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 62, height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick toggle tile

/// Compact ~150x64 tile for the menu bar Control Center: "Hide Icons", on/off, hidden count.
struct MenuBarManagerQuickToggle: View {
    private let manager = MenuBarManager.shared
    @State private var hover = false

    var body: some View {
        let dropdownMode = MenuBarManagerPrefs.mode == .dropdown
        let on = manager.isRunning && (dropdownMode ? manager.dropdown.isVisible : manager.isCollapsed)
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if !manager.isRunning {
                    MenuBarManagerPrefs.defaults.set(true, forKey: MenuBarManagerPrefs.enabledKey)
                    manager.start()
                } else if dropdownMode {
                    // Let the popover this tile lives in close first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { manager.openDropdown() }
                } else {
                    manager.toggle()
                }
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(on ? Theme.Palette.indigo[1] : Color.primary.opacity(0.13))
                    Image(systemName: dropdownMode ? "rectangle.topthird.inset.filled" : (on ? "eye.slash.fill" : "eye.slash"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dropdownMode ? "Menu Bar Items" : "Hide Icons").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(dropdownMode ? dropdownSubtitle : subtitle(on: on)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 150, height: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .modifier(MenuBarManagerGlassModifier(radius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
        .help(dropdownMode ? "List every menu bar item" : "Collapse or expand hidden menu bar icons")
    }

    private var dropdownSubtitle: String {
        guard manager.isRunning else { return "Off" }
        let n = manager.dropdownEntries.count
        return n > 0 ? Fmt.count(n, "item") : "Open list"
    }

    private func subtitle(on: Bool) -> String {
        guard manager.isRunning else { return "Off" }
        let n = manager.hiddenCount
        return (on ? "On" : "Off") + (n > 0 ? " · \(n) hidden" : "")
    }
}
