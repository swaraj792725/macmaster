import Foundation

/// Finds installed .app bundles and reads their Info.plist. Blocking: call off the main thread.
enum AppScanner {
    static func roots() -> [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [InstalledApp] = []
        var seenIDs = Set<String>()
        let selfID = Bundle.main.bundleIdentifier

        func consider(_ url: URL) {
            guard let app = read(url) else { return }
            // Apple system apps update with macOS; MacMaster updates itself.
            if app.bundleID.hasPrefix("com.apple.") && !app.hasReceipt { return }
            if let selfID, app.bundleID == selfID { return }
            if !app.bundleID.isEmpty {
                guard seenIDs.insert(app.bundleID).inserted else { return }
            }
            found.append(app)
        }

        for root in roots() {
            guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { continue }
            for url in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if url.pathExtension == "app" { consider(url); continue }
                // One level of plain folders (Utilities, vendor folders).
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let inner = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
                for sub in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where sub.pathExtension == "app" {
                    consider(sub)
                }
            }
        }
        return found
    }

    static func read(_ url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        // Some bundles carry invisible direction marks in the file name (WhatsApp).
        let fileName = String(String.UnicodeScalarView(url.deletingPathExtension().lastPathComponent.unicodeScalars
            .filter { $0.properties.generalCategory != .format })).trimmingCharacters(in: .whitespaces)
        let feed = (plist["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let receipt = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        return InstalledApp(
            id: url.path,
            name: fileName,
            bundleID: (plist["CFBundleIdentifier"] as? String) ?? "",
            version: (plist["CFBundleShortVersionString"] as? String) ?? "",
            build: (plist["CFBundleVersion"] as? String) ?? "",
            feedURL: feed, hasReceipt: receipt, tracking: nil, caskToken: nil)
    }
}
