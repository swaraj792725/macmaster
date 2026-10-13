import Foundation
import AppKit
import Darwin

// MARK: - Snapshot types (Sendable, produced off the main thread)

struct OptimizerRunningApp: Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var bundlePath: String?
    var isRegular: Bool
}

/// One app (with its helper processes rolled up) or one stand-alone user process.
struct OptimizerUsage: Identifiable, Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var path: String?           // bundle path for apps, executable path otherwise
    var memory: UInt64
    var cpuMin: Double          // lowest CPU across samples (1.0 = one core)
    var cpuMax: Double
    var cpuAvg: Double
    var isApp: Bool
    var isFrontmost: Bool
    var isUserOwned: Bool
    var id: pid_t { pid }
}

struct OptimizerBlocker: Sendable, Identifiable {
    var pid: pid_t
    var app: String
    var type: String
    var reason: String
    var seconds: Int
    var id: String { "\(pid)-\(type)" }
}

struct OptimizerSnapshot: Sendable {
    var date = Date()
    var sampleCount = 0
    var measure = OptimizerMeasure.read()
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure = 1
    var diskTotal: Int64 = 0
    var diskAvailable: Int64 = 0     // "important usage" (what Finder shows)
    var uptime: TimeInterval = 0
    var usage: [OptimizerUsage] = []
    var blockers: [OptimizerBlocker] = []
    var localSnapshots = 0
    var trashBytes: Int64 = 0
    var spotlightEnabled: Bool?
    var spotlightText = ""
    var startupItems: [String] = []
    var finderMemory: UInt64 = 0
    var dockMemory: UInt64 = 0

    var diskFreeFraction: Double { diskTotal > 0 ? Double(diskAvailable) / Double(diskTotal) : 1 }
    var memUsedFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
}

// MARK: - Process helpers

