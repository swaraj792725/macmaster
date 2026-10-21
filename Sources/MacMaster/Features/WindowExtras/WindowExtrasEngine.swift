import Foundation

/// Scaffold: click debounce, Dock-click minimize, quit on last window close, green-button maximize.
/// `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class WindowExtrasEngine {
    static let shared = WindowExtrasEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Window and mouse extras settings, added to the global search.
    static let windowExtrasEntries: [SearchEntry] = []
    /// Clipboard upgrades (plain-text paste, link cleaning, auto-clear), added to the global search.
    static let clipboardExtrasEntries: [SearchEntry] = []
    /// Cleaner project junk and Uninstaller unused-apps entries, added to the global search.
    static let devToolsEntries: [SearchEntry] = []
}
