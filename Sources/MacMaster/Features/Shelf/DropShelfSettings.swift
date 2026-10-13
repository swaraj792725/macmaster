import SwiftUI
import Observation

/// Screen edge that opens the shelf when a file drag reaches it.
enum DropShelfEdge: String, CaseIterable, Identifiable {
    case off, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// Persisted Drop Shelf preferences (`mm.shelf.*`).
@Observable
@MainActor
final class DropShelfSettings {
    static let shared = DropShelfSettings()

    var enabled: Bool { didSet { save(enabled, Keys.enabled) } }
    var shakeToOpen: Bool { didSet { save(shakeToOpen, Keys.shake) } }
    var edge: DropShelfEdge { didSet { save(edge.rawValue, Keys.edge) } }
    var autoCloseWhenEmpty: Bool { didSet { save(autoCloseWhenEmpty, Keys.autoClose) } }

    /// Called after any change; `DropShelf` uses it to (un)install the drag monitor.
    @ObservationIgnored var onChange: (() -> Void)?

    private enum Keys {
        static let enabled = "mm.shelf.enabled"
        static let shake = "mm.shelf.shake"
        static let edge = "mm.shelf.edge"
        static let autoClose = "mm.shelf.autoclose"
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Keys.enabled) as? Bool ?? true
        shakeToOpen = d.object(forKey: Keys.shake) as? Bool ?? true
        edge = DropShelfEdge(rawValue: d.string(forKey: Keys.edge) ?? "") ?? .off
        autoCloseWhenEmpty = d.object(forKey: Keys.autoClose) as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}
