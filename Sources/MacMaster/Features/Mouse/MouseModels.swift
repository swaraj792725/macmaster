import Foundation
import CoreGraphics
import os

// MARK: - Enums

enum MouseSmoothness: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Time constant (seconds) of the exponential glide while the wheel is being turned.
    var tau: Double {
        switch self {
        case .low: return 0.075
        case .medium: return 0.125
        case .high: return 0.19
        }
    }
}

enum MouseAccelCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, gentle, medium, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Linear"
        case .gentle: return "Gentle"
        case .medium: return "Dynamic"
        case .strong: return "Aggressive"
        }
    }
    /// How much faster fast wheel spins travel compared to slow ones.
    var gain: Double {
        switch self {
        case .off: return 0
        case .gentle: return 0.8
        case .medium: return 1.6
        case .strong: return 3.2
        }
    }
}

enum MouseActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, middleClick, rightClick
    case missionControl, appExpose, showDesktop, launchpad, notificationCenter, spotlight, screenshot, lockScreen
    case back, forward, spaceLeft, spaceRight, lookUp, smartZoom
    case pageUp, pageDown, scrollTop, scrollBottom
    case nextTab, prevTab, newTab, closeTab, reopenTab, minimize, fullScreen, hideApp
    case copy, paste, cut, undo, redo
    case playPause, nextTrack, prevTrack, volumeUp, volumeDown, mute
    case shortcut, openApp, openURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Default (pass through)"
        case .middleClick: return "Middle click"
        case .rightClick: return "Right click"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad / Apps"
        case .notificationCenter: return "Notification Center"
        case .spotlight: return "Spotlight"
        case .screenshot: return "Screenshot"
        case .lockScreen: return "Lock Screen"
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .spaceLeft: return "Move left a Space"
        case .spaceRight: return "Move right a Space"
        case .lookUp: return "Look Up"
        case .smartZoom: return "Smart Zoom"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .scrollTop: return "Scroll to top (⌘↑)"
        case .scrollBottom: return "Scroll to bottom (⌘↓)"
        case .nextTab: return "Next tab (⌃⇥)"
        case .prevTab: return "Previous tab (⌃⇧⇥)"
        case .newTab: return "New tab (⌘T)"
        case .closeTab: return "Close tab / window (⌘W)"
        case .reopenTab: return "Reopen closed tab (⌘⇧T)"
        case .minimize: return "Minimize window (⌘M)"
        case .fullScreen: return "Toggle full screen (⌃⌘F)"
        case .hideApp: return "Hide app (⌘H)"
        case .copy: return "Copy (⌘C)"
        case .paste: return "Paste (⌘V)"
        case .cut: return "Cut (⌘X)"
        case .undo: return "Undo (⌘Z)"
        case .redo: return "Redo (⌘⇧Z)"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next track"
        case .prevTrack: return "Previous track"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .shortcut: return "Keyboard shortcut…"
        case .openApp: return "Open app…"
        case .openURL: return "Open URL…"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "arrow.uturn.right"
        case .middleClick: return "computermouse"
        case .rightClick: return "contextualmenu.and.cursorarrow"
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "square.stack.3d.up"
        case .showDesktop: return "macwindow"
        case .launchpad: return "square.grid.3x3"
        case .notificationCenter: return "bell"
        case .spotlight: return "magnifyingglass"
        case .screenshot: return "camera.viewfinder"
        case .lockScreen: return "lock"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .spaceLeft: return "arrow.left.to.line"
        case .spaceRight: return "arrow.right.to.line"
        case .lookUp: return "text.magnifyingglass"
        case .smartZoom: return "plus.magnifyingglass"
        case .pageUp: return "arrow.up.doc"
        case .pageDown: return "arrow.down.doc"
        case .scrollTop: return "arrow.up.to.line"
        case .scrollBottom: return "arrow.down.to.line"
        case .nextTab: return "arrow.right.square"
        case .prevTab: return "arrow.left.square"
        case .newTab: return "plus.square.on.square"
        case .closeTab: return "xmark.square"
        case .reopenTab: return "arrow.uturn.backward.square"
        case .minimize: return "minus.square"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .hideApp: return "eye.slash"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .cut: return "scissors"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .playPause: return "playpause"
        case .nextTrack: return "forward"
        case .prevTrack: return "backward"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .mute: return "speaker.slash"
        case .shortcut: return "command"
        case .openApp: return "app.badge"
        case .openURL: return "link"
        }
    }

    /// Fine to fire again and again during one long drag (volume, pages, tabs…). Others fire once per direction.
    var repeatsWhileDragging: Bool {
        switch self {
        case .back, .forward, .spaceLeft, .spaceRight, .pageUp, .pageDown, .nextTab, .prevTab,
             .undo, .redo, .volumeUp, .volumeDown, .nextTrack, .prevTrack: return true
        default: return false
        }
    }

    /// Picker groups, in display order. `.none` is listed on its own above these.
    static let groups: [(title: String, kinds: [MouseActionKind])] = [
        ("Clicks", [.middleClick, .rightClick]),
        ("Navigation", [.back, .forward, .pageUp, .pageDown, .scrollTop, .scrollBottom]),
        ("Spaces & windows", [.spaceLeft, .spaceRight, .missionControl, .appExpose, .showDesktop, .launchpad]),
        ("Tabs & apps", [.nextTab, .prevTab, .newTab, .closeTab, .reopenTab, .minimize, .fullScreen, .hideApp]),
        ("Edit", [.copy, .paste, .cut, .undo, .redo, .lookUp, .smartZoom]),
        ("Media", [.playPause, .nextTrack, .prevTrack, .volumeUp, .volumeDown, .mute]),
        ("System", [.notificationCenter, .spotlight, .screenshot, .lockScreen]),
        ("Custom", [.shortcut, .openApp, .openURL]),
    ]
}

