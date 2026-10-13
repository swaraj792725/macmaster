import AppKit
import SwiftUI

// MARK: - Layout

enum TilingLayoutCategory: String, CaseIterable, Identifiable {
    case halves = "Halves", quarters = "Quarters", thirds = "Thirds", twoThirds = "Two Thirds"
    case size = "Size", display = "Displays"
    var id: String { rawValue }
}

/// Everything the tiler can do to one window.
enum TilingLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center, restore
    case previousDisplay, nextDisplay
    case shrink, grow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .previousDisplay: "Previous Display"
        case .nextDisplay: "Next Display"
        case .shrink: "Shrink"
        case .grow: "Grow"
        }
    }

    /// Short caption for compact UIs.
    var shortTitle: String {
        switch self {
        case .leftHalf: "Left"
        case .rightHalf: "Right"
        case .topHalf: "Top"
        case .bottomHalf: "Bottom"
        case .topLeft: "TL"
        case .topRight: "TR"
        case .bottomLeft: "BL"
        case .bottomRight: "BR"
        case .leftThird: "1/3"
        case .centerThird: "Mid"
        case .rightThird: "3/3"
        case .leftTwoThirds: "2/3 L"
        case .rightTwoThirds: "2/3 R"
        case .maximize: "Max"
        case .almostMaximize: "90%"
        case .center: "Center"
        case .restore: "Restore"
        case .previousDisplay: "Prev"
        case .nextDisplay: "Next"
        case .shrink: "Shrink"
        case .grow: "Grow"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .leftThird: "rectangle.leftthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.rightthird.inset.filled"
        case .leftTwoThirds: "rectangle.lefthalf.inset.filled"
        case .rightTwoThirds: "rectangle.righthalf.inset.filled"
        case .maximize: "rectangle.fill"
        case .almostMaximize: "rectangle.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        case .previousDisplay: "arrow.left.to.line"
        case .nextDisplay: "arrow.right.to.line"
        case .shrink: "arrow.down.right.and.arrow.up.left"
        case .grow: "arrow.up.left.and.arrow.down.right"
        }
    }

    var category: TilingLayoutCategory {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .quarters
        case .leftThird, .centerThird, .rightThird: .thirds
        case .leftTwoThirds, .rightTwoThirds: .twoThirds
        case .maximize, .almostMaximize, .center, .restore, .shrink, .grow: .size
        case .previousDisplay, .nextDisplay: .display
        }
    }

    /// Fraction of the usable screen area (top-left origin, 0…1) this layout fills. Nil for relative actions.
    var unitRect: CGRect? {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        default: nil
        }
    }

    /// Rect used by mini diagrams (includes `center`).
    var diagramRect: CGRect? {
        if self == .center { return CGRect(x: 0.22, y: 0.2, width: 0.56, height: 0.6) }
        return unitRect
    }

    var isHalf: Bool { category == .halves }

    /// Layouts offered in the hover panel and the hero strip, in grid order (5 columns).
    static let gridOrder: [TilingLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .topLeft, .topRight, .bottomLeft, .bottomRight, .center,
    ]
}

// MARK: - Settings

/// Typed access to `mm.tiling.*` defaults. Safe to read from any thread.
enum TilingSettings {
    enum Key {
        static let enabled = "mm.tiling.enabled"
        static let snapEnabled = "mm.tiling.snap.enabled"
        static let snapHalves = "mm.tiling.snap.halves"
        static let snapTop = "mm.tiling.snap.top"
        static let snapCorners = "mm.tiling.snap.corners"
        static let snapThirds = "mm.tiling.snap.thirds"
        static let sensitivity = "mm.tiling.snap.sensitivity"
        static let restoreOnDrag = "mm.tiling.snap.restoreOnDrag"
        static let gap = "mm.tiling.gap"
        static let snapLayouts = "mm.tiling.snapLayouts.enabled"
        static let hotkeys = "mm.tiling.hotkeys.enabled"
        static let modDrag = "mm.tiling.modDrag.enabled"
        static let modDragModifier = "mm.tiling.modDrag.modifier"
        static let focusFollows = "mm.tiling.focusFollowsMouse"
        static let focusDelay = "mm.tiling.focusFollowsMouse.delay"
        static let titleDoubleClick = "mm.tiling.titleDoubleClick"
        static let shortcuts = "mm.tiling.shortcuts"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.enabled: true, Key.snapEnabled: true, Key.snapHalves: true, Key.snapTop: true,
            Key.snapCorners: true, Key.snapThirds: true, Key.sensitivity: 12.0, Key.restoreOnDrag: true,
            Key.gap: 0.0, Key.snapLayouts: true, Key.hotkeys: true, Key.modDrag: true,
            Key.modDragModifier: TilingModifierChoice.ctrlCmd.rawValue,
            Key.focusFollows: false, Key.focusDelay: 0.35, Key.titleDoubleClick: false,
        ])
    }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    private static func double(_ key: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? def
    }

    static var enabled: Bool { bool(Key.enabled, true) }
    static var snapEnabled: Bool { bool(Key.snapEnabled, true) }
    static var restoreOnDrag: Bool { bool(Key.restoreOnDrag, true) }
    static var sensitivity: CGFloat { CGFloat(min(60, max(4, double(Key.sensitivity, 12)))) }
    static var gap: CGFloat { CGFloat(min(20, max(0, double(Key.gap, 0)))) }
    static var snapLayoutsEnabled: Bool { bool(Key.snapLayouts, true) }
    static var hotkeysEnabled: Bool { bool(Key.hotkeys, true) }
    static var modDragEnabled: Bool { bool(Key.modDrag, true) }
    static var modDragModifier: TilingModifierChoice {
        TilingModifierChoice(rawValue: UserDefaults.standard.string(forKey: Key.modDragModifier) ?? "") ?? .ctrlCmd
    }
    static var focusFollows: Bool { bool(Key.focusFollows, false) }
    static var focusDelay: TimeInterval { min(1.5, max(0.1, double(Key.focusDelay, 0.35))) }
    static var titleDoubleClick: Bool { bool(Key.titleDoubleClick, false) }

    static var zones: TilingZoneConfig {
        TilingZoneConfig(halves: bool(Key.snapHalves, true), top: bool(Key.snapTop, true),
                         corners: bool(Key.snapCorners, true), thirds: bool(Key.snapThirds, true),
                         sensitivity: sensitivity)
    }
}

struct TilingZoneConfig: Sendable {
    var halves: Bool
    var top: Bool
    var corners: Bool
    var thirds: Bool
    var sensitivity: CGFloat
}

/// Modifier combination for the Linux-style drag.
enum TilingModifierChoice: String, CaseIterable, Identifiable {
    case ctrlCmd, optCmd, ctrlOpt, cmdShift
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ctrlCmd: "⌃⌘  Control + Command"
        case .optCmd: "⌥⌘  Option + Command"
        case .ctrlOpt: "⌃⌥  Control + Option"
        case .cmdShift: "⇧⌘  Shift + Command"
        }
    }

    var shortTitle: String {
        switch self {
        case .ctrlCmd: "⌃⌘"
        case .optCmd: "⌥⌘"
        case .ctrlOpt: "⌃⌥"
        case .cmdShift: "⇧⌘"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .ctrlCmd: [.maskControl, .maskCommand]
        case .optCmd: [.maskAlternate, .maskCommand]
        case .ctrlOpt: [.maskControl, .maskAlternate]
        case .cmdShift: [.maskShift, .maskCommand]
        }
    }
}

// MARK: - Saved layouts

struct TilingSavedWindow: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct TilingSavedLayout: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var windows: [TilingSavedWindow]
}
