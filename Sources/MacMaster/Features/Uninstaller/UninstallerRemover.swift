import AppKit
import Foundation

// MARK: - Quitting running apps

@MainActor
enum UninstallerQuitter {
    static func instances(of app: UninstallerApp) -> [NSRunningApplication] {
        let path = app.url.standardizedFileURL.path
        let id = app.bundleID.lowercased()
        return NSWorkspace.shared.runningApplications.filter { r in
            if r.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
            if let p = r.bundleURL?.standardizedFileURL.path, p == path || p.hasPrefix(path + "/") { return true }
            if let b = r.bundleIdentifier?.lowercased(), b == id { return true }
            return false
        }
    }

    static func isRunning(_ app: UninstallerApp) -> Bool { !instances(of: app).isEmpty }

    /// Politely terminates, then force-terminates after a timeout. Returns true when nothing is left running.
    static func quit(_ app: UninstallerApp, timeout: TimeInterval = 6) async -> Bool {
        let list = instances(of: app)
        if list.isEmpty { return true }
        list.forEach { _ = $0.terminate() }
        var waited: TimeInterval = 0
        while waited < timeout {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
            if instances(of: app).allSatisfy(\.isTerminated) { return true }
        }
        instances(of: app).forEach { _ = $0.forceTerminate() }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if instances(of: app).allSatisfy(\.isTerminated) { return true }
        }
        return instances(of: app).isEmpty
    }
}

// MARK: - Removal pipeline

enum UninstallerRemover {
    /// Removes the given items. Call from a background task (blocking shell/file work).
    static func run(items: [UninstallerItem], deleteImmediately: Bool,
                    progress: @escaping @Sendable (String) -> Void) async -> UninstallerRemovalSummary {
        var summary = UninstallerRemovalSummary()
        summary.permanent = deleteImmediately
        let fm = FileManager.default
        let uid = getuid()

        let pruned = UninstallerItems.pruneNested(items)
        let receipts = pruned.filter(\.isReceipt)
        var files: [UninstallerItem] = []
        for item in pruned where !item.isReceipt {
            if UninstallerPaths.isProtected(item.url) {
                summary.failures.append(UninstallerRemovalFailure(path: item.displayPath, reason: "Protected system location – not touched"))
            } else if item.url.lastPathComponent.lowercased().hasPrefix("com.apple.") && !item.allowApple && item.category != .caches {
                summary.failures.append(UninstallerRemovalFailure(path: item.displayPath, reason: "Apple item – skipped for safety"))
            } else {
                files.append(item)
            }
        }
        // Everything inside a pruned parent is removed with it, so count nested ones as removed too.
        let nestedCovered = items.filter { it in !it.isReceipt && !pruned.contains(where: { $0.id == it.id }) }

        // 1. Unload launch jobs.
        let launchItems = files.filter { $0.launchLabel != nil }
        var adminParts: [String] = []
        if !launchItems.isEmpty { progress("Unloading launch items…") }
        for item in launchItems {
            guard let label = item.launchLabel, !label.isEmpty else { continue }
            if item.launchSystemDomain {
                adminParts.append("/bin/launchctl bootout \(Shell.quote("system/" + label)) >/dev/null 2>&1")
                adminParts.append("/bin/launchctl remove \(Shell.quote(label)) >/dev/null 2>&1")
            } else {
                _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15)
                _ = Shell.run("/bin/launchctl", ["remove", label], timeout: 15)
            }
        }

        // 2. User-removable items first.
        var adminFiles: [UninstallerItem] = []
        var removedFiles: [UninstallerItem] = []
        var alreadyGone: [UninstallerItem] = []   // vanished before we got to them: drop from the list, don't count
        var touchedPrefs = false
        for (i, item) in files.enumerated() {
            if Task.isCancelled { break }
            progress("Removing \(item.name)  (\(i + 1)/\(files.count))")
            if !UninstallerPaths.exists(item.url) { alreadyGone.append(item); continue }
            if !fm.isDeletableFile(atPath: item.url.path) || (item.requiresAdmin && !item.isUserDomain) {
                adminFiles.append(item); continue
            }
            do {
                if deleteImmediately { try fm.removeItem(at: item.url) }
                else { try fm.trashItem(at: item.url, resultingItemURL: nil) }
                removedFiles.append(item)
                if item.category == .preferences { touchedPrefs = true }
            } catch {
                let ns = error as NSError
                if isPermission(ns) { adminFiles.append(item) }
                else { summary.failures.append(UninstallerRemovalFailure(path: item.displayPath, reason: ns.localizedDescription)) }
            }
        }

