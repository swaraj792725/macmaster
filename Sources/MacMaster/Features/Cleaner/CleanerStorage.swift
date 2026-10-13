import SwiftUI
import Observation

struct CleanerStorageSegment: Identifiable, Sendable, Codable {
    let id: String
    let title: String
    var bytes: Int64
    let colorHex: UInt32
    var color: Color { Color(hex: colorHex) }
    private enum CodingKeys: String, CodingKey { case id, title, bytes, colorHex }
}

private struct CleanerStorageCache: Codable {
    var date: Date
    var segments: [CleanerStorageSegment]
}

/// Fast approximate "what's using my disk" breakdown. Sizes are measured off the main thread.
@Observable
@MainActor
final class CleanerStorage {
    static let shared = CleanerStorage()

    private(set) var segments: [CleanerStorageSegment] = []
    private(set) var isLoading = false
    @ObservationIgnored private var lastLoad: Date?
    private static let cacheFile = "storage-breakdown.json"
    /// Walking the home folder is the most expensive thing the app does; do it at most every 6 hours.
    private static let maxAge: TimeInterval = 6 * 3600

    private init() {
        if let c = Store.load(CleanerStorageCache.self, from: Self.cacheFile) {
            segments = c.segments
            lastLoad = c.date
        }
    }

    func refresh(force: Bool = false) {
        if isLoading { return }
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < Self.maxAge, !segments.isEmpty { return }
        isLoading = true
        let used = SystemMonitor.shared.disk.used
        Task {
            let home = AppPaths.home
            let groups: [(String, String, UInt32, [URL])] = [
                ("apps", "Apps", 0x60A5FA, [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]),
                ("docs", "Documents", 0xA78BFA, [home.appendingPathComponent("Documents")]),
                ("downloads", "Desktop & Downloads", 0xFACC15, [home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads")]),
                ("media", "Media", 0xF472B6, ["Pictures", "Movies", "Music"].map { home.appendingPathComponent($0) }),
                ("dev", "Developer", 0x34D399, [home.appendingPathComponent("Library/Developer"), home.appendingPathComponent(".gradle"),
                                                  home.appendingPathComponent(".npm"), home.appendingPathComponent(".cargo")]),
                ("caches", "Caches", 0xFB923C, [home.appendingPathComponent("Library/Caches")]),
            ]
            var measured: [String: Int64] = [:]
            // One folder at a time at background priority: slower to finish, but never hogs the CPU or disk.
            for g in groups {
                let urls = g.3
                let size = await Task.detached(priority: .background) {
                    urls.reduce(Int64(0)) { $0 + AppPaths.allocatedSize(of: $1) }
                }.value
                measured[g.0] = size
                publish(groups: groups.map { ($0.0, $0.1, $0.2) }, measured: measured, used: used, final: false)
            }
            publish(groups: groups.map { ($0.0, $0.1, $0.2) }, measured: measured, used: used, final: true)
        }
    }

    private func publish(groups: [(String, String, UInt32)], measured: [String: Int64], used: Int64, final: Bool) {
        var segs = groups.compactMap { g -> CleanerStorageSegment? in
            guard let b = measured[g.0] else { return nil }
            return CleanerStorageSegment(id: g.0, title: g.1, bytes: b, colorHex: g.2)
        }
        if final {
            // `used` was read when the scan began; prefer the live value (the first sample may not have landed then).
            let live = SystemMonitor.shared.disk.used
            let used = live > 0 ? live : used
            let known = segs.reduce(Int64(0)) { $0 + $1.bytes }
            segs.append(CleanerStorageSegment(id: "system", title: "System Data (est.)", bytes: max(0, used - known), colorHex: 0x94A3B8))
            isLoading = false
            lastLoad = Date()
            Store.save(CleanerStorageCache(date: Date(), segments: segs), to: Self.cacheFile)
        }
        // Keep showing the cached breakdown until the new one is complete.
        if final || lastLoad == nil || segments.isEmpty { segments = segs }
    }
}
