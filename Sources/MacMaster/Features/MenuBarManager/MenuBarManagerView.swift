import SwiftUI

/// Full page: status hero, arrange illustration, inventory, then the settings groups.
struct MenuBarManagerView: View {
    private let manager = MenuBarManager.shared
    @AppStorage(MenuBarManagerPrefs.enabledKey) private var enabled = true
    @AppStorage(MenuBarManagerPrefs.modeKey) private var modeRaw = MenuBarManagerMode.dropdown.rawValue

    private var mode: MenuBarManagerMode { MenuBarManagerMode(rawValue: modeRaw) ?? .dropdown }

    var body: some View {
        Page {
            PageHeader(title: "Menu Bar Manager",
                       subtitle: mode == .dropdown ? "List and open every menu bar icon from one dropdown"
                                                   : "Hide, reorder and reveal menu bar icons",
                       symbol: "menubar.rectangle",
                       colors: [Color(hex: 0x7D7AFF), Color(hex: 0x30B0C7)]) {
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: enabled) { _, on in
                        if on { manager.start() } else { manager.stop() }
                    }
            }

            if enabled {
                MenuBarManagerModePicker(modeRaw: $modeRaw)
                if mode == .dropdown {
                    MenuBarManagerDropdownHero()
                    MenuBarManagerPermissionNotes(dropdownMode: true)
                    MenuBarManagerZonesView()
                    MenuBarManagerDropdownBehaviourGroup()
                    MenuBarManagerSpacingGroup()
                    MenuBarManagerAppearanceGroup(classic: false)
                } else {
                    MenuBarManagerHero()
                    MenuBarManagerPermissionNotes(dropdownMode: false)
                    MenuBarManagerZonesView()
                    MenuBarManagerBehaviourGroup()
                    MenuBarManagerDropdownGroup()
                    MenuBarManagerSpacingGroup()
                    MenuBarManagerAppearanceGroup(classic: true)
                }
            } else {
                EmptyStateView(symbol: "menubar.rectangle", title: "Menu Bar Manager is off",
                               message: "Turn it on to get a toggle and dividers in the menu bar and to hide icons you rarely need.")
                    .card()
            }
        }
        .animation(.smooth(duration: 0.3), value: enabled)
        .animation(.smooth(duration: 0.3), value: modeRaw)
        .onAppear { manager.beginObserving() }
        .onDisappear { manager.endObserving() }
    }
}

// MARK: - Hero

