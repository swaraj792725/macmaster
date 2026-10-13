import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, optimizer, uninstaller, cleaner, battery, power, stats, health, mouse, keyboard, windows, tiling, tools, shelf, menubar, wifi, controlcenter, clock, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .optimizer: "Optimizer"
        case .uninstaller: "Uninstaller"
        case .cleaner: "Cleaner"
        case .battery: "Battery"
        case .power: "Power"
        case .stats: "System Stats"
        case .health: "Health Monitor"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        case .windows: "Window Switcher"
        case .tiling: "Window Tiling"
        case .menubar: "Menu Bar Icons"
        case .tools: "Toolbox"
        case .shelf: "Drop Shelf"
        case .wifi: "Wi-Fi"
        case .controlcenter: "Control Center"
        case .clock: "Clock"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .optimizer: SymbolKit.firstAvailable(["gauge.with.dots.needle.67percent", "speedometer"])
        case .uninstaller: "trash.fill"
        case .cleaner: "sparkles"
        case .battery: SymbolKit.firstAvailable(["battery.100percent.bolt", "bolt.batteryblock.fill", "battery.100"])
        case .power: "power"
        case .stats: "chart.xyaxis.line"
        case .health: "heart.text.square.fill"
        case .mouse: "computermouse.fill"
        case .keyboard: "keyboard.fill"
        case .windows: "macwindow.on.rectangle"
        case .tiling: SymbolKit.firstAvailable(["rectangle.split.2x2.fill", "square.split.2x2.fill"])
        case .menubar: "menubar.rectangle"
        case .tools: "wrench.and.screwdriver.fill"
        case .shelf: "tray.and.arrow.down.fill"
        case .wifi: "wifi"
        case .controlcenter: "switch.2"
        case .clock: "clock.fill"
        case .permissions: "lock.shield.fill"
        }
    }

    /// One-line description (used for sidebar search and tooltips).
    var blurb: String {
        switch self {
        case .dashboard: "Overview of your Mac"
        case .optimizer: "Speed up memory, CPU, disk and startup"
        case .uninstaller: "Remove apps and their leftovers"
        case .cleaner: "Free up space from caches and junk"
        case .battery: "Charge, health and power details"
        case .power: "Sleep, shutdown timers, energy and pmset"
        case .stats: "Live CPU, memory, disk and network"
        case .health: "Watchdog for bad patterns"
        case .mouse: "Scrolling, buttons and gestures"
        case .keyboard: "Hyper key, app shortcuts, hot corners"
        case .windows: "⌘Tab with window previews, Dock previews"
        case .tiling: "Snap windows to edges, layouts, shortcuts"
        case .menubar: "Hide, collapse and arrange menu bar icons"
        case .tools: "Large files, duplicates, startup items"
        case .shelf: "Park files while you drag, then drop them anywhere"
        case .wifi: "Signal, speed, addresses and nearby networks"
        case .controlcenter: "Tiles, brightness and sound in your menu bar"
        case .clock: "Menu bar clock, calendar, world time and time zone"
        case .permissions: "What MacMaster can access, and why"
        }
    }

    /// True when `query` matches the title, group or blurb.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return title.lowercased().contains(q) || group.lowercased().contains(q) || blurb.lowercased().contains(q)
    }

    /// Group names in first-seen order (robust to new cases/groups).
    static var groupOrder: [String] {
        var seen: [String] = []
        for s in allCases where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    var colors: [Color] {
        switch self {
        case .dashboard: Theme.Palette.dashboard
        case .optimizer: Theme.Palette.yellow
        case .uninstaller: Theme.Palette.uninstaller
        case .cleaner: Theme.Palette.cleaner
        case .battery: Theme.Palette.battery
        case .power: Theme.Palette.red
        case .stats: Theme.Palette.stats
        case .health: Theme.Palette.health
        case .mouse: Theme.Palette.mouse
        case .keyboard: Theme.Palette.blue
        case .windows: Theme.Palette.windows
        case .tiling: Theme.Palette.mint
        case .menubar: Theme.Palette.indigo
        case .tools: Theme.Palette.tools
        case .shelf: Theme.Palette.mint
        case .wifi: Theme.Palette.blue
        case .controlcenter: Theme.Palette.indigo
        case .clock: Theme.Palette.orange
        case .permissions: Theme.Palette.blue
        }
    }

    var group: String {
        switch self {
        case .dashboard: ""
        case .optimizer, .uninstaller, .cleaner: "Clean"
        case .battery, .power, .stats, .health: "Monitor"
        case .mouse, .keyboard, .windows, .tiling, .tools, .shelf: "Enhance"
        case .menubar, .wifi, .controlcenter, .clock: "Menu Bar"
        case .permissions: "Setup"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .dashboard: DashboardView()
        case .optimizer: OptimizerView()
        case .uninstaller: UninstallerView()
        case .cleaner: CleanerView()
        case .battery: BatteryView()
        case .power: PowerView()
        case .stats: StatsView()
        case .health: HealthView()
        case .mouse: MouseView()
        case .keyboard: KeyboardView()
        case .windows: WindowPreviewView()
        case .tiling: TilingView()
        case .menubar: MenuBarManagerView()
        case .tools: ToolsView()
        case .shelf: DropShelfView()
        case .wifi: WiFiView()
        case .controlcenter: ControlCenterView()
        case .clock: ClockView()
        case .permissions: PermissionsView()
        }
    }
}

extension Notification.Name {
    /// Post with `object: "<AppSection rawValue>"` to navigate the main window.
    static let openSection = Notification.Name("MacMaster.openSection")
}
