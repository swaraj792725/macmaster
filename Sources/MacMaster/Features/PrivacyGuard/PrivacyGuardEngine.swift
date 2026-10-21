import Foundation

/// Scaffold: background side of Privacy Guard. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class PrivacyGuardEngine {
    static let shared = PrivacyGuardEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Privacy Guard settings, added to the global search.
    static let privacyGuardEntries: [SearchEntry] = []
}
