import Foundation
import AppKit

/// Turns a snapshot into the list of actionable / informational recommendations.
enum OptimizerRecommender {
    @MainActor
    static func build(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var recs: [OptimizerRecommendation] = []
        recs += memory(s)
        recs += cpu(s)
        recs += energy(s)
        recs += disk(s)
        recs += startup(s)
        recs += system(s)
        recs += maintenance(s)
        return recs.sorted {
            if $0.category.sortIndex != $1.category.sortIndex { return $0.category.sortIndex < $1.category.sortIndex }
            return $0.impact > $1.impact
        }
    }

    private static let gb = 1_073_741_824.0

    // MARK: Memory

    @MainActor
    private static func memory(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var out: [OptimizerRecommendation] = []

        for u in OptimizerScoring.idleHeavyApps(s).prefix(6) {
            let impact: OptimizerImpact = u.memory > 1_500 << 20 ? .high : u.memory > 800 << 20 ? .medium : .low
            let pid = u.pid, path = u.path, name = u.name
            out.append(OptimizerRecommendation(
                id: "mem.app.\(u.bundleID ?? String(u.pid))",
                title: "Quit \(u.name)",
                detail: "\(u.name) is running in the background and using \(Fmt.bytes(u.memory)) of memory (including helpers) while idle. It will be asked to quit gracefully, so you can save any open work.",
                category: .memory, impact: impact, gain: "Frees about \(Fmt.bytes(u.memory))",
                symbol: "memorychip", quitsApps: true,
                apply: { await OptimizerProc.quit(pid: pid, expectedPath: path, name: name, force: false) },
                estimatedMemory: Int64(u.memory)))
        }

        let pressured = s.pressure >= 2 || s.swapUsed > 512 << 20 || s.memUsedFraction > 0.85
        if pressured {
            let cached = s.memCached
            out.append(OptimizerRecommendation(
                id: "mem.purge", title: "Purge inactive memory",
                detail: s.pressure >= 4
                    ? "Memory pressure is critical. Purging releases cached files so apps have room. macOS refills the cache as needed."
                    : "Releases cached and inactive memory (about \(Fmt.bytes(cached)) is cached right now). Needs your administrator password.",
                category: .memory, impact: s.pressure >= 2 ? .high : .medium,
                gain: "Reclaims up to \(Fmt.bytes(cached))", symbol: "wind",
                adminCommand: "/usr/sbin/purge", estimatedMemory: Int64(cached)))
        }
        if s.swapUsed > 1 << 30 {
            out.append(OptimizerRecommendation(
                id: "mem.swap", title: "High swap usage",
                detail: String(format: "%.1f GB of memory has been pushed to disk, which slows everything down. Quitting heavy apps or restarting clears it.", Double(s.swapUsed) / gb),
                category: .memory, impact: .medium, gain: "Faster app switching", symbol: "arrow.left.arrow.right.square"))
        }
        return out
    }

    // MARK: CPU

    @MainActor
    private static func cpu(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        OptimizerScoring.hogs(s).prefix(5).map { u in
            let pid = u.pid, path = u.path, name = u.name
            let pct = Int(u.cpuAvg * 100)
            return OptimizerRecommendation(
                id: "cpu.\(u.pid)",
                title: "\(u.name) is using \(pct)% CPU",
                detail: "\(u.name) kept at least \(Int(u.cpuMin * 100))% of a CPU core busy across \(s.sampleCount) samples. It may be stuck or running a heavy task. Quit it, or Force Quit if it won't respond.",
                category: .cpu, impact: u.cpuAvg >= 1.5 ? .high : .medium,
                gain: "Frees \(pct)% of a core", symbol: "flame",
                quitsApps: true,
                apply: { await OptimizerProc.quit(pid: pid, expectedPath: path, name: name, force: false) },
                force: OptimizerForceAction(
                    label: "Force Quit",
                    confirm: "Force quitting \(name) discards unsaved changes in it.",
                    run: { await OptimizerProc.quit(pid: pid, expectedPath: path, name: name, force: true) }))
        }
    }

    // MARK: Energy

    @MainActor
    private static func energy(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var out: [OptimizerRecommendation] = []
        var seenPIDs = Set<pid_t>()
        for b in s.blockers {
            guard seenPIDs.insert(b.pid).inserted else { continue }
            let app = NSRunningApplication(processIdentifier: b.pid)
            let isApp = app?.activationPolicy == .regular
            guard isApp || OptimizerProc.isUserProcess(b.pid) else { continue }
            let kind = b.type.contains("Display") ? "keeps the display on" : "prevents your Mac from sleeping"
            let name = app?.localizedName ?? b.app
            let path = app?.bundleURL?.path ?? ProcessReader.path(of: b.pid)
            let pid = b.pid
            let secs = b.seconds
            let dur = secs > 60 ? " for \(Fmt.duration(TimeInterval(secs)))" : ""
            out.append(OptimizerRecommendation(
                id: "sleep.\(b.pid)",
                title: "\(name) \(kind)",
                detail: "\(name) \(kind)\(dur)" + (b.reason.isEmpty ? "." : " (\"\(b.reason)\").") + " That drains battery and stops idle sleep. Quit it if you don't need that.",
                category: .system, impact: isApp ? .medium : .low, gain: "Lets your Mac sleep", symbol: "moon.zzz",
                quitsApps: true,
                apply: { await OptimizerProc.quit(pid: pid, expectedPath: path, name: name, force: false) }))
        }
        return out
    }

    // MARK: Disk

