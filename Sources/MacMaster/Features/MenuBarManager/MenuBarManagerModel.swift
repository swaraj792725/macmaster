import AppKit
import SwiftUI

// MARK: - Preferences

/// UserDefaults keys (`mm.menubarmgr.*`) and typed accessors.
enum MenuBarManagerPrefs {
    static let enabledKey = "mm.menubarmgr.enabled"
    static let autoRehideKey = "mm.menubarmgr.autoRehideSeconds"
    static let rehideOnClickKey = "mm.menubarmgr.rehideOnClickElsewhere"
    static let rehideOnAppChangeKey = "mm.menubarmgr.rehideOnAppChange"
    static let showOnHoverKey = "mm.menubarmgr.showOnHover"
    static let showOnScrollKey = "mm.menubarmgr.showOnScroll"
    static let optionClickKey = "mm.menubarmgr.optionClickAlwaysHidden"
    static let alwaysHiddenEnabledKey = "mm.menubarmgr.alwaysHiddenEnabled"
    static let dropdownKey = "mm.menubarmgr.dropdownBar"
    static let hotkeyEnabledKey = "mm.menubarmgr.hotkeyEnabled"
    static let hotkeyCodeKey = "mm.menubarmgr.hotkeyCode"
    static let hotkeyModsKey = "mm.menubarmgr.hotkeyMods"
    static let glyphKey = "mm.menubarmgr.glyph"
    static let showDividerKey = "mm.menubarmgr.showDivider"
    static let collapsedKey = "mm.menubarmgr.collapsed"
    static let modeKey = "mm.menubarmgr.mode"
    static let modeMigrationKey = "mm.menubarmgr.modeMigratedV1"
    static let favoritesKey = "mm.menubarmgr.dropdown.favorites"
    static let dropdownHiddenKey = "mm.menubarmgr.dropdown.hiddenItems"
    static let showSystemItemsKey = "mm.menubarmgr.dropdown.showSystemItems"

    static let defaultAutoRehide = 10

    static var defaults: UserDefaults { .standard }

    static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
    static func int(_ key: String, default value: Int) -> Int {
        defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key)
    }

    static var enabled: Bool { bool(enabledKey, default: true) }
    static var autoRehideSeconds: Int { int(autoRehideKey, default: defaultAutoRehide) }
    static var rehideOnClick: Bool { bool(rehideOnClickKey, default: true) }
    static var rehideOnAppChange: Bool { bool(rehideOnAppChangeKey, default: true) }
    static var showOnHover: Bool { bool(showOnHoverKey, default: false) }
    static var showOnScroll: Bool { bool(showOnScrollKey, default: false) }
    static var optionClickAlwaysHidden: Bool { bool(optionClickKey, default: true) }
    static var alwaysHiddenEnabled: Bool { bool(alwaysHiddenEnabledKey, default: true) }
    static var dropdownBar: Bool { bool(dropdownKey, default: true) }
    static var hotkeyEnabled: Bool { bool(hotkeyEnabledKey, default: true) }
    static var glyph: MenuBarManagerGlyph {
        MenuBarManagerGlyph(rawValue: defaults.string(forKey: glyphKey) ?? "") ?? .chevron
    }
    static var showDivider: Bool { bool(showDividerKey, default: true) }
    static var showSystemItems: Bool { bool(showSystemItemsKey, default: false) }

    static var favorites: [String] {
        get { defaults.stringArray(forKey: favoritesKey) ?? [] }
        set { defaults.set(newValue, forKey: favoritesKey) }
    }
    static var dropdownHidden: [String] {
        get { defaults.stringArray(forKey: dropdownHiddenKey) ?? [] }
        set { defaults.set(newValue.sorted(), forKey: dropdownHiddenKey) }
    }

    /// Dropdown is the default for everyone; Classic only when explicitly chosen.
    static var mode: MenuBarManagerMode {
        get { MenuBarManagerMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .dropdown }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    /// One-time migration: everyone who ran the old separator manager lands in Dropdown mode with nothing
    /// collapsed. Our own toggle is parked next to the system items (preferred position 1 = right-most of the
    /// third-party area) instead of at the far left where the notch can clip it. Only our own item is touched.
    static func migrateIfNeeded() {
        guard !bool(modeMigrationKey, default: false) else { return }
        defaults.set(true, forKey: modeMigrationKey)
        defaults.set(MenuBarManagerMode.dropdown.rawValue, forKey: modeKey)
        defaults.set(false, forKey: collapsedKey)
        defaults.set(1.0, forKey: "NSStatusItem Preferred Position MacMasterMenuBarToggle")
    }
}

// MARK: - Mode

