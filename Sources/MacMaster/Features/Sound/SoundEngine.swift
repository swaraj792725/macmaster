import Foundation

/// Scaffold: background side of Sound. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class SoundEngine {
    static let shared = SoundEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Sound settings, added to the global search.
    static let soundEntries: [SearchEntry] = []
}
