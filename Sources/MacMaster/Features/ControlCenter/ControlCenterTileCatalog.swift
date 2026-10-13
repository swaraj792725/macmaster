import SwiftUI

/// Footprint of a tile on the popover's 4-column grid. Rows are counted in half rows
/// (34pt, the height of a slider), so a "1x1" tile is two half rows tall.
enum ControlCenterTileSize: String, CaseIterable, Identifiable {
    case small, wide, large, banner, panel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .wide: "Wide"
        case .large: "Large"
        case .banner: "Banner"
        case .panel: "Panel"
        }
    }

    /// Footprint in tile units, e.g. "2×1".
    var detail: String {
        switch self {
        case .small: "1×1"
        case .wide: "2×1"
        case .large: "2×2"
        case .banner: "4×1"
        case .panel: "4×2"
        }
    }

    var cols: Int {
        switch self {
        case .small: 1
        case .wide, .large: 2
        case .banner, .panel: 4
        }
    }

    var rows: Int {
        switch self {
        case .small, .wide, .banner: 2
        case .large, .panel: 4
        }
    }
}

/// Tiles the popover can show.
enum ControlCenterTile: String, CaseIterable, Identifiable {
    case wifi, bluetooth, darkMode, keepAwake, focus, nightShift, lowPower, lockScreen, screenshot, airDrop, cleaning, shelf
    case micMute, brightness, volume, keyboardBrightness, nowPlaying, audioDevices, bluetoothDevices
    case hideDesktop, hiddenFiles, smoothScroll, windowSwitcher

    var id: String { rawValue }

    enum Kind { case toggle, slider, module }

    var kind: Kind {
        switch self {
        case .brightness, .volume, .keyboardBrightness: .slider
        case .nowPlaying, .audioDevices, .bluetoothDevices: .module
        default: .toggle
        }
    }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .darkMode: "Dark Mode"
        case .keepAwake: "Keep Awake"
        case .focus: "Focus"
        case .nightShift: "Night Shift"
        case .lowPower: "Low Power"
        case .lockScreen: "Lock Screen"
        case .screenshot: "Screenshot"
        case .airDrop: "AirDrop"
        case .cleaning: "Cleaning"
        case .shelf: "Drop Shelf"
        case .micMute: "Mic Mute"
        case .brightness: "Display"
        case .volume: "Sound"
        case .keyboardBrightness: "Keyboard"
        case .nowPlaying: "Now Playing"
        case .audioDevices: "Audio Devices"
        case .bluetoothDevices: "Bluetooth Devices"
        case .hideDesktop: "Hide Desktop"
        case .hiddenFiles: "Hidden Files"
        case .smoothScroll: "Smooth Scroll"
        case .windowSwitcher: "Window Switcher"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .bluetooth: SymbolKit.firstAvailable(["bluetooth", "dot.radiowaves.left.and.right"])
        case .darkMode: "circle.lefthalf.filled"
        case .keepAwake: SymbolKit.firstAvailable(["cup.and.saucer.fill", "bolt.fill"])
        case .focus: "moon.fill"
        case .nightShift: SymbolKit.firstAvailable(["sun.max.fill", "sun.max"])
        case .lowPower: SymbolKit.firstAvailable(["battery.25percent", "battery.25"])
        case .lockScreen: "lock.fill"
        case .screenshot: SymbolKit.firstAvailable(["camera.viewfinder", "camera"])
        case .airDrop: SymbolKit.firstAvailable(["airplayaudio", "dot.radiowaves.left.and.right"])
        case .cleaning: SymbolKit.firstAvailable(["hand.raised.fill", "sparkles"])
        case .shelf: SymbolKit.firstAvailable(["tray.fill", "tray"])
        case .micMute: SymbolKit.firstAvailable(["mic.fill", "mic"])
        case .brightness: SymbolKit.firstAvailable(["sun.max.fill", "sun.max"])
        case .volume: "speaker.wave.2.fill"
        case .keyboardBrightness: SymbolKit.firstAvailable(["light.max", "keyboard"])
        case .nowPlaying: SymbolKit.firstAvailable(["play.circle.fill", "music.note"])
        case .audioDevices: SymbolKit.firstAvailable(["hifispeaker.fill", "speaker.wave.2.fill"])
        case .bluetoothDevices: SymbolKit.firstAvailable(["headphones", "dot.radiowaves.left.and.right"])
        case .hideDesktop: SymbolKit.firstAvailable(["menubar.dock.rectangle", "macwindow"])
        case .hiddenFiles: SymbolKit.firstAvailable(["eye.fill", "eye"])
        case .smoothScroll: SymbolKit.firstAvailable(["computermouse.fill", "cursorarrow"])
        case .windowSwitcher: SymbolKit.firstAvailable(["macwindow.on.rectangle", "macwindow"])
        }
    }

    var colors: [Color] {
        switch self {
        case .wifi, .bluetooth, .airDrop, .volume, .audioDevices: Theme.Palette.blue
        case .darkMode: Theme.Palette.indigo
        case .keepAwake: Theme.Palette.orange
        case .focus: Theme.Palette.purple
        case .nightShift, .brightness, .keyboardBrightness: Theme.Palette.yellow
        case .lowPower: Theme.Palette.green
        case .lockScreen: Theme.Palette.gray
        case .screenshot, .bluetoothDevices: Theme.Palette.teal
        case .cleaning, .nowPlaying: Theme.Palette.pink
        case .shelf: Theme.Palette.mint
        case .hideDesktop: Theme.Palette.teal
        case .hiddenFiles: Theme.Palette.pink
        case .smoothScroll: Theme.Palette.blue
        case .windowSwitcher: Theme.Palette.purple
        case .micMute: Theme.Palette.red
        }
    }

    /// Sizes the tile can take. Sliders are always one full-width half row.
    var sizes: [ControlCenterTileSize] {
        switch self {
        case .keepAwake: [.small, .wide, .large]
        case .brightness, .volume, .keyboardBrightness: [.banner]
        case .nowPlaying: [.wide, .banner, .large]
        case .audioDevices: [.wide, .banner, .panel]
        case .bluetoothDevices: [.wide, .banner, .large, .panel]
        default: [.small, .wide]
        }
    }

    var defaultSize: ControlCenterTileSize {
        switch self {
        case .wifi, .bluetooth, .airDrop: .wide
        case .brightness, .volume, .keyboardBrightness, .audioDevices, .nowPlaying, .bluetoothDevices: .banner
        default: .small
        }
    }

    /// Grid span (columns, half rows) for a size. Sliders ignore the size and take one half row.
    func span(_ size: ControlCenterTileSize) -> (cols: Int, rows: Int) {
        kind == .slider ? (4, 1) : (size.cols, size.rows)
    }

    /// Order and size a fresh install starts with. Tiles for hardware the Mac lacks hide themselves at runtime.
    static let defaultLayout: [(tile: ControlCenterTile, size: ControlCenterTileSize)] = [
        (.wifi, .wide), (.bluetooth, .wide),
        (.darkMode, .small), (.focus, .small), (.nightShift, .small), (.keepAwake, .small),
        (.lowPower, .small), (.micMute, .small), (.lockScreen, .small), (.screenshot, .small),
        (.airDrop, .wide), (.cleaning, .small), (.shelf, .small),
        (.hideDesktop, .small), (.hiddenFiles, .small), (.smoothScroll, .small), (.windowSwitcher, .small),
        (.brightness, .banner), (.keyboardBrightness, .banner), (.volume, .banner),
        (.audioDevices, .banner), (.nowPlaying, .banner), (.bluetoothDevices, .banner),
    ]

    /// Short description for the settings page.
    var blurb: String {
        switch self {
        case .wifi: "Turn the Wi-Fi radio on or off."
        case .bluetooth: "Turn Bluetooth on or off (asks for Bluetooth access once)."
        case .darkMode: "Switch appearance. Needs Automation access to System Events."
        case .keepAwake: "Stop the Mac from sleeping. Right-click or use the large size for 15m / 1h / 2h timers."
        case .focus: "Opens Focus settings, or runs a Shortcut you name below."
        case .nightShift: "Warm the display colors. Hidden if macOS blocks access."
        case .lowPower: "Toggling asks for your administrator password via macOS."
        case .lockScreen: "Lock the screen immediately."
        case .screenshot: "Open the macOS screenshot toolbar."
        case .airDrop: "Open the AirDrop window in Finder."
        case .cleaning: "Lock keyboard and trackpad until you end it."
        case .shelf: "Show or hide the Drop Shelf."
        case .micMute: "Mute or unmute the current microphone."
        case .brightness: "Built-in display brightness slider."
        case .volume: "Volume slider for the current output device."
        case .keyboardBrightness: "Keyboard backlight slider. Hidden if your keyboard has none."
        case .nowPlaying: "Title, artwork and transport controls. Hidden when macOS gives no playback info."
        case .audioDevices: "Switch the default output and input device."
        case .bluetoothDevices: "Connected Bluetooth devices with battery levels."
        case .hideDesktop: "Hide or show the icons on your desktop."
        case .hiddenFiles: "Show or hide hidden files in Finder."
        case .smoothScroll: "Smooth mouse-wheel scrolling (turns the Mouse feature on)."
        case .windowSwitcher: "Window previews when you switch apps."
        }
    }
}

