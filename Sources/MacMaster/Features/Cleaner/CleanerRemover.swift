import Foundation

struct CleanerOutcome: Sendable {
    var freed: Int64 = 0
    var removedCount = 0
    var failures: [CleanerFailure] = []
    var perCategory: [CleanerCategoryID: Int64] = [:]
    var adminDeclined = false
}

/// Defense in depth: scanners only build safe paths, but we re-validate right before touching disk.
enum CleanerGuard {
    private static let forbidden = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Applications", "/cores", "/opt"]

    static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.contains("/../"), !path.hasSuffix("/.."), path.count > 3 else { return false }
        for f in forbidden where path == f || path.hasPrefix(f + "/") {
            // /usr/local is the only exception, and nothing here targets it.
            return false
        }
        let home = AppPaths.home.path
        // Parent must resolve inside an allowed root (blocks a symlinked parent redirecting outside).
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        if path.hasPrefix(home + "/") && path != home {
            let resolvedHome = AppPaths.home.resolvingSymlinksInPath().path
            return parent == resolvedHome || parent.hasPrefix(resolvedHome + "/")
        }
        if path.hasPrefix("/Library/Caches/") || path.hasPrefix("/Library/Logs/") { return parent.hasPrefix("/Library/") }
        if path.hasPrefix("/private/var/log/") { return parent.hasPrefix("/private/var/log") }
        if path.hasPrefix("/Volumes/") { return path.contains("/.Trashes/") }
        return false
    }
}

enum CleanerRemover {
    typealias Progress = @Sendable (Double, String) -> Void

    /// - Parameters:
    ///   - minAge: when set, directory/file deletes only remove files not modified for that long.
    ///   - allowAdmin: false in unattended runs; admin items are then skipped silently.
    static func run(items: [CleanerItem], minAge: TimeInterval? = nil, allowAdmin: Bool,
                    progress: @escaping Progress) async -> CleanerOutcome {
        await Task.detached(priority: .utility) {
            runSync(items: items, minAge: minAge, allowAdmin: allowAdmin, progress: progress)
        }.value
    }

    private static func runSync(items: [CleanerItem], minAge: TimeInterval?, allowAdmin: Bool,
                                progress: Progress) -> CleanerOutcome {
        var out = CleanerOutcome()
        let local = items.filter { !$0.needsAdmin && $0.isSelectable }
        let admin = items.filter { $0.needsAdmin && $0.isSelectable }
        let steps = Double(max(1, local.count + (admin.isEmpty ? 0 : 1)))
        var done = 0.0

        for item in local {
            if Task.isCancelled { break }
            progress(done / steps, item.name)
            let r = removeLocal(item, minAge: minAge)
            record(&out, item: item, freed: r.freed, error: r.error)
            done += 1
        }

        if !admin.isEmpty && allowAdmin && !Task.isCancelled {
            progress(done / steps, "Waiting for administrator approval…")
            runAdmin(admin, into: &out)
            done += 1
        }
        progress(1, "Finishing")
        return out
    }

    private static func record(_ out: inout CleanerOutcome, item: CleanerItem, freed: Int64, error: String?) {
        if freed > 0 || error == nil {
            out.freed += freed
            out.perCategory[item.category, default: 0] += freed
        }
        if let error {
            out.failures.append(CleanerFailure(name: item.name, reason: error))
        } else {
            out.removedCount += 1
        }
    }

    // MARK: Local removal

