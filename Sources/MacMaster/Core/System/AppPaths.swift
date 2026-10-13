import Foundation

enum AppPaths {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/MacMaster — created on first access.
    static var support: URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMaster", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func supportFile(_ name: String) -> URL { support.appendingPathComponent(name) }

    /// Recursive allocated size of a file or directory. Does not follow symlinks.
    /// On-disk size of a file or folder tree (allocated blocks, symlinks not followed, regular files only).
    /// Uses fts + lstat, several times cheaper than FileManager's URL enumerator for big trees.
    static func allocatedSize(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return Int64(st.st_blocks) * 512
        case S_IFDIR: break
        default: return 0
        }
        var total: Int64 = 0
        guard let root = strdup(url.path) else { return 0 }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            if Int32(ent.pointee.fts_info) == FTS_F, let sp = ent.pointee.fts_statp {
                total += Int64(sp.pointee.st_blocks) * 512
            }
        }
        return total
    }

    /// Moves to Trash (reversible). Returns error message on failure.
    @discardableResult
    static func trash(_ url: URL) -> String? {
        do { try fm.trashItem(at: url, resultingItemURL: nil); return nil }
        catch { return error.localizedDescription }
    }
}

/// Simple JSON persistence for Codable values in Application Support.
enum Store {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: AppPaths.supportFile(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: AppPaths.supportFile(name), options: .atomic)
    }
}
