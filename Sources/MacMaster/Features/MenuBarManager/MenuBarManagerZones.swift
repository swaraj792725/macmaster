import AppKit
import SwiftUI

// MARK: - Zones
//
// Windows-tray model: three zones icons are dragged between. In Classic mode a drop runs the real ⌘-drag
// move (`move(_:to:)`). In Dropdown mode (and on macOS versions that lay out the bar themselves) nothing in the
// real bar can move, so the zones are virtual: the order and membership are saved in prefs and decide what the
// « panel lists. Items macOS itself pushed out of the bar always land in the panel.

enum MenuBarManagerZone: String, CaseIterable, Identifiable {
    case shown, overflow, alwaysHidden
    var id: String { rawValue }

    var section: MenuBarManagerSection {
        switch self {
        case .shown: .visible
        case .overflow: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }
    init(section: MenuBarManagerSection) {
        switch section {
        case .visible: self = .shown
        case .hidden: self = .overflow
        case .alwaysHidden: self = .alwaysHidden
        }
    }

    var title: String {
        switch self {
        case .shown: "Shown in menu bar"
        case .overflow: "Hidden"
        case .alwaysHidden: "Always hidden"
        }
    }
    var symbol: String {
        switch self {
        case .shown: "menubar.rectangle"
        case .overflow: "chevron.left.2"
        case .alwaysHidden: "lock.fill"
        }
    }
    var colors: [Color] { section.colors }
}

/// One draggable icon, whichever mode produced it.
struct MenuBarManagerTile: Identifiable {
    /// Classic: the item's window id. Dropdown: the entry's stable id.
    let id: String
    let name: String
    let detail: String?
    let appIcon: NSImage?
    var zone: MenuBarManagerZone
    /// Control Center and Clock: macOS pins them, so they can't be dragged.
    var locked = false
    /// Dropdown mode: macOS already dropped it from the bar, so it can only live in the panel.
    var forcedOverflow = false
    var item: MenuBarManagerItem?
    var entry: MenuBarManagerEntry?

    static let payloadPrefix = "mmitem:"
    var payload: String { Self.payloadPrefix + id }

    @MainActor var capture: MenuBarManagerCapturedImage? {
        if let item { return MenuBarManagerCapture.shared.image(for: item) }
        if let entry { return MenuBarManagerCapture.shared.image(for: entry) }
        return nil
    }
}

extension MenuBarManager {
    /// Real zones: Classic mode, where our dividers and ⌘-drag actually rearrange the bar.
    var zonesAreReal: Bool { runningMode == .classic }

    static func isLocked(name: String, identifier: String) -> Bool {
        name == "Control Center" || name == "Clock"
            || identifier.hasPrefix("com.apple.menuextra.controlcenter") || identifier.hasPrefix("com.apple.menuextra.clock")
    }

    var dropdownOverflowCount: Int { zoneTiles()[.overflow]?.count ?? 0 }

    // MARK: Tiles

    /// Every zone's tiles, in display order. `includeSystem` keeps macOS's own items (Wi-Fi, battery, ...) in.
    func zoneTiles(includeSystem: Bool = true) -> [MenuBarManagerZone: [MenuBarManagerTile]] {
        var out: [MenuBarManagerZone: [MenuBarManagerTile]] = [:]
        if zonesAreReal {
            for it in items {
                var detail: String?
                if it.isClipped { detail = "Behind the notch" }
                else if it.isOffscreen && it.section == .visible { detail = "Off the bar" }
                let zone = MenuBarManagerZone(section: it.section)
                out[zone, default: []].append(MenuBarManagerTile(
                    id: "\(it.id)", name: it.displayName, detail: detail, appIcon: it.icon, zone: zone,
                    locked: Self.isLocked(name: it.displayName, identifier: it.title), item: it))
            }
            return out
        }
        let hiddenIDs = dropdownHiddenIDs
        let pool = dropdownEntries.filter { includeSystem || !$0.isSystem || favorites.contains($0.id) || hiddenIDs.contains($0.id) }
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let favs = favorites.compactMap { byID[$0] }.filter { !hiddenIDs.contains($0.id) }
        let favSet = Set(favs.map(\.id))
        let rest = pool.filter { !hiddenIDs.contains($0.id) && !favSet.contains($0.id) }
        func tile(_ e: MenuBarManagerEntry, _ zone: MenuBarManagerZone) -> MenuBarManagerTile {
            MenuBarManagerTile(id: e.id, name: e.displayName, detail: e.visibility.label ?? e.detail, appIcon: e.icon, zone: zone,
                               locked: Self.isLocked(name: e.displayName, identifier: e.identifier),
                               forcedOverflow: !e.visibility.isShowing, item: nil, entry: e)
        }
        out[.overflow] = favs.map { tile($0, .overflow) } + rest.filter { !$0.visibility.isShowing }.map { tile($0, .overflow) }
        out[.shown] = rest.filter { $0.visibility.isShowing }.map { tile($0, .shown) }
        out[.alwaysHidden] = pool.filter { hiddenIDs.contains($0.id) }.map { tile($0, .alwaysHidden) }
        return out
    }