        // 3. Everything that needs root: ONE administrator prompt.
        if !adminFiles.isEmpty || !receipts.isEmpty || !adminParts.isEmpty, !Task.isCancelled {
            summary.usedAdmin = true
            progress("Waiting for administrator approval…")
            let trash = UninstallerPaths.home.appendingPathComponent(".Trash").path
            let owner = "\(getuid()):\(getgid())"
            var parts = adminParts
            var usedNames = Set<String>()
            var results: [String: String] = [:]    // item id -> reason
            for item in adminFiles {
                let src = Shell.quote(item.url.path)
                let tag = Shell.quote(item.id)
                if deleteImmediately {
                    parts.append("( /bin/rm -rf -- \(src) && [ ! -e \(src) ] ) && printf 'OK\\t%s\\n' \(tag) || printf 'FAIL\\t%s\\n' \(tag)")
                } else {
                    var name = item.url.lastPathComponent
                    var n = 1
                    while usedNames.contains(name) || fm.fileExists(atPath: trash + "/" + name) {
                        name = "\(item.url.lastPathComponent) (MacMaster \(n))"; n += 1
                    }
                    usedNames.insert(name)
                    let dst = Shell.quote(trash + "/" + name)
                    parts.append("( /bin/mv -f -- \(src) \(dst) && /usr/sbin/chown -R -h \(owner) \(dst) ) && printf 'OK\\t%s\\n' \(tag) || printf 'FAIL\\t%s\\n' \(tag)")
                }
            }
            for r in receipts {
                guard case .receipt(let pkg) = r.kind else { continue }
                let tag = Shell.quote(r.id)
                parts.append("( /usr/sbin/pkgutil --forget \(Shell.quote(pkg)) >/dev/null 2>&1 ) && printf 'OK\\t%s\\n' \(tag) || printf 'FAIL\\t%s\\n' \(tag)")
            }
            let script = parts.joined(separator: "; ")
            let r = Shell.runAsAdmin("/bin/sh", ["-c", script],
                                     prompt: "MacMaster needs administrator access to remove \(adminFiles.count + receipts.count) protected item(s).")
            var okIDs = Set<String>()
            for line in r.stdout.components(separatedBy: .newlines) {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 2 else { continue }
                if cols[0] == "OK" { okIDs.insert(cols[1]) } else { results[cols[1]] = "Administrator command failed" }
            }
            let cancelled = !r.ok && okIDs.isEmpty
            for item in adminFiles + receipts {
                if okIDs.contains(item.id) {
                    if item.isReceipt { summary.removedCount += 1; summary.removedIDs.insert(item.id) }
                    else { removedFiles.append(item) }
                    if item.category == .preferences { touchedPrefs = true }
                } else {
                    let reason = cancelled ? (r.stderr.isEmpty ? "Administrator approval was not granted" : r.stderr)
                                           : (results[item.id] ?? "Could not be removed (is Full Disk Access granted?)")
                    summary.failures.append(UninstallerRemovalFailure(path: item.isReceipt ? item.id : item.displayPath, reason: reason))
                }
            }
        }

        // 4. Bookkeeping.
        for item in removedFiles {
            summary.removedCount += 1
            summary.freed += item.size
            summary.removedIDs.insert(item.id)
        }
        for item in alreadyGone { summary.removedIDs.insert(item.id) }
        for item in nestedCovered where removedFiles.contains(where: { parent in
            item.url.standardizedFileURL.path.hasPrefix(parent.url.standardizedFileURL.path + "/")
        }) {
            summary.removedIDs.insert(item.id)
        }
        if touchedPrefs { _ = Shell.run("/usr/bin/killall", ["cfprefsd"], timeout: 10) }
        if summary.removedCount > 0 && !deleteImmediately {
            summary.notes.append("Removed items are in the Trash – empty it to reclaim the space.")
        }
        return summary
    }

    private static func isPermission(_ e: NSError) -> Bool {
        if e.domain == NSCocoaErrorDomain {
            return [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(e.code)
        }
        if e.domain == NSPOSIXErrorDomain { return e.code == Int(EPERM) || e.code == Int(EACCES) }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(u) }
        return false
    }
}
