import Foundation

/// Scaffold: background side of Capture. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class CaptureEngine {
    static let shared = CaptureEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Capture settings, added to the global search.
    static let captureEntries: [SearchEntry] = []
}