/// What happens while a button is held down and the mouse moves.
enum MouseDragMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, spaces, scroll, horizontalScroll, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .spaces: return "Switch Spaces & Mission Control"
        case .scroll: return "Scroll (grab and drag)"
        case .horizontalScroll: return "Horizontal scroll"
        case .custom: return "Custom action per direction"
        }
    }
    var detail: String {
        switch self {
        case .none: return "Moving the mouse while holding the button does nothing special."
        case .spaces: return "Drag left or right to switch Spaces (like a trackpad swipe), up for Mission Control, down for App Exposé."
        case .scroll: return "Hold and move the mouse to scroll the content under the pointer in any direction."
        case .horizontalScroll: return "Hold and move left or right to scroll sideways. Handy for timelines and wide tables."
        case .custom: return "Pick an action for each drag direction. Fires once per drag distance."
        }
    }
}

// MARK: - Shortcut / action / mapping

struct MouseShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// `CGEventFlags` raw value restricted to ⌃⌥⇧⌘.
    var flags: UInt64
    var label: String

    static let modifierMask: UInt64 =
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue

    var display: String {
        var s = ""
        if flags & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if flags & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s + label
    }
}

struct MouseAction: Codable, Equatable, Sendable {
    var kind: MouseActionKind = .none
    var shortcut: MouseShortcut? = nil
    /// App path (`openApp`) or URL string (`openURL`).
    var target: String = ""

    init(_ kind: MouseActionKind = .none) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case kind, shortcut, target }

    /// Unknown kinds (from a newer build) decode as `.none` instead of failing the whole config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(MouseActionKind.self, forKey: .kind)) ?? MouseActionKind.none
        shortcut = try? c.decodeIfPresent(MouseShortcut.self, forKey: .shortcut)
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
    }

    var summary: String {
        switch kind {
        case .shortcut: return shortcut?.display ?? "Shortcut (not set)"
        case .openApp:
            if target.isEmpty { return "Open app…" }
            return (target as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        case .openURL: return target.isEmpty ? "Open URL…" : target
        default: return kind.title
        }
    }
}

struct MouseButtonMapping: Codable, Equatable, Sendable {
    var click = MouseAction()
    var doubleClick = MouseAction()
    /// Long press without moving.
    var hold = MouseAction()
    /// Hold the button and move the mouse.
    var drag: MouseDragMode = .none
    var dragLeft = MouseAction(.spaceRight)
    var dragRight = MouseAction(.spaceLeft)
    var dragUp = MouseAction(.missionControl)
    var dragDown = MouseAction(.appExpose)

    init() {}

    /// True when we need to intercept this button at all.
    var isManaged: Bool {
        click.kind != .none || doubleClick.kind != .none || hold.kind != .none || drag != .none
    }

    enum CodingKeys: String, CodingKey { case click, doubleClick, hold, drag, dragLeft, dragRight, dragUp, dragDown }

    // Tolerant: fields added later must not wipe saved mappings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ cur: inout T) {
            if let x = try? c.decodeIfPresent(T.self, forKey: key) { cur = x }
        }
        v(.click, &click); v(.doubleClick, &doubleClick); v(.hold, &hold); v(.drag, &drag)
        v(.dragLeft, &dragLeft); v(.dragRight, &dragRight); v(.dragUp, &dragUp); v(.dragDown, &dragDown)
    }
}

// MARK: - Config

