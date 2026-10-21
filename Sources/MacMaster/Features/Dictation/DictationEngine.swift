import Foundation

/// Scaffold: background side of Dictation. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class DictationEngine {
    static let shared = DictationEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Dictation settings, added to the global search.
    static let dictationEntries: [SearchEntry] = []
}
