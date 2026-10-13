import AppKit
import Observation

/// One parked file. Only the URL is stored; the file itself is never touched on drop.
struct DropShelfItem: Identifiable {
    let id = UUID()
    let url: URL
    let icon: NSImage
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// In-memory shelf contents.
@Observable
@MainActor
final class DropShelfModel {
    private(set) var items: [DropShelfItem] = []
    var notice: String?
    /// True while a drag that started on the shelf is in flight (ignore self-drops).
    var internalDragActive = false
    /// Drops whose URLs are still loading asynchronously.
    var pendingLoads = 0

    @ObservationIgnored var onChange: (() -> Void)?

    var urls: [URL] { items.map(\.url) }

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        var seen = known
        let fresh = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map(DropShelfItem.init))
        onChange?()
    }

    func remove(_ urls: [URL]) {
        let gone = Set(urls.map { $0.standardizedFileURL.path })
        items.removeAll { gone.contains($0.url.standardizedFileURL.path) }
        onChange?()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        onChange?()
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    /// Drops entries whose file vanished.
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { onChange?() }
    }
}