struct MouseConfig: Codable, Equatable, Sendable {
    // Scrolling
    var reverseVertical = false
    var reverseHorizontal = false
    var smoothEnabled = true
    var smoothness: MouseSmoothness = .medium
    var speed = 1.0
    var acceleration: MouseAccelCurve = .medium
    var inertia = true
    // Modifiers
    var shiftHorizontal = true
    var optionPrecise = true
    var controlFast = true
    var commandZoomPassthrough = true
    var preciseFactor = 0.3
    var fastFactor = 3.0
    // Buttons (keys are `mouseEventButtonNumber`: 2 = middle, 3 = button 4, 4 = button 5 …)
    var mappings: [Int: MouseButtonMapping] = [:]
    /// Distance (points) a held button must travel before a drag action fires.
    var gestureThreshold = 60.0
    // Legacy single "gesture button" (before per-button drag modes). Migrated into `mappings` on load.
    var gestureEnabled = false
    var gestureButton = 2
    var gestureLeft = MouseAction(.spaceRight)
    var gestureRight = MouseAction(.spaceLeft)
    var gestureUp = MouseAction(.missionControl)
    var gestureDown = MouseAction(.appExpose)
    // Pointer
    var disableAcceleration = false
    var customPointerSpeed = false
    var pointerSpeed = 0.6875

    init() {}

    enum CodingKeys: String, CodingKey {
        case reverseVertical, reverseHorizontal, smoothEnabled, smoothness, speed, acceleration, inertia
        case shiftHorizontal, optionPrecise, controlFast, commandZoomPassthrough, preciseFactor, fastFactor
        case mappings
        case gestureEnabled, gestureButton, gestureThreshold, gestureLeft, gestureRight, gestureUp, gestureDown
        case disableAcceleration, customPointerSpeed, pointerSpeed
    }

    // Tolerant decoding: unknown / missing keys fall back to defaults so adding fields never wipes settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ cur: inout T) {
            if let x = try? c.decodeIfPresent(T.self, forKey: key) { cur = x }
        }
        v(.reverseVertical, &reverseVertical); v(.reverseHorizontal, &reverseHorizontal)
        v(.smoothEnabled, &smoothEnabled); v(.smoothness, &smoothness); v(.speed, &speed)
        v(.acceleration, &acceleration); v(.inertia, &inertia)
        v(.shiftHorizontal, &shiftHorizontal); v(.optionPrecise, &optionPrecise)
        v(.controlFast, &controlFast); v(.commandZoomPassthrough, &commandZoomPassthrough)
        v(.preciseFactor, &preciseFactor); v(.fastFactor, &fastFactor)
        v(.mappings, &mappings)
        v(.gestureEnabled, &gestureEnabled); v(.gestureButton, &gestureButton)
        v(.gestureThreshold, &gestureThreshold)
        v(.gestureLeft, &gestureLeft); v(.gestureRight, &gestureRight)
        v(.gestureUp, &gestureUp); v(.gestureDown, &gestureDown)
        v(.disableAcceleration, &disableAcceleration); v(.customPointerSpeed, &customPointerSpeed)
        v(.pointerSpeed, &pointerSpeed)

        if gestureEnabled {
            var m = mappings[gestureButton] ?? MouseButtonMapping()
            if m.drag == .none {
                m.drag = .custom
                m.dragLeft = gestureLeft; m.dragRight = gestureRight
                m.dragUp = gestureUp; m.dragDown = gestureDown
                mappings[gestureButton] = m
            }
            gestureEnabled = false
        }
    }
}

// MARK: - Settings store

/// Observable settings for the UI; the tap thread reads `snapshot` (lock protected copy).
@MainActor
final class MouseSettings: ObservableObject {
    static let shared = MouseSettings()

    nonisolated static let enabledKey = "mm.mouse.enabled"
    nonisolated static let configKey = "mm.mouse.config"

    let snapshot: OSAllocatedUnfairLock<MouseConfig>

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            MouseEngine.shared.settingsChanged()
        }
    }

    @Published var config: MouseConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.configKey)
            }
            let c = config
            snapshot.withLock { $0 = c }
            MouseEngine.shared.settingsChanged()
        }
    }

    private init() {
        let d = UserDefaults.standard
        let en = d.object(forKey: Self.enabledKey) as? Bool ?? true
        var cfg = MouseConfig()
        if let data = d.data(forKey: Self.configKey), let c = try? JSONDecoder().decode(MouseConfig.self, from: data) {
            cfg = c
        }
        enabled = en
        config = cfg
        snapshot = OSAllocatedUnfairLock(initialState: cfg)
    }

    func mapping(_ button: Int) -> MouseButtonMapping { config.mappings[button] ?? MouseButtonMapping() }

    func resetAll() {
        config = MouseConfig()
    }
}
