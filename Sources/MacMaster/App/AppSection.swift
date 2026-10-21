import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    // Declared in sidebar order (the Go menu shortcuts follow this order). Raw values are persisted: never rename.
    case dashboard
    case optimizer, cleaner, uninstaller, updates
    case stats, health, battery, power, wifi, sound
    case mouse, keyboard, windows, tiling
    case menubar, controlcenter, clock
    case commandbar, capture, tools, shelf
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .optimizer: "Optimizer"
        case .uninstaller: "Uninstaller"
        case .updates: "App Updates"
        case .sound: "Sound"
        case .commandbar: "Command Bar"
        case .capture: "Capture"
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
        case .controlcenter: "Control Center & Clock"
        case .clock: "Clock"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .optimizer: SymbolKit.firstAvailable(["gauge.with.dots.needle.67percent", "speedometer"])
        case .uninstaller: "trash.fill"
        case .updates: SymbolKit.firstAvailable(["arrow.down.app.fill", "arrow.down.circle.fill"])
        case .sound: SymbolKit.firstAvailable(["speaker.wave.3.fill", "speaker.wave.2.fill"])
        case .commandbar: SymbolKit.firstAvailable(["command.square.fill", "command"])
        case .capture: SymbolKit.firstAvailable(["camera.viewfinder", "viewfinder"])
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
        case .updates: "Updates for every app, in one list"
        case .sound: "Output, input, device priority and mic mute"
        case .commandbar: "Launch apps, actions and settings from anywhere"
        case .capture: "Copy text, QR codes and colors from the screen"
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
        case .controlcenter: "Apple's Control Center and clock icons"
        case .clock: "Menu bar clock, calendar, world time and time zone"
        case .permissions: "What MacMaster can access, and why"
        }
    }

    var colors: [Color] {
        switch self {
        case .dashboard: Theme.Palette.dashboard
        case .optimizer: Theme.Palette.yellow
        case .uninstaller: Theme.Palette.uninstaller
        case .updates: Theme.Palette.blue
        case .sound: Theme.Palette.pink
        case .commandbar: Theme.Palette.gray
        case .capture: Theme.Palette.purple
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

    var group: AppGroup {
        switch self {
        case .dashboard: .overview
        case .optimizer, .cleaner, .uninstaller, .updates: .clean
        case .stats, .health, .battery, .power, .wifi, .sound: .monitor
        case .mouse, .keyboard, .windows, .tiling: .input
        case .menubar, .controlcenter, .clock: .menubar
        case .commandbar, .capture, .tools, .shelf: .utilities
        case .permissions: .setup
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .dashboard: DashboardView()
        case .optimizer: OptimizerView()
        case .uninstaller: UninstallerView()
        case .updates: AppUpdatesView()
        case .sound: SoundView()
        case .commandbar: CommandBarView()
        case .capture: CaptureView()
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

/// Sidebar groups, in display order. Every section belongs to exactly one.
enum AppGroup: String, CaseIterable, Identifiable {
    case overview, clean, monitor, input, menubar, utilities, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .clean: "Clean & Optimize"
        case .monitor: "Monitor"
        case .input: "Input & Windows"
        case .menubar: "Menu Bar"
        case .utilities: "Utilities"
        case .setup: "Setup"
        }
    }

    var blurb: String {
        switch self {
        case .overview: "Your Mac at a glance"
        case .clean: "Free space and speed things up"
        case .monitor: "Live stats, health, battery and network"
        case .input: "Mouse, keyboard and window management"
        case .menubar: "Icons, Control Center and the clock"
        case .utilities: "Handy extras"
        case .setup: "Access MacMaster needs"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .clean: "sparkles"
        case .monitor: "waveform.path.ecg"
        case .input: "cursorarrow.and.square.on.square.dashed"
        case .menubar: "menubar.rectangle"
        case .utilities: "wrench.and.screwdriver.fill"
        case .setup: "lock.shield.fill"
        }
    }

    var sections: [AppSection] { AppSection.allCases.filter { $0.group == self } }
}

extension Notification.Name {
    /// Post with `object: "<AppSection rawValue>"` to navigate the main window.
    static let openSection = Notification.Name("MacMaster.openSection")
}
