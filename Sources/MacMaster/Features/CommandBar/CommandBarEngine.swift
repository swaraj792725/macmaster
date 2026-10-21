import SwiftUI
import AppKit

/// Background side of the Command Bar. `start()` runs once at launch from `Services.startAll()`.
/// When the bar is off nothing is registered, scanned or running.
@MainActor @Observable
final class CommandBarEngine {
    static let shared = CommandBarEngine()

    enum HotKeyState { case off, active, none, conflict }

    private(set) var hotKeyState: HotKeyState = .off
    private static let hotKeyName = "commandbar.open"

    private init() {}

    func start() {
        seedHotKey()
        guard CommandBarPrefs.enabled else { return }
        activate()
    }

    /// Called by the page's switch.
    func setEnabled(_ on: Bool) {
        if on {
            seedHotKey()
            activate()
        } else {
            GlobalHotKeys.shared.unregister(Self.hotKeyName)
            hotKeyState = .off
            CommandBarController.shared.hide()
            CBIcons.flush()
        }
    }

    /// Called by the hotkey field after the shortcut changed.
    func hotKeyChanged() {
        guard CommandBarPrefs.enabled else { return }
        registerHotKey()
    }

    func openNow() { CommandBarController.shared.show() }

    func resetUsage() { CommandBarUsage.shared.reset() }

    // MARK: Private

    private func activate() {
        registerHotKey()
        CommandBarAppIndex.shared.refreshIfStale()
        // Build the panel once the launch work is done so the first press is instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { if CommandBarPrefs.enabled { CommandBarController.shared.prewarm() } }
        }
    }

    private func registerHotKey() {
        guard StoredHotKey.load(CommandBarPrefs.hotKeyKey) != nil else {
            GlobalHotKeys.shared.unregister(Self.hotKeyName)
            hotKeyState = .none
            return
        }
        let ok = GlobalHotKeys.shared.register(Self.hotKeyName, defaultsKey: CommandBarPrefs.hotKeyKey) {
            CommandBarController.shared.toggle()
        }
        hotKeyState = ok ? .active : .conflict
    }

    /// First run: Option-Space. After that the user's choice (including "none") is kept.
    private func seedHotKey() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: CommandBarPrefs.hotKeySeededKey) else { return }
        d.set(true, forKey: CommandBarPrefs.hotKeySeededKey)
        if StoredHotKey.load(CommandBarPrefs.hotKeyKey) == nil {
            StoredHotKey.save(KeyboardCombo(keyCode: 49, modifiers: KeyboardMods.option, label: "Space"), CommandBarPrefs.hotKeyKey)
        }
    }
}

extension AppSearchIndex {
    /// Command Bar settings, added to the global search.
    static let commandBarEntries: [SearchEntry] = [
        SearchEntry(.commandbar, "Enable Command Bar", "launcher spotlight raycast alfred switch on off turn on hotkey global shortcut",
                    anchor: "commandbar.enable"),
        SearchEntry(.commandbar, "Command Bar shortcut", "hotkey global key option space keyboard open launcher",
                    anchor: "commandbar.hotkey"),
        SearchEntry(.commandbar, "Preview", "mock example what it looks like launcher window",
                    anchor: "commandbar.preview"),
        SearchEntry(.commandbar, "What the Command Bar searches", "providers apps files clipboard snippets calculator web system settings quick actions toggles",
                    anchor: "commandbar.providers"),
        SearchEntry(.commandbar, crumb: "What it searches", "Web search engine", "google duckduckgo browser search fallback",
                    anchor: "commandbar.providers"),
        SearchEntry(.commandbar, "Reset usage ranking", "frecency learned history forget favorites ranking clear",
                    anchor: "commandbar.ranking"),
        SearchEntry(.commandbar, "Command Bar tips", "syntax calculator unit conversion clip snip open url help",
                    anchor: "commandbar.tips"),
    ]
}
