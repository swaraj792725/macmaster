import SwiftUI

// MARK: - Icon style

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case logo, health, cpu, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logo: "Logo"
        case .health: "Logo + health"
        case .cpu: "Logo + CPU bar"
        case .text: "Compact text"
        }
    }
    var detail: String {
        switch self {
        case .logo: "Static MacMaster mark."
        case .health: "Logo with a dot tinted by your Mac's health score."
        case .cpu: "Logo with a tiny live CPU bar."
        case .text: "A live percentage, e.g. 23%."
        }
    }
    /// Live styles need periodic refreshing.
    var isLive: Bool { self != .logo }
}

enum MenuBarTextMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, battery, health
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .health: "Health score"
        }
    }
}

// MARK: - Popover sections / tiles / actions

enum MenuBarSection: String, CaseIterable, Identifiable {
    case issues, stats, toggles, sliders, actions, windows, power, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .issues: "Health issues banner"
        case .stats: "Live stats"
        case .toggles: "Toggle tiles"
        case .sliders: "Brightness & volume"
        case .actions: "Quick actions"
        case .windows: "Window tiling & hidden icons"
        case .power: "Power & timers"
        case .processes: "Top processes"
        }
    }
    var symbol: String {
        switch self {
        case .issues: "exclamationmark.triangle"
        case .stats: "gauge.with.dots.needle.50percent"
        case .toggles: "switch.2"
        case .sliders: "slider.horizontal.3"
        case .actions: "bolt.fill"
        case .windows: "rectangle.split.2x2"
        case .power: "power"
        case .processes: "list.number"
        }
    }
    var key: String { "mm.menubar.show.\(rawValue)" }
}

enum MenuBarTile: String, CaseIterable, Identifiable {
    case keepAwake, darkMode, wifi, bluetooth, hideDesktop, hiddenFiles, lowPower, mute, smoothScroll, windowSwitcher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepAwake: "Keep Awake"
        case .darkMode: "Dark Mode"
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .hideDesktop: "Hide Desktop"
        case .hiddenFiles: "Hidden Files"
        case .lowPower: "Low Power"
        case .mute: "Mute"
        case .smoothScroll: "Smooth Scroll"
        case .windowSwitcher: "Window Switcher"
        }
    }
    var symbol: String {
        switch self {
        case .keepAwake: "cup.and.heat.waves.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .hideDesktop: "menubar.dock.rectangle"
        case .hiddenFiles: "eye.fill"
        case .lowPower: "bolt.badge.clock.fill"
        case .mute: "speaker.slash.fill"
        case .smoothScroll: "computermouse.fill"
        case .windowSwitcher: "macwindow.on.rectangle"
        }
    }
    var tint: Color {
        switch self {
        case .keepAwake: Color(hex: 0xF59E0B)
        case .darkMode: Color(hex: 0x6366F1)
        case .wifi: Color(hex: 0x0A84FF)
        case .bluetooth: Color(hex: 0x0A84FF)
        case .hideDesktop: Color(hex: 0x14B8A6)
        case .hiddenFiles: Color(hex: 0xEC4899)
        case .lowPower: Color(hex: 0xFACC15)
        case .mute: Color(hex: 0xEF4444)
        case .smoothScroll: Color(hex: 0x38BDF8)
        case .windowSwitcher: Color(hex: 0x8B5CF6)
        }
    }
    var key: String { "mm.menubar.tile.\(rawValue)" }
}

enum MenuBarQuickAction: String, CaseIterable, Identifiable {
    case optimize, freeRAM, flushDNS, openTrash, eject, lock, sleepDisplays, screenSaver, screenshot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optimize: "Optimize"
        case .freeRAM: "Free RAM"
        case .flushDNS: "Flush DNS"
        case .openTrash: "Trash"
        case .eject: "Eject"
        case .lock: "Lock"
        case .sleepDisplays: "Displays"
        case .screenSaver: "Saver"
        case .screenshot: "Capture"
        }
    }
    var help: String {
        switch self {
        case .optimize: "Quick optimize"
        case .freeRAM: "Free up memory"
        case .flushDNS: "Flush DNS cache (asks for administrator access)"
        case .openTrash: "Open the Trash in Finder"
        case .eject: "Eject all external disks"
        case .lock: "Lock screen"
        case .sleepDisplays: "Sleep displays"
        case .screenSaver: "Start screen saver"
        case .screenshot: "Screenshot tools"
        }
    }
    var symbol: String {
        switch self {
        case .optimize: "wand.and.stars"
        case .freeRAM: "memorychip"
        case .flushDNS: "network"
        case .openTrash: "trash"
        case .eject: "eject.fill"
        case .lock: "lock.fill"
        case .sleepDisplays: "display"
        case .screenSaver: "sparkles.tv"
        case .screenshot: "camera.viewfinder"
        }
    }
    var colors: [Color] {
        switch self {
        case .optimize: Theme.Palette.cleaner
        case .freeRAM: Theme.Palette.stats
        case .flushDNS: [Color(hex: 0x34D399), Color(hex: 0x0F766E)]
        case .openTrash: Theme.Palette.uninstaller
        case .eject: [Color(hex: 0x2DD4BF), Color(hex: 0x0F766E)]
        case .lock: Theme.Palette.neutral
        case .sleepDisplays: Theme.Palette.windows
        case .screenSaver: Theme.Palette.dashboard
        case .screenshot: [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
        }
    }
    var key: String { "mm.menubar.action.\(rawValue)" }
}

// MARK: - Optimizer hooks (wired by the app)

/// The lead wires these to `OptimizerEngine`. Buttons only show when the hook is set.
enum MenuBarHooks {
    static var quickOptimize: (() async -> String)?
    static var freeMemory: (() async -> String)?
}

// MARK: - Preference access

enum MenuBarPrefs {
    static let iconStyleKey = "mm.menubar.iconStyle"
    static let textMetricKey = "mm.menubar.iconTextMetric"
    static let columnsKey = "mm.menubar.tileColumns"

    static func isOn(_ key: String, default d: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }

    static var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: UserDefaults.standard.string(forKey: iconStyleKey) ?? "") ?? .logo
    }

    static var textMetric: MenuBarTextMetric {
        MenuBarTextMetric(rawValue: UserDefaults.standard.string(forKey: textMetricKey) ?? "") ?? .cpu
    }

    /// 2 or 3.
    static var tileColumns: Int {
        let v = UserDefaults.standard.object(forKey: columnsKey) as? Int ?? 2
        return v == 3 ? 3 : 2
    }

    /// Cheap fingerprint of every menu bar preference, used to detect changes.
    static func signature() -> String {
        var s = "\(iconStyle.rawValue)|\(textMetric.rawValue)|\(tileColumns)"
        for x in MenuBarSection.allCases { s += isOn(x.key) ? "1" : "0" }
        for x in MenuBarTile.allCases { s += isOn(x.key) ? "1" : "0" }
        for x in MenuBarQuickAction.allCases { s += isOn(x.key) ? "1" : "0" }
        return s
    }
}
