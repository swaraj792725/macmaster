import Foundation

/// Scaffold: background side of Command Bar. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class CommandBarEngine {
    static let shared = CommandBarEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Command Bar settings, added to the global search.
    static let commandBarEntries: [SearchEntry] = []
}