    @MainActor
    private static func disk(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var out: [OptimizerRecommendation] = []
        let free = s.diskFreeFraction
        if free < 0.15 || s.diskAvailable < 25 << 30 {
            out.append(OptimizerRecommendation(
                id: "disk.low", title: "Low free disk space",
                detail: "Only \(Fmt.bytes(s.diskAvailable)) (\(Fmt.percent(free))) is free. macOS slows down and can't swap properly when the disk is nearly full. Use the Cleaner to find caches, logs and leftovers.",
                category: .disk, impact: free < 0.08 ? .high : .medium, gain: "More room to work", symbol: "externaldrive.badge.exclamationmark",
                link: .section("cleaner", label: "Open Cleaner")))
        }
        if s.localSnapshots > 0 {
            out.append(OptimizerRecommendation(
                id: "disk.snapshots", title: "Thin local Time Machine snapshots",
                detail: "\(s.localSnapshots) local snapshot\(s.localSnapshots == 1 ? "" : "s") are stored on this disk. Thinning removes the oldest ones to free space. Your backups on the Time Machine drive are untouched.",
                category: .disk, impact: free < 0.2 ? .high : .low, gain: "Frees purgeable space", symbol: "clock.arrow.circlepath",
                adminCommand: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"))
        }
        if s.trashBytes > 100 << 20 {
            out.append(OptimizerRecommendation(
                id: "disk.trash", title: "Empty the Trash",
                detail: "The Trash holds \(Fmt.bytes(s.trashBytes)). Emptying it is permanent. Items cannot be recovered afterwards.",
                category: .disk, impact: s.trashBytes > 5 << 30 ? .high : s.trashBytes > 1 << 30 ? .medium : .low,
                gain: "Frees \(Fmt.bytes(s.trashBytes))", symbol: "trash", irreversible: true,
                apply: {
                    let r = await Shell.runAsync("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty the trash"], timeout: 300)
                    if r.ok { return OptimizerOutcome(ok: true, message: "Trash emptied") }
                    let denied = r.stderr.contains("-1743")
                    return OptimizerOutcome(ok: false, message: denied
                        ? "Allow MacMaster to control Finder in Privacy & Security > Automation."
                        : "Couldn't empty Trash: \(OptimizerMaintenance.firstLine(r.stderr))")
                },
                estimatedDisk: s.trashBytes))
        }
        if s.spotlightEnabled == false {
            out.append(OptimizerRecommendation(
                id: "disk.spotlight", title: "Spotlight indexing is off",
                detail: "Search in Spotlight, Finder and Mail can't find new files while indexing is disabled. Turn it back on for the startup volume.",
                category: .disk, impact: .low, gain: "Working search", symbol: "magnifyingglass",
                adminCommand: "/usr/bin/mdutil -i on /"))
        }
        return out
    }

    // MARK: Startup

    @MainActor
    private static func startup(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        let n = s.startupItems.count
        guard n >= 8 else { return [] }
        return [OptimizerRecommendation(
            id: "startup.items", title: "\(n) background agents start at login",
            detail: "Third-party launch agents slow down login and use memory all day. Review them in the Toolbox and disable the ones you don't need.",
            category: .startup, impact: n > 20 ? .high : n > 12 ? .medium : .low, gain: "Faster login, less memory",
            symbol: "power", link: .section("tools", label: "Open Toolbox"))]
    }

    // MARK: System

    @MainActor
    private static func system(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var out: [OptimizerRecommendation] = []
        let days = Int(s.uptime / 86_400)
        if days >= 14 {
            out.append(OptimizerRecommendation(
                id: "system.restart", title: "Restart your Mac",
                detail: "It has been up for \(days) days. A restart clears memory leaks, swap and stuck system services, and applies pending updates.",
                category: .system, impact: days > 30 ? .high : .medium, gain: "Clears leaks and swap", symbol: "restart"))
        }
        if s.finderMemory > 1 << 30 {
            out.append(restartRecommendation(id: "system.finder", name: "Finder", memory: s.finderMemory))
        }
        if s.dockMemory > 600 << 20 {
            out.append(restartRecommendation(id: "system.dock", name: "Dock", memory: s.dockMemory))
        }
        return out
    }

    @MainActor
    private static func restartRecommendation(id: String, name: String, memory: UInt64) -> OptimizerRecommendation {
        OptimizerRecommendation(
            id: id, title: "Restart \(name)",
            detail: "\(name) is using \(Fmt.bytes(memory)), far more than usual. It relaunches automatically within a second.",
            category: .system, impact: .medium, gain: "Frees about \(Fmt.bytes(memory))", symbol: "arrow.clockwise", quitsApps: true,
            apply: {
                let r = await Shell.runAsync("/usr/bin/killall", [name], timeout: 10)
                return OptimizerOutcome(ok: r.ok, message: r.ok ? "\(name) restarted" : "Couldn't restart \(name)")
            },
            estimatedMemory: Int64(memory))
    }

    // MARK: Maintenance (only when due)

    @MainActor
    private static func maintenance(_ s: OptimizerSnapshot) -> [OptimizerRecommendation] {
        var out: [OptimizerRecommendation] = []
        for t in OptimizerMaintenance.all where OptimizerMaintenance.isDue(t) {
            let id = t.id
            var detail = t.detail
            if let last = OptimizerMaintenance.lastRun(id) {
                detail += " Last run \(last.formatted(.relative(presentation: .named)))."
            }
            var action: OptimizerAction?
            if t.run != nil {
                action = { () async -> OptimizerOutcome in await OptimizerEngine.shared.performMaintenance(id) }
            }
            out.append(OptimizerRecommendation(
                id: id, title: t.title, detail: detail, category: t.category, impact: t.impact, gain: t.gain,
                symbol: t.symbol, safe: t.safe, apply: action, adminCommand: t.adminCommand))
        }
        return out
    }
}
