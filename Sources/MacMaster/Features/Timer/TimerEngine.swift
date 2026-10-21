import Foundation

/// Scaffold: background side of Timer & Stopwatch. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class TimerEngine {
    static let shared = TimerEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Timer & Stopwatch settings, added to the global search.
    static let timerEntries: [SearchEntry] = []
}