    // MARK: Drop

    /// A tile was dropped on a zone (or onto a tile of the overflow zone, `before`). Classic: runs the real move.
    /// Dropdown: updates the virtual zones. `report` gets any reason it can't be done. Returns whether the drop was taken.
    @discardableResult
    func dropTiles(_ payloads: [String], into zone: MenuBarManagerZone, before: String? = nil,
                   report: @escaping (String) -> Void) -> Bool {
        let prefix = MenuBarManagerTile.payloadPrefix
        guard let id = payloads.first(where: { $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) }) else { return false }
        if zonesAreReal {
            guard let item = items.first(where: { "\($0.id)" == id }) else {
                report("That icon is gone. The list refreshes in a moment.")
                return false
            }
            if Self.isLocked(name: item.displayName, identifier: item.title) {
                report("\(item.displayName) is locked by macOS and can't be moved.")
                return false
            }
            guard !isMoving, busyItemID == nil else {
                report("Wait for the current move to finish.")
                return false
            }
            // Position inside a section can't be targeted by the ⌘-drag simulation, so a same-zone drop does nothing.
            guard item.section != zone.section else { return false }
            Task { [weak self] in await self?.move(item, to: zone.section) }
            return true
        }
        guard let e = dropdownEntries.first(where: { $0.id == id }) else {
            report("That icon is gone. Rescan and try again.")
            return false
        }
        if Self.isLocked(name: e.displayName, identifier: e.identifier) {
            report("\(e.displayName) is locked by macOS and can't be moved.")
            return false
        }
        if let msg = placeEntry(e, in: zone, before: before) {
            report(msg)
            return false
        }
        return true
    }

    /// Virtual move. Returns a failure message, nil on success.
    private func placeEntry(_ e: MenuBarManagerEntry, in zone: MenuBarManagerZone, before: String?) -> String? {
        if before == e.id { return nil }
        switch zone {
        case .shown:
            guard e.visibility.isShowing else {
                return "macOS isn't showing \(e.displayName) in the bar (\(e.visibility.label ?? "no room")), so it stays in the « panel."
            }
            favorites.removeAll { $0 == e.id }
            dropdownHiddenIDs.remove(e.id)
        case .overflow:
            dropdownHiddenIDs.remove(e.id)
            favorites.removeAll { $0 == e.id }
            if let before, let i = favorites.firstIndex(of: before) { favorites.insert(e.id, at: i) } else { favorites.append(e.id) }
        case .alwaysHidden:
            favorites.removeAll { $0 == e.id }
            dropdownHiddenIDs.insert(e.id)
        }
        persistDropdownPrefs()
        if zone != .alwaysHidden { Task { [weak self] in await self?.captureDropdownIcons() } }
        return nil
    }

    /// Click on a tile: open that icon's menu.
    func openTile(_ t: MenuBarManagerTile, kind: MenuBarManagerAutomation.PressKind = .primary) {
        if let e = t.entry { activateDropdownEntry(e, kind: kind) }
        else if let it = t.item { Task { [weak self] in await self?.activate(it) } }
    }
}
