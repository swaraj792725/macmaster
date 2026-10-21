import Foundation

/// Scaffold: background side of Notes. `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class NotesEngine {
    static let shared = NotesEngine()
    private init() {}
    func start() {}
}

extension AppSearchIndex {
    /// Notes settings, added to the global search.
    static let notesEntries: [SearchEntry] = []
}