enum OptimizerProc {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
                                 "/Library/Apple/", "/private/var/", "/usr/lib/"]

    static func isSystemPath(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    static func ownerUID(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? info.pbi_uid : nil
    }

    /// True only for processes owned by the current user that do not live in system locations.
    static func isUserProcess(_ pid: pid_t) -> Bool {
        guard pid > 1, ownerUID(of: pid) == getuid() else { return false }
        guard let path = ProcessReader.path(of: pid) else { return false }
        return !isSystemPath(path)
    }

    static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    /// Gracefully (or forcefully) quits a process. Verifies identity before touching a raw pid.
    @MainActor
    static func quit(pid: pid_t, expectedPath: String?, name: String, force: Bool) async -> OptimizerOutcome {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let expected = expectedPath, let bundle = app.bundleURL?.path, bundle != expected {
                return OptimizerOutcome(ok: false, message: "\(name) changed since the scan. Skipped.")
            }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil {
                return OptimizerOutcome(ok: false, message: "MacMaster won't quit itself.")
            }
            _ = force ? app.forceTerminate() : app.terminate()
            for _ in 0..<16 {
                if app.isTerminated { return OptimizerOutcome(ok: true, message: "Quit \(name)") }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return OptimizerOutcome(ok: false, message: "\(name) didn't quit. It may be asking to save changes.")
        }
        guard isUserProcess(pid) else {
            return OptimizerOutcome(ok: false, message: "\(name) is no longer running or isn't a user process.")
        }
        if let expected = expectedPath, ProcessReader.path(of: pid) != expected {
            return OptimizerOutcome(ok: false, message: "\(name) changed since the scan. Skipped.")
        }
        kill(pid, force ? SIGKILL : SIGTERM)
        for _ in 0..<16 {
            if kill(pid, 0) != 0 { return OptimizerOutcome(ok: true, message: "Stopped \(name)") }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return OptimizerOutcome(ok: false, message: "\(name) is still running.")
    }
}

// MARK: - Analyzer

enum OptimizerAnalyzer {
    /// Gathers everything that is not process-sample based. Blocking; call off the main thread.
    static func collectSystem(progress: @escaping @Sendable (String) -> Void) -> OptimizerSnapshot {
        var s = OptimizerSnapshot()
        let mem = MemoryReader.read()
        s.memTotal = mem.total; s.memUsed = mem.used; s.memCached = mem.cached
        s.swapUsed = mem.swapUsed; s.pressure = mem.pressureLevel
        s.uptime = SystemInfo.uptime

        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            s.diskAvailable = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        }

        progress("Checking sleep blockers…")
        s.blockers = readBlockers()

        progress("Looking at disk and snapshots…")
        let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15)
        if snaps.ok {
            s.localSnapshots = snaps.stdout.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        }
        let md = Shell.run("/usr/bin/mdutil", ["-s", "/"], timeout: 10)
        if md.ok {
            let t = md.stdout.lowercased()
            s.spotlightText = md.stdout.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if t.contains("indexing enabled") { s.spotlightEnabled = true }
            else if t.contains("indexing disabled") { s.spotlightEnabled = false }
        }
        s.trashBytes = trashSize()

        progress("Counting startup items…")
        s.startupItems = startupItems()
        return s
    }

    /// Rolls per-process samples up into apps and stand-alone processes. Blocking; call off the main thread.
    static func collectProcesses(apps: [OptimizerRunningApp], frontPID: pid_t, samples: [[ProcessSample]],
                                 into snap: inout OptimizerSnapshot) {
        snap.sampleCount = samples.count
        let n = max(1, samples.count)
        var memory: [pid_t: UInt64] = [:]
        var names: [pid_t: String] = [:]
        for p in samples.last ?? [] { memory[p.pid] = p.memory; names[p.pid] = p.name }
        let cpuBySample: [[pid_t: Double]] = samples.map { sample in
            Dictionary(sample.map { ($0.pid, $0.cpu) }, uniquingKeysWith: +)
        }
        let appPIDs = Set(apps.map(\.pid))
        var candidates: [pid_t] = []
        for (pid, mem) in memory {
            let busy = cpuBySample.contains { ($0[pid] ?? 0) > 0.03 }
            if mem >= 20 << 20 || busy || appPIDs.contains(pid) { candidates.append(pid) }
        }
        var paths: [pid_t: String] = [:]
        for pid in candidates { if let p = ProcessReader.path(of: pid) { paths[pid] = p } }

        func cpuSeries(_ members: [pid_t]) -> [Double] {
            (0..<n).map { i in
                guard i < cpuBySample.count else { return 0 }
                return members.reduce(0) { $0 + (cpuBySample[i][$1] ?? 0) }
            }
        }

        var assigned = Set<pid_t>()
        var out: [OptimizerUsage] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        for app in apps where app.isRegular {
            guard let bp = app.bundlePath, app.pid != myPID else { continue }
            let members = candidates.filter { $0 == app.pid || (paths[$0]?.hasPrefix(bp + "/") ?? false) }
            assigned.formUnion(members)
            let mem = members.reduce(UInt64(0)) { $0 + (memory[$1] ?? 0) }
            let series = cpuSeries(members)
            out.append(OptimizerUsage(
                pid: app.pid, name: app.name, bundleID: app.bundleID, path: bp, memory: mem,
                cpuMin: series.min() ?? 0, cpuMax: series.max() ?? 0,
                cpuAvg: series.reduce(0, +) / Double(n), isApp: true,
                isFrontmost: app.pid == frontPID || members.contains(frontPID),
                isUserOwned: true))
        }

        for pid in candidates where !assigned.contains(pid) && pid != myPID {
            let series = cpuSeries([pid])
            guard (series.max() ?? 0) > 0.3 else { continue }   // only interesting stand-alone processes
            let owned = OptimizerProc.isUserProcess(pid)
            out.append(OptimizerUsage(
                pid: pid, name: names[pid] ?? "pid \(pid)", bundleID: nil, path: paths[pid],
                memory: memory[pid] ?? 0, cpuMin: series.min() ?? 0, cpuMax: series.max() ?? 0,
                cpuAvg: series.reduce(0, +) / Double(n), isApp: false, isFrontmost: false, isUserOwned: owned))
        }
        snap.usage = out

        for pid in candidates {
            guard let p = paths[pid] else { continue }
            if p.hasPrefix("/System/Library/CoreServices/Finder.app") { snap.finderMemory = max(snap.finderMemory, memory[pid] ?? 0) }
            if p.hasPrefix("/System/Library/CoreServices/Dock.app") { snap.dockMemory = max(snap.dockMemory, memory[pid] ?? 0) }
        }
    }

    // MARK: Pieces

    /// Parses `pmset -g assertions` for apps that keep the Mac awake.
    static func readBlockers() -> [OptimizerBlocker] {
        let r = Shell.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 10)
        guard r.ok,
              let re = try? NSRegularExpression(
                pattern: #"pid (\d+)\((.+?)\):\s+\[0x[0-9a-fA-F]+\]\s+(\d+):(\d+):(\d+)\s+(\w+)\s+named:\s+"(.*?)""#)
        else { return [] }
        var seen = Set<String>()
        var out: [OptimizerBlocker] = []
        for line in r.stdout.split(separator: "\n") {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            let type = g(6)
            guard type.hasPrefix("Prevent") || type.hasPrefix("NoIdle") || type.hasPrefix("NoDisplay") else { continue }
            let app = g(2)
            if ["powerd", "caffeinate", "coreaudiod"].contains(app) { continue }
            let secs = (Int(g(3)) ?? 0) * 3600 + (Int(g(4)) ?? 0) * 60 + (Int(g(5)) ?? 0)
            let b = OptimizerBlocker(pid: pid_t(g(1)) ?? 0, app: app, type: type, reason: g(7), seconds: secs)
            if b.pid > 0, seen.insert(b.id).inserted { out.append(b) }
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    static func trashSize() -> Int64 {
        let trash = AppPaths.home.appendingPathComponent(".Trash")
        guard let items = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return 0 }
        return items.reduce(Int64(0)) { $0 + AppPaths.allocatedSize(of: $1) }
    }

    /// Third-party LaunchAgents that run at load (user + system agents).
    static func startupItems() -> [String] {
        let dirs = [AppPaths.home.appendingPathComponent("Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchAgents")]
        var names: [String] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "plist" {
                let label = f.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                guard let data = try? Data(contentsOf: f),
                      let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
                else { continue }
                if (dict["Disabled"] as? Bool) == true { continue }
                if (dict["RunAtLoad"] as? Bool) == true || dict["KeepAlive"] != nil { names.append(label) }
            }
        }
        return names.sorted()
    }
}

