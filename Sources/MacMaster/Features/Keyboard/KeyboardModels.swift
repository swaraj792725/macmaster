import SwiftUI
import AppKit

// MARK: - Preferences (UserDefaults keys, prefix mm.keyboard.)

enum KeyboardPrefs {
    static let hyperEnabled = "mm.keyboard.hyper.enabled"
    static let hyperKey = "mm.keyboard.hyper.key"
    static let hyperTapEscape = "mm.keyboard.hyper.tapEscape"
    /// Original `UserKeyMapping` saved before we changed it (JSON array). Survives crashes so we can always restore.
    static let hyperSavedMapping = "mm.keyboard.hyper.savedMapping"

    static let cornersEnabled = "mm.keyboard.corners.enabled"
    static let cornerDelay = "mm.keyboard.corners.delay"
    static let cornerFlash = "mm.keyboard.corners.flash"

    static let snippetsEnabled = "mm.keyboard.snippets.enabled"
    static let visualizerEnabled = "mm.keyboard.visualizer.enabled"
    static let cmdQGuard = "mm.keyboard.cmdq.enabled"
    static let cleaningDuration = "mm.keyboard.cleaning.duration"

    static func bool(_ key: String, default value: Bool = false) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    static func double(_ key: String, default value: Double) -> Double {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? value : d.double(forKey: key)
    }
}

// MARK: - Hyper

enum KeyboardHyperKey: String, CaseIterable, Identifiable {
    case caps, rightCommand, rightOption
    var id: String { rawValue }
    var title: String {
        switch self {
        case .caps: "Caps Lock"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        }
    }

    static var current: KeyboardHyperKey {
        KeyboardHyperKey(rawValue: UserDefaults.standard.string(forKey: KeyboardPrefs.hyperKey) ?? "") ?? .caps
    }
}

// MARK: - Key combos

enum KeyboardMods {
    // Carbon modifier masks (RegisterEventHotKey).
    static let command: UInt32 = 256
    static let shift: UInt32 = 512
    static let option: UInt32 = 2048
    static let control: UInt32 = 4096
    static let hyper: UInt32 = command | shift | option | control

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= command }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        return m
    }

    static func glyphs(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & control != 0 { s += "⌃" }
        if carbon & option != 0 { s += "⌥" }
        if carbon & shift != 0 { s += "⇧" }
        if carbon & command != 0 { s += "⌘" }
        return s
    }
}

struct KeyboardCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    var isHyper: Bool { modifiers & KeyboardMods.hyper == KeyboardMods.hyper }
    var display: String { (isHyper ? "✦ " : KeyboardMods.glyphs(modifiers)) + label }
}

// MARK: - App / action shortcuts

enum KeyboardShortcutKind: String, Codable, CaseIterable, Identifiable {
    case app, folder, url, shell
    case lockScreen, sleepDisplays, toggleDarkMode, emptyClipboard, showDesktop, missionControl
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "Launch / Focus App"
        case .folder: "Open Folder"
        case .url: "Open URL"
        case .shell: "Run Shell Command"
        case .lockScreen: "Lock Screen"
        case .sleepDisplays: "Sleep Displays"
        case .toggleDarkMode: "Toggle Dark Mode"
        case .emptyClipboard: "Empty Clipboard"
        case .showDesktop: "Show Desktop"
        case .missionControl: "Mission Control"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.fill"
        case .folder: "folder.fill"
        case .url: "link"
        case .shell: "terminal.fill"
        case .lockScreen: "lock.fill"
        case .sleepDisplays: "moon.fill"
        case .toggleDarkMode: "circle.lefthalf.filled"
        case .emptyClipboard: "clipboard"
        case .showDesktop: "macwindow"
        case .missionControl: "rectangle.3.group"
        }
    }

    var colors: [Color] {
        switch self {
        case .app: Theme.Palette.blue
        case .folder: Theme.Palette.teal
        case .url: Theme.Palette.indigo
        case .shell: Theme.Palette.gray
        case .lockScreen: Theme.Palette.red
        case .sleepDisplays: Theme.Palette.purple
        case .toggleDarkMode: Theme.Palette.indigo
        case .emptyClipboard: Theme.Palette.orange
        case .showDesktop: Theme.Palette.mint
        case .missionControl: Theme.Palette.purple
        }
    }

    var needsTarget: Bool { self == .app || self == .folder || self == .url || self == .shell }
}

enum KeyboardFrontmostBehavior: String, Codable, CaseIterable, Identifiable {
    case hide, cycle, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hide: "Hide the app (toggle)"
        case .cycle: "Cycle its windows"
        case .nothing: "Do nothing"
        }
    }
}

struct KeyboardAppShortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: KeyboardShortcutKind
    var target: String = ""
    var bundleID: String? = nil
    var combo: KeyboardCombo? = nil
    var enabled = true
    var frontmost: KeyboardFrontmostBehavior = .hide

    var summary: String {
        switch kind {
        case .app, .folder: return target.isEmpty ? "Not set" : (target as NSString).abbreviatingWithTildeInPath
        case .url, .shell: return target.isEmpty ? "Not set" : target
        default: return kind.title
        }
    }
}

// MARK: - Hot corners