private struct MenuBarManagerHero: View {
    private let manager = MenuBarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 28) {
                counter("Visible", manager.visibleCount, Theme.Palette.green[1], unknown: manager.inventoryNeedsAccessibility)
                counter("Hidden", manager.hiddenCount, Theme.Palette.orange[1], unknown: manager.inventoryNeedsAccessibility)
                if manager.notchClippedCount > 0 {
                    counter("Behind notch", manager.notchClippedCount, Theme.Palette.red[1])
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer(minLength: 12)
                Button {
                    let opt = NSEvent.modifierFlags.contains(.option)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        if manager.isCollapsed { manager.expand(includeAlwaysHidden: opt) } else {
                            manager.clearHidingUnsupported() // explicit press re-tests
                            manager.collapse()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: manager.isCollapsed ? "chevron.left.2" : "chevron.right.2")
                            .font(.system(size: 15, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(manager.isCollapsed ? "Expand" : "Collapse")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.mmPrimary(tint: manager.isCollapsed ? Theme.Palette.blue[1] : Theme.Palette.indigo[1]))
                .disabled(!manager.isRunning)
                .help("Option-click Expand to include always-hidden icons")
            }

            if manager.inventoryNeedsAccessibility {
                note("lock.shield.fill", "Grant Accessibility to list icons. Collapsing and expanding still work without it.",
                     color: Theme.Palette.orange[1])
            }
            if let r = manager.blockedReason, r != MenuBarManager.unsupportedMessage {
                note("exclamationmark.triangle.fill", r, color: Theme.Palette.orange[1])
            }
            if manager.hidingUnsupported {
                HStack(alignment: .center, spacing: 12) {
                    note("exclamationmark.triangle.fill", MenuBarManager.unsupportedMessage, color: Theme.Palette.orange[1])
                    Spacer(minLength: 8)
                    Button("Open Menu Bar Settings") { manager.openSystemMenuBarSettings() }
                        .buttonStyle(.mmSecondary)
                }
            }
            if manager.notchClippedCount > 0 {
                note("macbook", "\(manager.notchClippedCount) icon\(manager.notchClippedCount == 1 ? " is" : "s are") hidden behind the notch. Hide a few icons or remove some to make room.",
                     color: Theme.Palette.red[1])
            }
        }
        .card(padding: 18, kind: .glass, radius: Theme.Radius.hero)
        .animation(.smooth(duration: 0.3), value: manager.notchClippedCount)
        .animation(.smooth(duration: 0.3), value: manager.blockedReason)
    }

    private func counter(_ title: String, _ value: Int, _ color: Color, unknown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(unknown ? "–" : "\(value)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: value)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func note(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Permissions

private struct MenuBarManagerPermissionNotes: View {
    let dropdownMode: Bool

    var body: some View {
        VStack(spacing: 10) {
            PermissionBanner(permission: .accessibility,
                             reason: dropdownMode
                                 ? "Needed to list every menu bar item (macOS only exposes them this way) and to open an item's menu from the dropdown."
                                 : "Needed to move icons between sections and to open hidden icons' menus from the dropdown bar.")
            PermissionBanner(permission: .screenRecording,
                             reason: dropdownMode
                                 ? "Needed to show each item's real icon image. Without it the dropdown shows app icons and names."
                                 : "Needed to show the real icon images in the dropdown bar. Without it you get app icons and names.")
        }
    }
}


// MARK: - Mode picker

/// Two tiles at the top of the page, one line of explanation each. Writing the pref restarts the manager in that mode.
private struct MenuBarManagerModePicker: View {
    @Binding var modeRaw: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(MenuBarManagerMode.allCases) { m in tile(m) }
        }
    }

    private func tile(_ m: MenuBarManagerMode) -> some View {
        let selected = modeRaw == m.rawValue
        return Button {
            withAnimation(.smooth(duration: 0.25)) { modeRaw = m.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: m.symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(m.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dropdown mode: hero

private struct MenuBarManagerDropdownHero: View {
    private let manager = MenuBarManager.shared

    var body: some View {
        let needsAX = manager.inventoryNeedsAccessibility
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 28) {
                counter("In the bar", manager.dropdownVisibleCount, Theme.Palette.green[1], unknown: needsAX)
                counter("Not showing", manager.dropdownNotShowingCount, Theme.Palette.orange[1], unknown: needsAX)
                counter("In the « panel", manager.dropdownOverflowCount, Theme.Palette.indigo[1])
                Spacer(minLength: 12)
                Button {
                    manager.openDropdown()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold))
                        Text("Open Dropdown").font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.mmPrimary(tint: Theme.Palette.indigo[1]))
                .disabled(!manager.isRunning || manager.runningMode != .dropdown)
            }
            if needsAX {
                note("lock.shield.fill", "Grant Accessibility to list menu bar items.", color: Theme.Palette.orange[1])
            }
            if manager.dropdownNotShowingCount > 0 {
                note("macbook", "\(manager.dropdownNotShowingCount) item\(manager.dropdownNotShowingCount == 1 ? " is" : "s are") not showing in your menu bar (behind the notch or dropped by macOS). They are still listed in the dropdown and can be opened from there.",
                     color: Theme.Palette.orange[1])
            }
            note("hand.raised.fill", "Nothing in your menu bar is hidden, resized or moved by this mode.", color: Theme.Palette.green[1])
        }
        .card(padding: 18, kind: .glass, radius: Theme.Radius.hero)
    }

    private func counter(_ title: String, _ value: Int, _ color: Color, unknown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(unknown ? "–" : "\(value)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
                .contentTransition(.numericText()).animation(.smooth, value: value)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func note(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
