import Foundation

/// Scaffold: background side of App Updates. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class AppUpdatesEngine {
    static let shared = AppUpdatesEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// App Updates settings, added to the global search.
    static let updatesEntries: [SearchEntry] = []
}
