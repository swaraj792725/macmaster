import Foundation

/// Mac App Store updates through the public iTunes lookup API (batched by bundle id).
enum AppStoreChecker {
    static let batchSize = 20

    static var storeCountry: String {
        (Locale.current.region?.identifier ?? "US").lowercased()
    }

    struct Entry {
        var bundleID: String
        var version: String
        var notes: String?
        var viewURL: String?
        var minOS: String?
    }

    /// Looks up one batch. Bundle ids missing from the result are simply not in the storefront.
    static func lookup(bundleIDs: [String]) async throws -> [String: Entry] {
        let ids = bundleIDs.joined(separator: ",")
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: ids),
            URLQueryItem(name: "country", value: storeCountry),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        guard let url = comps.url else { throw UpdateError.parse("Bad lookup address") }
        let data = try await UpdateNet.fetch(url)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [String: Entry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw UpdateError.parse("Unexpected App Store response")
        }
        var out: [String: Entry] = [:]
        for r in results {
            guard let id = r["bundleId"] as? String, let v = r["version"] as? String else { continue }
            out[id.lowercased()] = Entry(bundleID: id, version: v, notes: (r["releaseNotes"] as? String).map { UpdateText.plain(fromHTML: $0) },
                                         viewURL: r["trackViewUrl"] as? String, minOS: r["minimumOsVersion"] as? String)
        }
        return out
    }

    static func update(for app: InstalledApp, entry: Entry, osVersion: String) -> AppUpdate? {
        if let min = entry.minOS, VersionCompare.compare(min, osVersion) > 0 { return nil }
        guard !app.version.isEmpty, VersionCompare.isNewer(entry.version, than: app.version) else { return nil }
        return AppUpdate(
            id: app.id, key: app.key, name: app.name, bundleID: app.bundleID, path: app.path,
            installedVersion: app.version, newVersion: entry.version, source: .appStore,
            notes: (entry.notes?.isEmpty == false) ? entry.notes : nil, notesURL: nil, downloadURL: nil,
            pageURL: entry.viewURL, caskToken: nil)
    }
}
