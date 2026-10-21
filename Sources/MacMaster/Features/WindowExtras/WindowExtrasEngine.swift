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
    /// Cleaner project junk and Uninstaller unused-apps entries, added to the global search.
    static let devToolsEntries: [SearchEntry] = []
}
