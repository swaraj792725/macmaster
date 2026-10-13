import Foundation

/// Catalog of maintenance tasks plus helpers to run privileged work.
enum OptimizerMaintenance {
    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static let all: [OptimizerMaintenanceTask] = [
        OptimizerMaintenanceTask(
            id: "maint.dns", title: "Flush DNS cache",
            detail: "Clears cached hostname lookups and restarts mDNSResponder. Fixes sites that won't load after a network change.",
            symbol: "network", category: .network, impact: .low, gain: "Fixes stale lookups",
            requiresAdmin: true, intervalDays: 14, safe: false,
            adminCommand: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
        OptimizerMaintenanceTask(
            id: "maint.quicklook", title: "Reset Quick Look cache",
            detail: "Rebuilds Quick Look thumbnails and previews. Fixes blank or outdated previews in Finder.",
            symbol: "eye", category: .system, impact: .low, gain: "Fresh previews",
            requiresAdmin: false, intervalDays: 14, safe: true, adminCommand: nil,
            run: {
                let a = await Shell.runAsync("/usr/bin/qlmanage", ["-r", "cache"], timeout: 30)
                _ = await Shell.runAsync("/usr/bin/qlmanage", ["-r"], timeout: 30)
                return OptimizerOutcome(ok: a.ok, message: a.ok ? "Quick Look cache reset" : "qlmanage failed: \(OptimizerMaintenance.firstLine(a.stderr))")
            }),
        OptimizerMaintenanceTask(
            id: "maint.launchservices", title: "Rebuild Launch Services",
            detail: "Re-registers apps so Open With menus and default apps are accurate. Removes duplicate and ghost entries. Takes a minute.",
            symbol: "arrow.triangle.2.circlepath", category: .system, impact: .low, gain: "Cleaner Open With menu",
            requiresAdmin: false, intervalDays: 60, safe: false, longRunning: true, adminCommand: nil,
            run: {
                let r = await Shell.runAsync(OptimizerMaintenance.lsregisterPath,
                                             ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"], timeout: 240)
                return OptimizerOutcome(ok: r.ok, message: r.ok ? "Launch Services rebuilt. Relaunch Finder to see changes." : "lsregister failed: \(OptimizerMaintenance.firstLine(r.stderr))")
            }),
        OptimizerMaintenanceTask(
            id: "maint.fonts", title: "Clear font caches",
            detail: "Removes your user font cache so macOS rebuilds it. Fixes garbled or missing fonts. Log out or restart afterwards.",
            symbol: "textformat", category: .system, impact: .low, gain: "Fixes font glitches",
            requiresAdmin: false, intervalDays: 90, safe: false, adminCommand: nil,
            run: {
                let r = await Shell.runAsync("/usr/bin/atsutil", ["databases", "-removeUser"], timeout: 30)
                return OptimizerOutcome(ok: r.ok, message: r.ok ? "Font cache cleared. Restart to rebuild." : "atsutil failed: \(OptimizerMaintenance.firstLine(r.stderr))")
            }),
        OptimizerMaintenanceTask(
            id: "maint.verify", title: "Verify startup volume",
            detail: "Read-only check of the startup disk's file system structure. Nothing is modified. Can take a few minutes.",
            symbol: "checkmark.shield", category: .disk, impact: .low, gain: "Detects disk errors",
            requiresAdmin: false, intervalDays: 30, safe: false, longRunning: true, adminCommand: nil,
            run: {
                let r = await Shell.runAsync("/usr/sbin/diskutil", ["verifyVolume", "/"], timeout: 900)
                let text = r.stdout + "\n" + r.stderr
                let last = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty } ?? ""
                if r.ok { return OptimizerOutcome(ok: true, message: last.isEmpty ? "Volume verified" : last) }
                return OptimizerOutcome(ok: false, message: last.isEmpty ? "Verification reported a problem" : last)
            }),
        OptimizerMaintenanceTask(
            id: "maint.permissions", title: "Reset home folder permissions",
            detail: "Restores default ownership and permissions on your home folder. Fixes \"you don't have permission\" errors on your own files.",
            symbol: "lock.rotation", category: .system, impact: .low, gain: "Fixes permission errors",
            requiresAdmin: true, intervalDays: 90, safe: false,
            adminCommand: "/usr/sbin/diskutil resetUserPermissions / \(getuid())"),
    ]

    static func task(_ id: String) -> OptimizerMaintenanceTask? { all.first { $0.id == id } }

    fileprivate static var lsregisterPath: String { lsregister }

    static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown error"
    }

    // MARK: Last-run tracking

    private static let key = "mm.optimizer.lastRun"

    static func lastRun(_ id: String) -> Date? {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        return d?[id].map { Date(timeIntervalSince1970: $0) }
    }

    static func markRun(_ id: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        d[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: key)
    }

    static func isDue(_ t: OptimizerMaintenanceTask) -> Bool {
        guard let last = lastRun(t.id) else { return true }
        return Date().timeIntervalSince(last) > Double(t.intervalDays) * 86_400
    }

    // MARK: Privileged execution

    static func isCancelled(_ r: Shell.Result) -> Bool {
        r.stderr.contains("-128") || r.stderr.localizedCaseInsensitiveContains("cancel")
    }

    /// Runs one command with admin rights off the main thread (macOS shows the password prompt).
    static func admin(_ exe: String, _ args: [String], prompt: String) async -> Shell.Result {
        await Task.detached(priority: .userInitiated) { Shell.runAsAdmin(exe, args, prompt: prompt) }.value
    }

    /// Runs several trusted commands under one prompt. Returns per-id success.
    static func adminBatch(_ items: [(id: String, command: String)], prompt: String)
        async -> (results: [String: Bool], cancelled: Bool, error: String) {
        let script = items.map { "( \($0.command) ) >/dev/null 2>&1 && echo OK:\($0.id) || echo FAIL:\($0.id)" }
            .joined(separator: "; ")
        let r = await admin("/bin/sh", ["-c", script], prompt: prompt)
        if isCancelled(r) { return ([:], true, "Cancelled") }
        if !r.ok { return ([:], false, firstLine(r.stderr)) }
        var results: [String: Bool] = [:]
        for line in r.stdout.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("OK:") { results[String(t.dropFirst(3))] = true }
            else if t.hasPrefix("FAIL:") { results[String(t.dropFirst(5))] = false }
        }
        return (results, false, "")
    }
}
