import SwiftUI

/// Full page: status hero, arrange illustration, inventory, then the settings groups.
struct MenuBarManagerView: View {
    private let manager = MenuBarManager.shared
    @AppStorage(MenuBarManagerPrefs.enabledKey) private var enabled = true

    var body: some View {
        Page {
            PageHeader(title: "Menu Bar Manager",
                       subtitle: "Hide, reorder and reveal menu bar icons",
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
                MenuBarManagerHero()
                MenuBarManagerPermissionNotes()
                MenuBarManagerArrangeCard()
                MenuBarManagerInventory()
                MenuBarManagerBehaviourGroup()
                MenuBarManagerDropdownGroup()
                MenuBarManagerSpacingGroup()
                MenuBarManagerAppearanceGroup()
            } else {
                EmptyStateView(symbol: "menubar.rectangle", title: "Menu Bar Manager is off",
                               message: "Turn it on to get a toggle and dividers in the menu bar and to hide icons you rarely need.")
                    .card()
            }
        }
        .animation(.smooth(duration: 0.3), value: enabled)
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
            if let m = manager.statusMessage {
                note("info.circle.fill", m, color: .secondary)
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
    var body: some View {
        VStack(spacing: 10) {
            PermissionBanner(permission: .accessibility,
                             reason: "Needed to move icons between sections and to open hidden icons' menus from the dropdown bar.")
            PermissionBanner(permission: .screenRecording,
                             reason: "Needed to show the real icon images in the dropdown bar. Without it you get app icons and names.")
        }
    }
}

// MARK: - Arrange illustration

private struct MenuBarManagerArrangeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text("Arrange").font(.system(size: 15, weight: .semibold))
            }

            HStack(alignment: .top, spacing: 0) {
                column("Always hidden", color: Theme.Palette.purple[1], symbols: ["lock.fill", "bolt.horizontal", "cloud"])
                dividerColumn(dashed: true)
                column("Hidden", color: Theme.Palette.orange[1], symbols: ["wifi", "speaker.wave.2", "moon"])
                dividerColumn(dashed: false)
                chevronColumn
                column("Visible", color: Theme.Palette.green[1], symbols: ["battery.100", "magnifyingglass", "clock"])
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x3A3C46), Color(hex: 0x24262D)], startPoint: .top, endPoint: .bottom)))
            .environment(\.colorScheme, .dark)

            VStack(alignment: .leading, spacing: 4) {
                step("1", "Hold ⌘ and drag an icon in the menu bar across the | divider to hide it.")
                step("2", "Drag it back to the right of the | to show it again.")
                step("3", "Click the arrow to collapse. Hidden icons slide out of the bar; Option-click reveals the always-hidden ones.")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .card()
    }

    private func column(_ label: String, color: Color, symbols: [String]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(symbols, id: \.self) { s in
                    Image(systemName: SymbolKit.resolve(s))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.35)))
                }
            }
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func dividerColumn(dashed: Bool) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                ForEach(0..<(dashed ? 4 : 1), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                        .fill(.white.opacity(0.75))
                        .frame(width: 1.5, height: dashed ? 4 : 22)
                }
            }
            .frame(height: 22)
            Text(" ").font(.system(size: 10))
        }
        .padding(.horizontal, 6)
    }

    private var chevronColumn: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
            Text("Toggle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 6)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Inventory

private struct MenuBarManagerInventory: View {
    private let manager = MenuBarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            ForEach(MenuBarManagerSection.allCases) { section in
                if manager.inventoryNeedsAccessibility && manager.items.isEmpty { EmptyView() }
                else if section == .alwaysHidden && !manager.alwaysHiddenEnabled { EmptyView() }
                else { sectionView(section) }
            }
            if manager.items.isEmpty {
                if manager.inventoryNeedsAccessibility {
                    EmptyStateView(symbol: "lock.shield", title: "Grant Accessibility to list icons",
                                   message: "macOS 26 and later only expose menu bar icons through Accessibility. Grant it above, then icons appear here.")
                        .card()
                } else {
                    EmptyStateView(symbol: "menubar.arrow.up.rectangle", title: "Scanning the menu bar…",
                                   message: "Icons from other apps will be listed here.")
                        .card()
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MenuBarManagerSection) -> some View {
        let rows = manager.items(in: section)
        GroupedSection("\(section.title) · \(rows.count)", symbol: section.symbol, footer: footer(section)) {
            if rows.isEmpty {
                Text(emptyText(section)).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { MenuBarManagerItemRow(item: $0) }
            }
        }
    }

    private func emptyText(_ s: MenuBarManagerSection) -> String {
        switch s {
        case .visible: "No icons are in the visible section."
        case .hidden: "Nothing hidden yet. ⌘-drag an icon to the left of the | divider, or use the row menu."
        case .alwaysHidden: "Nothing here. Always-hidden icons only show in the dropdown bar or with Option-click."
        }
    }

    private func footer(_ s: MenuBarManagerSection) -> String? {
        guard s == .visible else { return nil }
        return "Use a row's menu to move an icon. Moving simulates a ⌘-drag and needs Accessibility."
    }
}

private struct MenuBarManagerItemRow: View {
    let item: MenuBarManagerItem
    private let manager = MenuBarManager.shared

    var body: some View {
        let busy = manager.busyItemID == item.id
        HStack(spacing: 12) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.body).lineLimit(1)
                if item.isClipped {
                    Text("Behind the notch").font(.caption).foregroundStyle(Theme.Palette.red[1])
                } else if item.isOffscreen && item.section == .visible {
                    Text("Off the bar").font(.caption).foregroundStyle(Theme.Palette.red[1])
                } else if !item.title.isEmpty, item.title != item.displayName {
                    Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            preview
            if busy { ProgressView().controlSize(.small) }
            Menu {
                ForEach(MenuBarManagerSection.allCases) { target in
                    if target != .alwaysHidden || manager.alwaysHiddenEnabled {
                        Button {
                            Task { await manager.move(item, to: target) }
                        } label: {
                            Label("Move to \(target.title)", systemImage: target.symbol)
                        }
                        .disabled(target == item.section)
                    }
                }
                Divider()
                Button { Task { await manager.activate(item) } } label: {
                    Label("Open Its Menu", systemImage: "cursorarrow.click")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(manager.isMoving || manager.busyItemID != nil)
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder
    private var preview: some View {
        let _ = manager.captureVersion
        if let cap = MenuBarManagerCapture.shared.image(for: item) {
            Image(nsImage: cap.image)
                .renderingMode(cap.isMonochrome ? .template : .original)
                .resizable().scaledToFit()
                .foregroundStyle(.primary)
                .frame(height: 20)
                .frame(maxWidth: 70)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