/// Ready-made layouts. Applying one shows exactly its tiles and hides the rest.
enum ControlCenterPreset: String, CaseIterable, Identifiable {
    case essentials, everything, minimal, media, work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials: "Essentials"
        case .everything: "Everything"
        case .minimal: "Minimal"
        case .media: "Media"
        case .work: "Work"
        }
    }

    var symbol: String {
        switch self {
        case .essentials: "star.fill"
        case .everything: "square.grid.2x2.fill"
        case .minimal: "minus.circle.fill"
        case .media: "music.note"
        case .work: "briefcase.fill"
        }
    }

    var layout: [(tile: ControlCenterTile, size: ControlCenterTileSize)] {
        switch self {
        case .essentials:
            [(.wifi, .wide), (.bluetooth, .wide), (.darkMode, .small), (.focus, .small), (.nightShift, .small),
             (.keepAwake, .small), (.brightness, .banner), (.volume, .banner)]
        case .everything:
            ControlCenterTile.defaultLayout
        case .minimal:
            [(.wifi, .small), (.bluetooth, .small), (.darkMode, .small), (.keepAwake, .small),
             (.brightness, .banner), (.volume, .banner)]
        case .media:
            [(.nowPlaying, .large), (.volume, .banner), (.audioDevices, .panel), (.micMute, .small),
             (.bluetoothDevices, .wide), (.brightness, .banner)]
        case .work:
            [(.keepAwake, .large), (.focus, .wide), (.darkMode, .small), (.nightShift, .small),
             (.micMute, .small), (.lockScreen, .small), (.screenshot, .small), (.cleaning, .small),
             (.windowSwitcher, .small), (.hideDesktop, .small),
             (.brightness, .banner), (.volume, .banner)]
        }
    }
}