enum MenuBarManagerMode: String, CaseIterable, Identifiable {
    /// Never hides, resizes or moves anything. One status item opens a floating list of every menu bar item.
    case dropdown
    /// Separator status items push icons off-screen (Bartender / Ice style).
    case classic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dropdown: "Dropdown (doesn't move icons)"
        case .classic: "Classic (hide icons)"
        }
    }
    var shortTitle: String { self == .dropdown ? "Dropdown" : "Classic" }
    var summary: String {
        switch self {
        case .dropdown:
            "One icon opens a floating list of every menu bar item, including ones macOS hid behind the notch. Nothing in your menu bar is moved or hidden."
        case .classic:
            "Divider items push icons out of view and you ⌘-drag to arrange them. Newer macOS versions arrange the bar themselves, so this may not work."
        }
    }
    var symbol: String { self == .dropdown ? "rectangle.topthird.inset.filled" : "eye.slash" }
}

// MARK: - Toggle glyph

enum MenuBarManagerGlyph: String, CaseIterable, Identifiable {
    case chevron, ellipsis, dot, line, logo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chevron: "Chevron"
        case .ellipsis: "Ellipsis"
        case .dot: "Dot"
        case .line: "Line"
        case .logo: "MacMaster"
        }
    }
    var symbol: String {
        switch self {
        case .chevron: "chevron.left"
        case .ellipsis: "ellipsis"
        case .dot: "circle.fill"
        case .line: "minus"
        case .logo: "sparkles"
        }
    }
}

// MARK: - Sections & items

enum MenuBarManagerSection: String, CaseIterable, Identifiable, Codable {
    case visible, hidden, alwaysHidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
    var symbol: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "lock.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .visible: Theme.Palette.green
        case .hidden: Theme.Palette.orange
        case .alwaysHidden: Theme.Palette.purple
        }
    }
}

/// One menu bar item window (someone else's status item).
struct MenuBarManagerItem: Identifiable {
    /// CGWindowID of the item's window.
    let id: Int
    let pid: pid_t
    let ownerName: String
    let title: String
    /// Frame in global CG coordinates (origin top-left of the primary display).
    let frame: CGRect
    var section: MenuBarManagerSection
    /// Window currently has no on-screen position (pushed off the bar).
    let isOffscreen: Bool
    /// Overlaps the camera housing, or is a "visible" item that overflowed off-screen.
    let isClipped: Bool
    var icon: NSImage?
    /// Stable identity across scans (AX identifier/title + ordinal, or the window ID on the legacy path).
    var key: String = ""

    var displayName: String {
        let generic: Set<String> = ["Control Center", "SystemUIServer", "Window Server", "Dock"]
        if title.hasPrefix("com.apple.menuextra") { return MenuBarManagerNames.system(title) }
        if generic.contains(ownerName), !title.isEmpty { return title }
        if !ownerName.isEmpty { return ownerName }
        return title.isEmpty ? "Menu bar item" : title
    }

    /// Identity used to keep cached images across scans.
    var cacheKey: String { key.isEmpty ? "\(pid)|\(title)|\(Int(frame.width.rounded()))" : key }
}

/// Running app reference handed to the off-main AX scan.
struct MenuBarManagerAppRef: Sendable {
    let pid: pid_t
    let name: String
    var bundleID: String = ""
}

/// Raw status item record from the Accessibility scan or CGWindowList (Sendable so scanning runs off the main thread).
struct MenuBarManagerRawWindow: Sendable {
    let id: Int
    let pid: pid_t
    let ownerName: String
    let title: String
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
    var identifier: String = ""
    var key: String = ""
    // Dropdown mode.
    var bundleID: String = ""
    /// Bundle-id based identity that survives relaunches (the classic `key` starts with the pid).
    var stableKey: String = ""
    /// Owned by macOS itself (MenuBarAgent, Control Center, SystemUIServer).
    var isSystem = false
}

// MARK: - Collapse state

enum MenuBarManagerState: Equatable {
    /// Hidden + always-hidden dividers pushed out: only visible items shown.
    case collapsed
    /// Hidden items shown; always-hidden stay pushed out.
    case expanded
    /// Everything shown.
    case expandedAll
}

// MARK: - Hot key value

struct MenuBarManagerHotKey: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096).
    var modifiers: UInt32

    static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    static let `default` = MenuBarManagerHotKey(keyCode: 11, modifiers: control | option | cmd) // ⌃⌥⌘B

    static var stored: MenuBarManagerHotKey {
        let d = MenuBarManagerPrefs.defaults
        guard d.object(forKey: MenuBarManagerPrefs.hotkeyCodeKey) != nil else { return .default }
        return MenuBarManagerHotKey(keyCode: UInt32(max(0, d.integer(forKey: MenuBarManagerPrefs.hotkeyCodeKey))),
                                    modifiers: UInt32(max(0, d.integer(forKey: MenuBarManagerPrefs.hotkeyModsKey))))
    }

    func save() {
        let d = MenuBarManagerPrefs.defaults
        d.set(Int(keyCode), forKey: MenuBarManagerPrefs.hotkeyCodeKey)
        d.set(Int(modifiers), forKey: MenuBarManagerPrefs.hotkeyModsKey)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        return m
    }

    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static func keyName(_ code: UInt32) -> String { names[code] ?? "Key \(code)" }
}
