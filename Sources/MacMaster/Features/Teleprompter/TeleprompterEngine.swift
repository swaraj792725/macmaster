import Foundation

/// Scaffold: background side of Teleprompter. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class TeleprompterEngine {
    static let shared = TeleprompterEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Teleprompter settings, added to the global search.
    static let teleprompterEntries: [SearchEntry] = []
}
