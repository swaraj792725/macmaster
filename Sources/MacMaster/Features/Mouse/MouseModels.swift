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
    case none, middleClick, missionControl, appExpose, showDesktop, launchpad
    case back, forward, spaceLeft, spaceRight, lookUp, smartZoom
    case copy, paste, shortcut, openApp, openURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Default (pass through)"
        case .middleClick: return "Middle click"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad / Apps"
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        case .spaceLeft: return "Space to the Left"
        case .spaceRight: return "Space to the Right"
        case .lookUp: return "Look Up"
        case .smartZoom: return "Smart Zoom"
        case .copy: return "Copy (⌘C)"
        case .paste: return "Paste (⌘V)"
        case .shortcut: return "Keyboard shortcut…"
        case .openApp: return "Open app…"
        case .openURL: return "Open URL…"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "arrow.uturn.right"
        case .middleClick: return "computermouse"
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "square.stack.3d.up"
        case .showDesktop: return "macwindow"
        case .launchpad: return "square.grid.3x3"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .spaceLeft: return "arrow.left.to.line"
        case .spaceRight: return "arrow.right.to.line"
        case .lookUp: return "text.magnifyingglass"
        case .smartZoom: return "plus.magnifyingglass"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .shortcut: return "command"
        case .openApp: return "app.badge"
        case .openURL: return "link"
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
    var hold = MouseAction()

    /// True when we need to intercept this button at all.
    var isManaged: Bool {
        click.kind != .none || doubleClick.kind != .none || hold.kind != .none
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
    // Gestures
    var gestureEnabled = false
    var gestureButton = 2
    var gestureThreshold = 60.0
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
