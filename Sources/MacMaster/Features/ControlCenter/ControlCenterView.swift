import SwiftUI
import AppKit

/// Settings page for the Control Center: the MacMaster menu bar dropdown IS the Control Center.
struct ControlCenterView: View {
    @State private var settings = ControlCenterSettings.shared
    @State private var redirect = AppleItemRedirect.shared
    @State private var hider = AppleItemHider.shared
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

    var body: some View {
        Page {
            PageHeader(title: "Control Center",
                       subtitle: "The MacMaster dropdown is your Control Center: tiles, brightness, sound, stats and more in one place.",
                       symbol: "switch.2", colors: Theme.Palette.indigo)
            menuBarCard
            iconPicker
            tilesSection
            replaceSection
        }
    }

    // MARK: Menu bar

    private var menuBarCard: some View {
        HStack(spacing: 14) {
            Image(systemName: settings.icon.symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Extra Control Center icon").font(.headline)
                Text(settings.showInMenuBar ? "A second icon that opens the same dropdown."
                                            : "Optional. The MacMaster icon (or Apple's Control Center icon, redirected below) already opens it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.showInMenuBar).toggleStyle(.switch).labelsHidden().controlSize(.large)
        }
        .card(kind: .glass, radius: Theme.Radius.hero)
    }

    private var iconPicker: some View {
        GroupedSection("Extra icon glyph", symbol: "star.square", footer: "Glyph for the optional extra icon. It follows light and dark automatically.") {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ControlCenterIcon.allCases) { icon in
                    let selected = settings.icon == icon
                    Button { settings.icon = icon } label: {
                        VStack(spacing: 6) {
                            Image(systemName: icon.symbol).font(.system(size: 17, weight: .medium))
                                .frame(width: 44, height: 28)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(icon.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
                        }
                        .padding(8).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(icon.title)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Tiles

    private var tilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupedSection("Layout", symbol: "square.grid.2x2",
                           footer: "Open the dropdown and press the edit button to drag tiles around, or set the order, size and visibility here.") {
                SettingsRow(title: "Preset", subtitle: "Start from a ready-made layout.", symbol: "rectangle.3.group", colors: Theme.Palette.indigo) {
                    Menu {
                        ForEach(ControlCenterPreset.allCases) { p in
                            Button { settings.apply(p) } label: { Label(p.title, systemImage: p.symbol) }
                        }
                    } label: { Text("Choose") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                SettingsRow(title: "Reset layout", subtitle: "Back to the default tiles, order and sizes.", symbol: "arrow.counterclockwise", colors: Theme.Palette.gray) {
                    Button("Reset") { settings.resetLayout() }.buttonStyle(.mmSecondary)
                }
            }
            GroupedSection("Tiles", symbol: "square.grid.2x2",
                           footer: "Tiles for hardware your Mac doesn't have are hidden automatically. Now Playing stays empty if macOS withholds playback info from apps.") {
                ForEach(settings.order) { tile in
                    SettingsRow(title: tile.title, subtitle: tile.blurb, symbol: tile.symbol, colors: tile.colors) {
                        HStack(spacing: 8) {
                            if tile.sizes.count > 1 {
                                Picker("", selection: Binding(get: { settings.size(tile) }, set: { settings.setSize(tile, $0) })) {
                                    ForEach(tile.sizes) { Text("\($0.title) \($0.detail)").tag($0) }
                                }
                                .labelsHidden().pickerStyle(.menu).fixedSize()
                            }
                            Button { settings.moveUp(tile) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.mmGhost).help("Move up")
                            Button { settings.moveDown(tile) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.mmGhost).help("Move down")
                            Toggle("", isOn: Binding(get: { settings.isVisible(tile) }, set: { settings.setVisible(tile, $0) }))
                                .toggleStyle(.switch).labelsHidden()
                        }
                    }
                }
            }
            GroupedSection("Focus shortcut", symbol: "moon.fill",
                           footer: "macOS has no public Do Not Disturb switch. Create a Shortcut that toggles a Focus, then type its name here. Leave empty to open Focus settings.") {
                SettingsRow(title: "Shortcut name") {
                    TextField("e.g. Toggle Do Not Disturb", text: $settings.focusShortcut)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
        }
    }

    // MARK: Replace Apple's Control Center

    private var replaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Replace Apple's icons", symbol: "switch.2")
            Text("macOS doesn't let apps remove Apple's menu bar icons. Redirect makes a click on Apple's icon open MacMaster's dropdown instead (Apple's icon stays, but does nothing). Or try hiding the icon.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.redirectControlCenter || settings.redirectClock {
                PermissionBanner(permission: .accessibility,
                                 reason: "Click redirect needs Accessibility to find Apple's icons and catch the click.")
            }
            redirectSection
            hideSection
            modulesSection
        }
        .onAppear { redirect.update(); hider.refreshState() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if redirect.status == .needsAccessibility { redirect.update() }
        }
    }

    private var redirectSection: some View {
        GroupedSection("Redirect clicks", symbol: "cursorarrow.click.2",
                       footer: "Hold Shift, Option, Command or Control while clicking to reach Apple's original. Apple's icon stays in the menu bar; the click opens MacMaster instead. To see what it does: log stream --predicate 'subsystem == \"com.macmaster.app\" AND category == \"redirect\"'") {
            SettingsRow(title: "Status", subtitle: statusDetail, symbol: statusSymbol, colors: statusColors) {
                HStack(spacing: 8) {
                    Text(statusLabel).font(.callout.weight(.semibold)).foregroundStyle(statusColor)
                    Button("Test") { redirect.test() }
                        .buttonStyle(.mmSecondary)
                        .disabled(redirect.status == .off || redirect.status == .needsAccessibility || redirect.status == .failed)
                        .help("Open the dropdown under Apple's Control Center icon")
                    Button { redirect.update(); redirect.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.mmGhost).help("Check again")
                }
            }
            SettingsRow(title: "Apple's Control Center icon opens MacMaster",
                        subtitle: foundLine(redirect.foundControlCenter, enabled: settings.redirectControlCenter),
                        symbol: "switch.2", colors: Theme.Palette.indigo) {
                Toggle("", isOn: $settings.redirectControlCenter).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Apple's clock opens MacMaster's Clock",
                        subtitle: foundLine(redirect.foundClock, enabled: settings.redirectClock),
                        symbol: "clock.fill", colors: Theme.Palette.orange) {
                Toggle("", isOn: $settings.redirectClock).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var statusLabel: String {
        switch redirect.status {
        case .off: "Off"
        case .needsAccessibility: "Needs Accessibility"
        case .failed: "Can't listen"
        case .notFound: "Apple icon not found"
        case .active: "Active"
        }
    }

    private var statusDetail: String {
        switch redirect.status {
        case .off: "Turn a switch below on to redirect Apple's icon."
        case .needsAccessibility: "Grant Accessibility above so MacMaster can find Apple's icons and catch the click."
        case .failed: "Couldn't start the click listener. Check Accessibility (and Input Monitoring) access, then press check again."
        case .notFound: "Listening, but Apple's icon wasn't located in the menu bar. Test still opens the dropdown at the top of the screen."
        case .active: "Listening. Click Apple's icon, or press Test."
        }
    }

    private var statusColor: Color {
        switch redirect.status {
        case .active: .green
        case .off: .secondary
        case .needsAccessibility, .notFound: .orange
        case .failed: .red
        }
    }

    private var statusColors: [Color] {
        switch redirect.status {
        case .active: Theme.Palette.green
        case .off: Theme.Palette.gray
        case .needsAccessibility, .notFound: Theme.Palette.orange
        case .failed: Theme.Palette.red
        }
    }

    private var statusSymbol: String {
        switch redirect.status {
        case .active: "checkmark.circle.fill"
        case .off: "pause.circle.fill"
        case .needsAccessibility, .notFound, .failed: "exclamationmark.triangle.fill"
        }
    }

    private func foundLine(_ found: Bool, enabled: Bool) -> String {
        guard enabled else { return "Off. Clicking Apple's icon opens Apple's popover." }
        switch redirect.status {
        case .needsAccessibility: return "Waiting for Accessibility access."
        case .failed: return "Click listener not running."
        case .off: return "Off."
        default: return found ? "Apple's icon found in the menu bar." : "Apple's icon not found yet (rechecks every few seconds)."
        }
    }

    private var hideSection: some View {
        GroupedSection("Hide Apple's icon (experimental)", symbol: "eye.slash",
                       footer: "This edits Control Center preferences and restarts Control Center, then checks the menu bar. It likely won't work on macOS 26 and later, where macOS keeps the icon; if so MacMaster tells you and Restore undoes it. Use click redirect instead.") {
            SettingsRow(title: "Try hiding Apple's Control Center icon",
                        subtitle: hider.hidden.contains("main") ? "Hidden by preference." : "Asks for confirmation first.",
                        symbol: "eye.slash.fill", colors: Theme.Palette.red) {
                HStack(spacing: 8) {
                    Button("Try hiding Apple's Control Center icon") { hider.tryHideControlCenter() }
                        .buttonStyle(.mmSecondary).disabled(hider.busy)
                    Button("Restore") { hider.restoreAll() }
                        .buttonStyle(.mmGhost).disabled(hider.busy || !(hider.hasBackup || hider.hidden.contains("main")))
                }
            }
            if hider.busy || hider.report != nil {
                HStack(alignment: .top, spacing: 8) {
                    if hider.busy {
                        ProgressView().controlSize(.small)
                        Text("Restarting Control Center and checking the menu bar...").font(.callout).foregroundStyle(.secondary)
                    } else if let r = hider.report {
                        Image(systemName: r.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.kind == .success ? Color.green : Color.orange)
                        Text(r.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var modulesSection: some View {
        GroupedSection("Other Apple menu bar items", symbol: "menubar.rectangle",
                       footer: "The reliable way is System Settings > Menu Bar, which opens below. The switches here use the same reversible preferences as the experiment above and may be ignored by macOS.") {
            SettingsRow(title: "Open Menu Bar settings", subtitle: "Choose \"Don't Show in Menu Bar\" for each item.",
                        symbol: "gearshape.fill", colors: Theme.Palette.gray) {
                Button("Open") { hider.openMenuBarSettings() }.buttonStyle(.mmSecondary)
            }
            ForEach(AppleItemHider.modules) { m in
                SettingsRow(title: "Hide \(m.title)", symbol: m.symbol, colors: Theme.Palette.gray) {
                    Toggle("", isOn: Binding(get: { hider.isHidden(m) }, set: { hider.setModuleHidden(m, $0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(hider.busy)
                }
            }
            SettingsRow(title: "Restore all", subtitle: "Put every item MacMaster touched back how it was.", symbol: "arrow.uturn.backward", colors: Theme.Palette.gray) {
                Button("Restore all") { hider.restoreAll() }.buttonStyle(.mmSecondary).disabled(hider.busy)
            }
        }
    }
}