// MARK: - Scoring

enum OptimizerScoring {
    static let hogThreshold = 0.8   // 80% of one core, sustained

    static func hogs(_ s: OptimizerSnapshot, threshold: Double = hogThreshold) -> [OptimizerUsage] {
        guard s.sampleCount >= 2 else { return [] }
        return s.usage
            .filter { $0.isUserOwned && $0.cpuMin >= threshold && !isProtected($0) }
            .sorted { $0.cpuAvg > $1.cpuAvg }
    }

    static func idleHeavyApps(_ s: OptimizerSnapshot) -> [OptimizerUsage] {
        s.usage
            .filter { $0.isApp && !$0.isFrontmost && !isProtected($0) && $0.memory >= 400 << 20 && $0.cpuMax < 0.05 }
            .sorted { $0.memory > $1.memory }
    }

    /// Things the optimizer must never offer to quit.
    static func isProtected(_ u: OptimizerUsage) -> Bool {
        if let id = u.bundleID, ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                                 "com.apple.loginwindow", "com.apple.WindowManager"].contains(id) { return true }
        if let p = u.path, p.hasPrefix("/System/Library/CoreServices/") { return true }
        if u.name == "WindowServer" || u.name == "kernel_task" { return true }
        return false
    }

    static func evaluate(_ s: OptimizerSnapshot) -> (score: Int, factors: [OptimizerScoreFactor]) {
        var factors: [OptimizerScoreFactor] = []
        let gb = 1_073_741_824.0

        // Memory
        var mem = 0
        var memNote = "Plenty of headroom"
        if s.pressure >= 4 { mem += 22; memNote = "Memory pressure is critical" }
        else if s.pressure >= 2 { mem += 10; memNote = "Memory pressure is elevated" }
        if s.memUsedFraction > 0.92 { mem += 6 } else if s.memUsedFraction > 0.85 { mem += 3 }
        let swapGB = Double(s.swapUsed) / gb
        if swapGB > 4 { mem += 8; if mem < 20 { memNote = String(format: "%.1f GB swapped to disk", swapGB) } }
        else if swapGB > 1 { mem += 4; memNote = String(format: "%.1f GB swapped to disk", swapGB) }
        else if swapGB > 0.25 { mem += 1 }
        let idleGB = Double(OptimizerScoring.idleHeavyApps(s).reduce(UInt64(0)) { $0 + $1.memory }) / gb
        if idleGB > 4 { mem += 4 } else if idleGB > 2 { mem += 2 }
        if mem > 0 && memNote == "Plenty of headroom" { memNote = "Idle apps are holding memory" }
        factors.append(OptimizerScoreFactor(id: "memory", title: "Memory", symbol: "memorychip", penalty: min(mem, 40),
                                            note: memNote, colors: OptimizerCategory.memory.colors))

        // CPU
        let hogList = hogs(s)
        let cpuPenalty = min(hogList.count * 8, 20)
        let cpuNote = hogList.first.map { "\($0.name) is using \(Int($0.cpuAvg * 100))% of a core" } ?? "Nothing is hogging the CPU"
        factors.append(OptimizerScoreFactor(id: "cpu", title: "CPU", symbol: "cpu", penalty: cpuPenalty,
                                            note: cpuNote, colors: OptimizerCategory.cpu.colors))

        // Disk
        var disk = 0
        var diskNote = "Healthy free space"
        let free = s.diskFreeFraction
        if free < 0.05 { disk += 20 } else if free < 0.10 { disk += 12 } else if free < 0.20 { disk += 5 }
        if disk > 0 { diskNote = "Only \(Fmt.bytes(s.diskAvailable)) free (\(Fmt.percent(free)))" }
        if s.localSnapshots > 3 && free < 0.25 { disk += 3; if diskNote == "Healthy free space" { diskNote = "\(s.localSnapshots) local snapshots" } }
        if s.trashBytes > 5 << 30 { disk += 2; if diskNote == "Healthy free space" { diskNote = "\(Fmt.bytes(s.trashBytes)) in the Trash" } }
        factors.append(OptimizerScoreFactor(id: "disk", title: "Disk", symbol: "internaldrive", penalty: min(disk, 25),
                                            note: diskNote, colors: OptimizerCategory.disk.colors))

        // Startup
        let startup = s.startupItems.count
        let startPenalty = startup > 20 ? 8 : startup > 12 ? 5 : startup > 8 ? 3 : 0
        factors.append(OptimizerScoreFactor(
            id: "startup", title: "Startup", symbol: "power", penalty: startPenalty,
            note: startup == 0 ? "No extra background agents" : "\(startup) background agents start at login",
            colors: OptimizerCategory.startup.colors))

        // Uptime
        let days = s.uptime / 86_400
        let upPenalty = days > 30 ? 10 : days > 14 ? 6 : days > 7 ? 2 : 0
        let upNote = days >= 1 ? "Up for \(Int(days)) days" : "Restarted recently"
        factors.append(OptimizerScoreFactor(id: "uptime", title: "Uptime", symbol: "clock", penalty: upPenalty,
                                            note: upNote, colors: OptimizerCategory.system.colors))

        // Energy
        let blockers = s.blockers.filter { NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular }.count
        factors.append(OptimizerScoreFactor(
            id: "energy", title: "Energy", symbol: "bolt.fill", penalty: min(blockers * 2, 6),
            note: blockers == 0 ? "Nothing is preventing sleep" : "\(blockers) app\(blockers == 1 ? "" : "s") preventing sleep",
            colors: OptimizerCategory.visual.colors))

        let total = factors.reduce(0) { $0 + $1.penalty }
        return (max(0, min(100, 100 - total)), factors)
    }
}
