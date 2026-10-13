import Foundation
import CoreGraphics
import os

/// Dock preview thumbnail size (also reused by the in-app demo).
enum WindowPreviewThumbSize: Int, CaseIterable, Identifiable {
    case small = 0, medium = 1, large = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    var size: CGSize {
        switch self {
        case .small: return CGSize(width: 160, height: 100)
        case .medium: return CGSize(width: 220, height: 140)
        case .large: return CGSize(width: 300, height: 190)
        }
    }
    /// Bigger boxes for the full-screen window switcher HUD.
    var switcherSize: CGSize {
        switch self {
        case .small: return CGSize(width: 190, height: 120)
        case .medium: return CGSize(width: 250, height: 158)
        case .large: return CGSize(width: 320, height: 202)
        }
    }
}

enum WindowPreviewSwitcherShortcut: String, CaseIterable, Identifiable, Sendable {
    case commandTab, optionTab, controlTab
    var id: String { rawValue }
    var title: String {
        switch self {
        case .commandTab: return "⌘ Tab (replaces system switcher)"
        case .optionTab: return "⌥ Tab"
        case .controlTab: return "⌃ Tab"
        }
    }
    var symbol: String {
        switch self {
        case .commandTab: return "⌘"
        case .optionTab: return "⌥"
        case .controlTab: return "⌃"
        }
    }
    var modifier: CGEventFlags {
        switch self {
        case .optionTab: return .maskAlternate
        case .controlTab: return .maskControl
        case .commandTab: return .maskCommand
        }
    }
}

@MainActor
final class WindowPreviewSettings: ObservableObject {
    static let shared = WindowPreviewSettings()

    /// Read from the switcher's event-tap thread.
    nonisolated let shortcutBox = OSAllocatedUnfairLock(initialState: WindowPreviewSwitcherShortcut.commandTab)

    // Dock previews
    @Published var dockPreviews: Bool { didSet { save(dockPreviews, "dockPreviews") } }
    @Published var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    @Published var thumbSize: WindowPreviewThumbSize { didSet { save(thumbSize.rawValue, "thumbSize") } }
    @Published var showTitles: Bool { didSet { save(showTitles, "showTitles") } }
    @Published var showMinimized: Bool { didSet { save(showMinimized, "showMinimized") } }
    @Published var liveRefresh: Bool { didSet { save(liveRefresh, "liveRefresh") } }

    // Window switcher
    @Published var switcherEnabled: Bool { didSet { save(switcherEnabled, "switcherEnabled") } }
    @Published var switcherShortcut: WindowPreviewSwitcherShortcut {
        didSet {
            let s = switcherShortcut
            shortcutBox.withLock { $0 = s }
            save(s.rawValue, "switcherShortcut")
        }
    }
    @Published var switcherSize: WindowPreviewThumbSize { didSet { save(switcherSize.rawValue, "switcherSize") } }
    /// Minimized windows and windows of hidden apps.
    @Published var switcherIncludeHidden: Bool { didSet { save(switcherIncludeHidden, "switcherIncludeHidden") } }
    /// Apps that are running but have no window get a tile of their own.
    @Published var switcherShowAppsWithoutWindows: Bool {
        didSet { save(switcherShowAppsWithoutWindows, "switcherShowAppsWithoutWindows") }
    }
    @Published var switcherCurrentSpaceOnly: Bool { didSet { save(switcherCurrentSpaceOnly, "switcherCurrentSpaceOnly") } }
    /// Background low-resolution thumbnail prefetch so the switcher opens instantly.
    @Published var switcherPrefetch: Bool { didSet { save(switcherPrefetch, "switcherPrefetch") } }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: "mm.windows." + key)
        WindowPreviewController.shared.settingsChanged()
    }

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "mm.windows." + k) as? Bool ?? def }
        func size(_ k: String, _ def: WindowPreviewThumbSize) -> WindowPreviewThumbSize {
            WindowPreviewThumbSize(rawValue: d.object(forKey: "mm.windows." + k) as? Int ?? def.rawValue) ?? def
        }
        dockPreviews = b("dockPreviews", true)
        hoverDelay = d.object(forKey: "mm.windows.hoverDelay") as? Double ?? 0.3
        thumbSize = size("thumbSize", .medium)
        showTitles = b("showTitles", true)
        showMinimized = b("showMinimized", true)
        liveRefresh = b("liveRefresh", true)

        switcherEnabled = b("switcherEnabled", true)
        // The shortcut key is only written when the user picks one, so a missing key means
        // "never changed" and gets the new ⌘Tab default (this is the migration).
        let sc = WindowPreviewSwitcherShortcut(rawValue: d.string(forKey: "mm.windows.switcherShortcut") ?? "") ?? .commandTab
        switcherShortcut = sc
        shortcutBox.withLock { $0 = sc }
        switcherSize = size("switcherSize", .medium)
        switcherIncludeHidden = b("switcherIncludeHidden", true)
        switcherShowAppsWithoutWindows = b("switcherShowAppsWithoutWindows", false)
        switcherCurrentSpaceOnly = b("switcherCurrentSpaceOnly", false)
        switcherPrefetch = b("switcherPrefetch", true)
    }
}
