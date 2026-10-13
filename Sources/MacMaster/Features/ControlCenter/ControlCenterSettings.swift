import SwiftUI
import Observation

/// Menu bar glyph choices for the Control Center replacement.
enum ControlCenterIcon: String, CaseIterable, Identifiable {
    case switches, sliders, grid, dots, dial, command, bolt, gears, sparkles, toggles
    case faders, stack, hexes, cards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switches: "Switches"
        case .sliders: "Sliders"
        case .grid: "Grid"
        case .dots: "Dots"
        case .dial: "Dial"
        case .command: "Command"
        case .bolt: "Bolt"
        case .gears: "Gears"
        case .sparkles: "Sparkles"
        case .toggles: "Toggles"
        case .faders: "Faders"
        case .stack: "Stack"
        case .hexes: "Hexes"
        case .cards: "Cards"
        }
    }

    var symbol: String {
        switch self {
        case .switches: SymbolKit.firstAvailable(["switch.2", "slider.horizontal.3"])
        case .sliders: "slider.horizontal.3"
        case .grid: "square.grid.2x2"
        case .dots: SymbolKit.firstAvailable(["circle.grid.2x2.fill", "circle.grid.2x2"])
        case .dial: SymbolKit.firstAvailable(["dial.medium", "gauge.medium", "dial.min"])
        case .command: "command"
        case .bolt: SymbolKit.firstAvailable(["bolt.circle", "bolt"])
        case .gears: SymbolKit.firstAvailable(["gearshape.2", "gearshape"])
        case .sparkles: "sparkles"
        case .toggles: SymbolKit.firstAvailable(["togglepower", "power"])
        case .faders: SymbolKit.firstAvailable(["slider.vertical.3", "slider.horizontal.3"])
        case .stack: SymbolKit.firstAvailable(["square.stack.3d.up", "square.stack"])
        case .hexes: SymbolKit.firstAvailable(["circle.hexagongrid", "hexagon"])
        case .cards: SymbolKit.firstAvailable(["rectangle.3.group", "square.grid.2x2"])
        }
    }
}

/// Persistent settings for the Control Center replacement (`mm.controlcenter.*`).
@Observable
@MainActor
final class ControlCenterSettings {
    static let shared = ControlCenterSettings()

    private enum Keys {
        static let show = "mm.controlcenter.show"
        static let icon = "mm.controlcenter.icon"
        static let hidden = "mm.controlcenter.hiddenTiles"
        static let order = "mm.controlcenter.order"
        static let sizes = "mm.controlcenter.sizes"
        static let brightness = "mm.controlcenter.showBrightness"   // legacy, migrated into `hidden`
        static let volume = "mm.controlcenter.showVolume"           // legacy, migrated into `hidden`
        static let shortcut = "mm.controlcenter.focusShortcut"
        static let redirectCC = "mm.controlcenter.redirectAppleControlCenter"
        static let redirectClock = "mm.controlcenter.redirectAppleClock"
    }

    /// Tiles that start hidden when they are new to a layout. Everything else starts visible.
    private static let hiddenByDefault: Set<ControlCenterTile> = [.audioDevices, .bluetoothDevices]