    private static func removeLocal(_ item: CleanerItem, minAge: TimeInterval?) -> (freed: Int64, error: String?) {
        switch item.action {
        case .info, .adminDelete:
            return (0, nil)
        case .command(let c):
            let r = Shell.run(c.executable, c.args, timeout: 900)
            var freed: Int64 = 0
            if r.ok {
                // Report what actually disappeared when the item has a measurable location.
                if !item.urls.isEmpty && item.size > 0 {
                    let after = item.urls.reduce(Int64(0)) { $0 + AppPaths.allocatedSize(of: $1) }
                    freed = max(0, item.size - after)
                } else { freed = item.size }
            }
            return (freed, r.ok ? nil : firstLine(r.stderr, fallback: "Command failed (\(r.status))"))
        case .trash:
            var freed: Int64 = 0, err: String?
            for u in item.urls {
                guard CleanerGuard.isAllowed(u) else { err = "Path not allowed"; continue }
                guard FileManager.default.fileExists(atPath: u.path) || isSymlink(u) else { continue }
                let size = AppPaths.allocatedSize(of: u)
                if let e = AppPaths.trash(u) { err = e } else { freed += size }
            }
            return (freed, err)
        case .delete:
            var freed: Int64 = 0, err: String?
            for u in item.urls {
                guard CleanerGuard.isAllowed(u) else { err = "Path not allowed"; continue }
                guard FileManager.default.fileExists(atPath: u.path) || isSymlink(u) else { continue }
                let r = delete(u, minAge: minAge)
                freed += r.freed
                if let e = r.error { err = e }
            }
            return (freed, err)
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Permanent delete. `removeItem` on a symlink removes the link, never its target.
    private static func delete(_ url: URL, minAge: TimeInterval?) -> (freed: Int64, error: String?) {
        let fm = FileManager.default
        if let minAge {
            return deleteOldContents(of: url, cutoff: Date().addingTimeInterval(-minAge))
        }
        let before = isSymlink(url) ? 0 : AppPaths.allocatedSize(of: url)
        do {
            try fm.removeItem(at: url)
            return (before, nil)
        } catch {
            let after = AppPaths.allocatedSize(of: url)
            return (max(0, before - after), error.localizedDescription)
        }
    }

    /// Removes only files last modified before `cutoff`; prunes directories left empty. Never follows symlinks.
    private static func deleteOldContents(of root: URL, cutoff: Date) -> (freed: Int64, error: String?) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var freed: Int64 = 0
        var firstError: String?
        var dirs: [URL] = []

        let rootVals = try? root.resourceValues(forKeys: Set(keys))
        if rootVals?.isSymbolicLink == true { return (0, nil) }
        if rootVals?.isRegularFile == true {
            guard let m = rootVals?.contentModificationDate, m < cutoff else { return (0, nil) }
            let size = Int64(rootVals?.totalFileAllocatedSize ?? rootVals?.fileAllocatedSize ?? 0)
            do { try fm.removeItem(at: root); return (size, nil) } catch { return (0, error.localizedDescription) }
        }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return (0, nil)
        }
        while let next = e.nextObject() as? URL {
            guard let v = try? next.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { e.skipDescendants(); continue }
            if v.isDirectory == true { dirs.append(next); continue }
            guard v.isRegularFile == true, let m = v.contentModificationDate, m < cutoff else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            do { try fm.removeItem(at: next); freed += size } catch { if firstError == nil { firstError = error.localizedDescription } }
        }
        // Deepest first; only directories that are now empty and themselves old.
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            guard (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true,
                  let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m < cutoff else { continue }
            try? fm.removeItem(at: d)
        }
        return (freed, firstError)
    }

    // MARK: Admin batch (one password prompt)

    private static func runAdmin(_ items: [CleanerItem], into out: inout CleanerOutcome) {
        var commands: [(item: CleanerItem, cmd: String)] = []
        for item in items {
            switch item.action {
            case .adminDelete:
                for u in item.urls where CleanerGuard.isAllowed(u) {
                    commands.append((item, "/bin/rm -rf -- " + Shell.quote(u.path)))
                }
            case .command(let c):
                commands.append((item, ([c.executable] + c.args).map(Shell.quote).joined(separator: " ")))
            default: break
            }
        }
        guard !commands.isEmpty else { return }
        let script = commands.enumerated().map { "\($0.element.cmd) || echo FAIL:\($0.offset)" }
            .joined(separator: "; ") + "; exit 0"
        let r = Shell.runAsAdmin("/bin/sh", ["-c", script],
                                 prompt: "MacMaster needs administrator access to remove system files.")
        if r.status != 0 {
            out.adminDeclined = true
            let reason = r.stderr.contains("-128") || r.stderr.localizedCaseInsensitiveContains("cancel")
                ? "Administrator access was cancelled" : firstLine(r.stderr, fallback: "Administrator command failed")
            for item in items { out.failures.append(CleanerFailure(name: item.name, reason: reason)) }
            return
        }
        var failed = Set<Int>()
        for line in r.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("FAIL:") {
            if let n = Int(line.dropFirst(5)) { failed.insert(n) }
        }
        var failedItems = Set<UUID>()
        for (i, c) in commands.enumerated() where failed.contains(i) { failedItems.insert(c.item.id) }
        let attempted = Set(commands.map(\.item.id))
        for item in items {
            if !attempted.contains(item.id) {
                out.failures.append(CleanerFailure(name: item.name, reason: "This location isn't allowed to be removed"))
            } else if failedItems.contains(item.id) {
                out.failures.append(CleanerFailure(name: item.name, reason: "Administrator command failed"))
            } else {
                out.freed += item.size
                out.perCategory[item.category, default: 0] += item.size
                out.removedCount += 1
            }
        }
    }

    private static func firstLine(_ s: String, fallback: String) -> String {
        let t = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? fallback : t
    }
}
