import AppKit

// MARK: - Names of system items

enum MenuBarManagerNames {
    private static let known: [String: String] = [
        "wifi": "Wi-Fi", "controlcenter": "Control Center", "clock": "Clock", "battery": "Battery",
        "bluetooth": "Bluetooth", "sound": "Sound", "display": "Display", "focusmode": "Focus",
        "airplay": "AirPlay", "siri": "Siri", "spotlight": "Spotlight", "textinput": "Input Source",
        "vpn": "VPN", "timemachine": "Time Machine", "user": "Fast User Switching", "nowplaying": "Now Playing",
        "keyboardbrightness": "Keyboard Brightness", "stagemanager": "Stage Manager", "screencapture": "Screen Recording",
        "accessibility": "Accessibility Shortcuts", "musicrecognition": "Music Recognition", "hearing": "Hearing",
        "airdrop": "AirDrop", "shortcuts": "Shortcuts", "weather": "Weather",
    ]

    /// `com.apple.menuextra.wifi` -> "Wi-Fi".
    static func system(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        if let n = known[last.lowercased()] { return n }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

// MARK: - Dropdown entry

/// Why an item may not be on screen right now.
enum MenuBarManagerVisibility: String, Sendable {
    case visible
    /// Laid out under or left of the camera housing, so the bar is clipping it.
    case behindNotch
    /// macOS dropped it from the bar (not enough room, or switched off in System Settings › Menu Bar).
    case hiddenByMacOS

    var isShowing: Bool { self == .visible }
    var label: String? {
        switch self {
        case .visible: nil
        case .behindNotch: "Behind the notch"
        case .hiddenByMacOS: "Hidden by macOS"
        }
    }
}

/// One menu bar item as listed by the dropdown. Identified by `id`, a bundle-id based key that survives relaunches.
struct MenuBarManagerEntry: Identifiable {
    let id: String
    let pid: pid_t
    let bundleID: String
    let ownerName: String
    let title: String
    let identifier: String
    let isSystem: Bool
    /// Frame in global CG coordinates. Stale for items macOS hid.
    let frame: CGRect
    var visibility: MenuBarManagerVisibility
    var icon: NSImage?

    var cacheKey: String { id }
    var canCapture: Bool { visibility == .visible && frame.width > 1 && frame.height > 1 }

    var displayName: String {
        if isSystem {
            if identifier.hasPrefix("com.apple.menuextra") { return MenuBarManagerNames.system(identifier) }
            if !title.isEmpty { return title }
            return ownerName
        }
        return ownerName.isEmpty ? (title.isEmpty ? "Menu bar item" : title) : ownerName
    }

    /// Second line: the item's own label when the app has several.
    var detail: String? {
        guard !isSystem, !title.isEmpty, title != displayName, !title.hasPrefix("Item-") else { return nil }
        return title
    }

    var appRef: MenuBarManagerAppRef { MenuBarManagerAppRef(pid: pid, name: ownerName, bundleID: bundleID) }
}

// MARK: - Visibility inference

/// macOS 26+ hides items itself and leaves their Accessibility frames stale, often overlapping visible items.
/// There is no attribute that says "hidden", so infer it: the bar is a right-to-left tiling, so walk from the
/// right edge, always taking the item whose right edge sits at the current frontier. Items nothing can tile
/// into are hidden. Items known to be on screen (macOS's own groups, our own icons) win overlap ties.
enum MenuBarManagerVisibilityEngine {
    struct Input {
        let frame: CGRect
        /// Known to be on screen, so it wins over a stale overlapping frame.
        let anchor: Bool
    }

    nonisolated static func classify(_ items: [Input], strip: CGRect, notch: CGRect?) -> [MenuBarManagerVisibility] {
        var result = [MenuBarManagerVisibility](repeating: .hiddenByMacOS, count: items.count)
        var remaining = Set(items.indices.filter { i in
            let f = items[i].frame
            return f.width > 0 && f.maxX > strip.minX && f.minX < strip.maxX + 3
                && f.minY >= strip.minY - 3 && f.maxY <= strip.maxY + 3
        })
        var frontier = strip.maxX + 3
        while true {
            let cands = remaining.filter { items[$0].frame.maxX <= frontier + 3 }
            guard var best = cands.max(by: { items[$0].frame.maxX < items[$1].frame.maxX }) else { break }
            if !items[best].anchor {
                let f = items[best].frame
                let anchors = cands.filter { items[$0].anchor && overlap(items[$0].frame, f) > 0.5 }
                if let a = anchors.max(by: { items[$0].frame.maxX < items[$1].frame.maxX }) { best = a }
            }
            let f = items[best].frame
            remaining.remove(best)
            frontier = min(frontier, f.minX)
            if let notch, f.intersects(notch) || f.maxX <= notch.maxX {
                result[best] = .behindNotch
            } else {
                result[best] = .visible
            }
        }
        // An anchor can never be "hidden": if the walk skipped it, our model of the bar is wrong, so trust the anchor.
        for i in items.indices where items[i].anchor && result[i] == .hiddenByMacOS && remaining.contains(i) {
            result[i] = .visible
        }
        return result
    }

    /// Overlap width as a fraction of the narrower frame.
    private nonisolated static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let m = min(a.width, b.width)
        return m > 0 ? max(0, w) / m : 0
    }
}