    var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: Keys.show)
            ControlCenterMenuBar.shared.update()
        }
    }
    var icon: ControlCenterIcon {
        didSet {
            UserDefaults.standard.set(icon.rawValue, forKey: Keys.icon)
            ControlCenterMenuBar.shared.update()
        }
    }
    var hiddenTiles: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenTiles).sorted(), forKey: Keys.hidden) }
    }
    /// Every tile, in display order. Hidden tiles keep their slot so showing one again puts it back.
    private(set) var order: [ControlCenterTile] {
        didSet { UserDefaults.standard.set(order.map(\.rawValue), forKey: Keys.order) }
    }
    private(set) var sizes: [String: String] {
        didSet { UserDefaults.standard.set(sizes, forKey: Keys.sizes) }
    }
    /// Name of a Shortcut that toggles Do Not Disturb / a Focus. Empty = open Focus settings.
    var focusShortcut: String {
        didSet { UserDefaults.standard.set(focusShortcut, forKey: Keys.shortcut) }
    }
    /// Swallow clicks on Apple's Control Center menu bar item and open ours instead.
    var redirectControlCenter: Bool {
        didSet {
            UserDefaults.standard.set(redirectControlCenter, forKey: Keys.redirectCC)
            AppleItemRedirect.shared.update()
        }
    }
    /// Same for Apple's Clock item and the MacMaster Clock popover.
    var redirectClock: Bool {
        didSet {
            UserDefaults.standard.set(redirectClock, forKey: Keys.redirectClock)
            AppleItemRedirect.shared.update()
        }
    }

    private init() {
        let d = UserDefaults.standard
        showInMenuBar = d.bool(forKey: Keys.show)   // off until the user opts in
        icon = ControlCenterIcon(rawValue: d.string(forKey: Keys.icon) ?? "") ?? .switches
        focusShortcut = d.string(forKey: Keys.shortcut) ?? ""
        redirectControlCenter = d.bool(forKey: Keys.redirectCC)
        redirectClock = d.bool(forKey: Keys.redirectClock)
        sizes = d.dictionary(forKey: Keys.sizes) as? [String: String] ?? [:]

        var hidden = Set(d.stringArray(forKey: Keys.hidden) ?? [])
        var saved = (d.stringArray(forKey: Keys.order) ?? []).compactMap(ControlCenterTile.init(rawValue:))
        if d.stringArray(forKey: Keys.order) == nil {
            // First run of the flexible layout: carry over the old slider switches.
            if d.object(forKey: Keys.brightness) as? Bool == false { hidden.insert(ControlCenterTile.brightness.rawValue) }
            if d.object(forKey: Keys.volume) as? Bool == false { hidden.insert(ControlCenterTile.volume.rawValue) }
        }
        // Tiles added in a later version land at the end, in catalog order.
        for (tile, _) in ControlCenterTile.defaultLayout where !saved.contains(tile) {
            saved.append(tile)
            if Self.hiddenByDefault.contains(tile) { hidden.insert(tile.rawValue) }
        }
        hiddenTiles = hidden
        order = saved
    }

    // MARK: Visibility

    func isVisible(_ tile: ControlCenterTile) -> Bool { !hiddenTiles.contains(tile.rawValue) }

    func setVisible(_ tile: ControlCenterTile, _ on: Bool) {
        if on { hiddenTiles.remove(tile.rawValue) } else { hiddenTiles.insert(tile.rawValue) }
    }

    var visibleTiles: [ControlCenterTile] { order.filter(isVisible) }
    var hiddenList: [ControlCenterTile] { order.filter { !isVisible($0) } }

    // MARK: Sizes

    func size(_ tile: ControlCenterTile) -> ControlCenterTileSize {
        if let raw = sizes[tile.rawValue], let s = ControlCenterTileSize(rawValue: raw), tile.sizes.contains(s) { return s }
        return tile.defaultSize
    }

    func setSize(_ tile: ControlCenterTile, _ size: ControlCenterTileSize) {
        guard tile.sizes.contains(size) else { return }
        sizes[tile.rawValue] = size.rawValue
    }

    /// Next allowed size, wrapping around.
    func cycleSize(_ tile: ControlCenterTile) {
        let all = tile.sizes
        guard all.count > 1, let i = all.firstIndex(of: size(tile)) else { return }
        setSize(tile, all[(i + 1) % all.count])
    }

    // MARK: Order

    /// Moves `tile` so it sits where `target` is now.
    func move(_ tile: ControlCenterTile, onto target: ControlCenterTile) {
        guard tile != target, let from = order.firstIndex(of: tile), let to = order.firstIndex(of: target) else { return }
        var o = order
        o.remove(at: from)
        o.insert(tile, at: to)
        order = o
    }

    func moveUp(_ tile: ControlCenterTile) { shift(tile, by: -1) }
    func moveDown(_ tile: ControlCenterTile) { shift(tile, by: 1) }

    private func shift(_ tile: ControlCenterTile, by delta: Int) {
        guard let i = order.firstIndex(of: tile), order.indices.contains(i + delta) else { return }
        var o = order
        o.swapAt(i, i + delta)
        order = o
    }

    // MARK: Presets

    /// Shows exactly the preset's tiles in its order and hides the rest (kept after them).
    func apply(_ preset: ControlCenterPreset) {
        let layout = preset.layout
        let chosen = layout.map(\.tile)
        order = chosen + order.filter { !chosen.contains($0) }
        hiddenTiles = Set(ControlCenterTile.allCases.filter { !chosen.contains($0) }.map(\.rawValue))
        var s: [String: String] = [:]
        for (tile, size) in layout { s[tile.rawValue] = size.rawValue }
        sizes = s
    }

    func resetLayout() {
        order = ControlCenterTile.defaultLayout.map(\.tile)
        hiddenTiles = Set(Self.hiddenByDefault.map(\.rawValue))
        sizes = [:]
    }
}