enum KeyboardCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
    /// Key of the matching native macOS hot-corner default.
    var dockKey: String {
        switch self {
        case .topLeft: "wvous-tl-corner"
        case .topRight: "wvous-tr-corner"
        case .bottomLeft: "wvous-bl-corner"
        case .bottomRight: "wvous-br-corner"
        }
    }
}

enum KeyboardCornerAction: String, Codable, CaseIterable, Identifiable {
    case none, missionControl, appExpose, showDesktop, launchpad, lockScreen, sleepDisplays
    case screenSaver, notificationCenter, openApp, windowSwitcher
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .launchpad: "Launchpad / Apps"
        case .lockScreen: "Lock Screen"
        case .sleepDisplays: "Sleep Displays"
        case .screenSaver: "Start Screen Saver"
        case .notificationCenter: "Notification Center"
        case .openApp: "Open App…"
        case .windowSwitcher: "Window Switcher"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "square.on.square"
        case .showDesktop: "macwindow"
        case .launchpad: "square.grid.3x3.fill"
        case .lockScreen: "lock.fill"
        case .sleepDisplays: "moon.fill"
        case .screenSaver: "sparkles.tv"
        case .notificationCenter: "bell.fill"
        case .openApp: "app.fill"
        case .windowSwitcher: "rectangle.stack"
        }
    }
}

enum KeyboardCornerModifier: String, Codable, CaseIterable, Identifiable {
    case none, command, option, control, shift
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Always"
        case .command: "Holding ⌘"
        case .option: "Holding ⌥"
        case .control: "Holding ⌃"
        case .shift: "Holding ⇧"
        }
    }
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .none: nil
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }
}

struct KeyboardCornerConfig: Codable, Equatable {
    var action: KeyboardCornerAction = .none
    var modifier: KeyboardCornerModifier = .none
    var appPath: String = ""
}

struct KeyboardCornerSet: Codable, Equatable {
    var items: [String: KeyboardCornerConfig] = [:]
    subscript(corner: KeyboardCorner) -> KeyboardCornerConfig {
        get { items[corner.rawValue] ?? KeyboardCornerConfig() }
        set { items[corner.rawValue] = newValue }
    }
}

// MARK: - Snippets

struct KeyboardSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
    var enabled = true
}

// MARK: - Persisted collections

@MainActor
@Observable
final class KeyboardStore {
    static let shared = KeyboardStore()

    var shortcuts: [KeyboardAppShortcut] = [] {
        didSet { if shortcuts != oldValue { Store.save(shortcuts, to: "keyboard-app-shortcuts.json"); changed() } }
    }
    var snippets: [KeyboardSnippet] = [] {
        didSet { if snippets != oldValue { Store.save(snippets, to: "keyboard-snippets.json"); changed() } }
    }
    var corners = KeyboardCornerSet() {
        didSet { if corners != oldValue { Store.save(corners, to: "keyboard-corners.json"); changed() } }
    }

    private init() {
        shortcuts = Store.load([KeyboardAppShortcut].self, from: "keyboard-app-shortcuts.json") ?? []
        snippets = Store.load([KeyboardSnippet].self, from: "keyboard-snippets.json") ?? []
        corners = Store.load(KeyboardCornerSet.self, from: "keyboard-corners.json") ?? KeyboardCornerSet()
    }

    private func changed() { KeyboardEngine.shared.reconcile() }
}

// MARK: - Key names

enum KeyboardKeyNames {
    /// US-layout label for a virtual key code ("" when unknown).
    static func label(for code: Int) -> String {
        switch code {
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 4: return "H"; case 5: return "G"; case 6: return "Z"; case 7: return "X"
        case 8: return "C"; case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 16: return "Y"
        case 17: return "T"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 22: return "6"; case 23: return "5"; case 24: return "="
        case 25: return "9"; case 26: return "7"; case 27: return "-"; case 28: return "8"
        case 29: return "0"; case 30: return "]"; case 31: return "O"; case 32: return "U"
        case 33: return "["; case 34: return "I"; case 35: return "P"; case 36: return "↩"
        case 37: return "L"; case 38: return "J"; case 39: return "'"; case 40: return "K"
        case 41: return ";"; case 42: return "\\"; case 43: return ","; case 44: return "/"
        case 45: return "N"; case 46: return "M"; case 47: return "."; case 48: return "⇥"
        case 49: return "Space"; case 50: return "`"; case 51: return "⌫"; case 53: return "⎋"
        case 71: return "Clear"; case 76: return "⌅"
        case 82: return "Num 0"; case 83: return "Num 1"; case 84: return "Num 2"; case 85: return "Num 3"
        case 86: return "Num 4"; case 87: return "Num 5"; case 88: return "Num 6"; case 89: return "Num 7"
        case 91: return "Num 8"; case 92: return "Num 9"
        case 65: return "Num ."; case 67: return "Num *"; case 69: return "Num +"
        case 75: return "Num /"; case 78: return "Num -"; case 81: return "Num ="
        case 115: return "Home"; case 116: return "Page Up"; case 117: return "⌦"; case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 105: return "F13"; case 107: return "F14"; case 113: return "F15"; case 106: return "F16"
        case 64: return "F17"; case 79: return "F18"; case 80: return "F19"; case 90: return "F20"
        default: return ""
        }
    }

    static func isFunctionKey(_ code: Int) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(code)
    }
}
