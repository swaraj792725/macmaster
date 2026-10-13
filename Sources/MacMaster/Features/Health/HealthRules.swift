import Foundation
import AppKit

// MARK: - Context handed to every rule (plain value snapshot → rules are pure and testable)

struct HealthContext {
    var now: Date
    var t: HealthThresholds
    var history: [HealthSample]                       // 10 s cadence, ~1 h
    var tracks: [HealthProcTrack]
    var sysTracks: [HealthSystemGroup: HealthSysTrack]
    var frontmostPID: Int32?
    var ownPID: Int32
    var totalMemory: UInt64
    var memory: MemoryReading
    var disk: DiskReading
    var thermalState: ProcessInfo.ThermalState
    var cpuTemp: Double?
    var battery: BatteryReading
    var uptime: TimeInterval
    var crashes: [String: [Date]]                     // app → crash dates within 24 h
    var loginItemCount: Int?
    var hung: [HealthHungApp]
    var topCPU: [ProcessSample]
    var topMemory: [ProcessSample]
    var checkupFindings: [HealthFinding]
}

protocol HealthRule {
    var id: String { get }
    var title: String { get }
    var blurb: String { get }
    var symbol: String { get }
    /// Minimum seconds between notifications for the same issue key.
    var cooldown: TimeInterval { get }
    func evaluate(_ ctx: HealthContext) -> [HealthFinding]
}

extension HealthRule {
    var cooldown: TimeInterval { 30 * 60 }
}

// MARK: - Helpers

enum HealthMath {
    /// Contiguous run at the tail of `vals` with value ≥ `floor`.
    static func sustained(_ vals: [HealthTimedValue], floor: Double, step: TimeInterval, now: Date) -> (duration: TimeInterval, mean: Double) {
        guard let last = vals.last, now.timeIntervalSince(last.t) <= step * 2.5 else { return (0, 0) }
        var count = 0
        var sum = 0.0
        for v in vals.reversed() {
            if v.v >= floor { count += 1; sum += v.v } else { break }
        }
        guard count > 0 else { return (0, 0) }
        return (Double(count) * step, sum / Double(count))
    }

    /// Least-squares slope (units/second) and R² of a timed series.
    static func regression(_ vals: [HealthTimedValue]) -> (slope: Double, r2: Double, span: TimeInterval)? {
        guard vals.count >= 3, let first = vals.first, let last = vals.last else { return nil }
        let xs = vals.map { $0.t.timeIntervalSince(first.t) }
        let ys = vals.map { $0.v }
        let n = Double(vals.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<vals.count {
            sxx += (xs[i] - mx) * (xs[i] - mx)
            sxy += (xs[i] - mx) * (ys[i] - my)
            syy += (ys[i] - my) * (ys[i] - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        return (slope, r2, last.t.timeIntervalSince(first.t))
    }

    static func minutes(_ s: TimeInterval) -> String {
        s >= 3600 ? String(format: "%.1f h", s / 3600) : "\(max(1, Int((s / 60).rounded()))) min"
    }
}

enum HealthSafety {
    /// Never offer to quit system processes or ourselves.
    static func canQuit(pid: Int32, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard pid > 1, pid != ownPID else { return false }
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return true }
        guard let path = ProcessReader.path(of: pid) else { return false }
        let blocked = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db"]
        return !blocked.contains { path.hasPrefix($0) }
    }

    static func quitActions(_ pid: Int32, _ name: String, ownPID: Int32, restart: Bool) -> [HealthFixAction] {
        guard canQuit(pid: pid, ownPID: ownPID) else { return [] }
        var a: [HealthFixAction] = []
        if restart, NSRunningApplication(processIdentifier: pid)?.bundleURL != nil { a.append(.restartApp(pid: pid, name: name)) }
        a.append(.quit(pid: pid, name: name))
        a.append(.forceQuit(pid: pid, name: name))
        return a
    }
}


enum HealthRules {
    static let all: [HealthRule] = [
        HealthRunawayRule(), HealthLeakRule(), HealthMemoryPressureRule(), HealthDiskRule(),
        HealthThermalRule(), HealthBatteryRule(), HealthLoginItemsRule(), HealthSystemProcessRule(),
        HealthCrashRule(), HealthUptimeRule(), HealthHungRule(), HealthCheckupRule(),
    ]
    static func rule(id: String) -> HealthRule? { all.first { $0.id == id } }
}

// MARK: 1. Runaway process

struct HealthRunawayRule: HealthRule {
    let id = "runaway"
    let title = "Runaway processes"
    let blurb = "An app pinning a CPU core for minutes."
    let symbol = "flame.fill"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        var out: [HealthFinding] = []
        for tr in ctx.tracks where tr.pid != ctx.ownPID {
            let (dur, mean) = HealthMath.sustained(tr.cpu, floor: ctx.t.runawayCPU * 0.7, step: 10, now: ctx.now)
            guard dur >= ctx.t.runawaySeconds, mean >= ctx.t.runawayCPU else { continue }
            let foreground = tr.pid == ctx.frontmostPID
            var sev: HealthSeverity = dur >= 600 ? .critical : .warning
            if foreground { sev = .info }   // user is probably actively using it
            let detail = foreground
                ? "\(tr.name) is in the foreground and has averaged \(Int(mean * 100))% of a core for \(HealthMath.minutes(dur)). Likely intentional heavy work."
                : "\(tr.name) has averaged \(Int(mean * 100))% of a core for \(HealthMath.minutes(dur)). It may be stuck in a loop and is draining battery and generating heat."
            var actions = HealthSafety.quitActions(tr.pid, tr.name, ownPID: ctx.ownPID, restart: false)
            actions.append(.ignoreApp(name: tr.name))
            out.append(HealthFinding(key: "runaway:\(tr.pid)", ruleID: id, severity: sev,
                                     title: "\(tr.name) is using a lot of CPU", detail: detail,
                                     actions: actions, appName: tr.name))
        }
        return out
    }
}

// MARK: 2. Memory leak suspect

struct HealthLeakRule: HealthRule {
    let id = "leak"
    let title = "Memory leak suspects"
    let blurb = "An app whose memory keeps growing, or hogs RAM."
    let symbol = "memorychip.fill"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        var out: [HealthFinding] = []
        let ramLimit = Double(ctx.totalMemory) * ctx.t.leakRAMFraction
        for tr in ctx.tracks where tr.pid != ctx.ownPID {
            var reason: String?
            var sev: HealthSeverity = .warning
            if tr.mem.count >= 40, let reg = HealthMath.regression(tr.mem), reg.span >= 20 * 60 {
                let growth = reg.slope * reg.span
                if growth > ctx.t.leakGrowthBytes, reg.r2 >= 0.85 {
                    reason = "\(tr.name)'s memory has grown steadily by \(Fmt.bytes(Int64(growth))) over \(HealthMath.minutes(reg.span)) (now \(Fmt.bytes(tr.memory)))."
                }
            }
            if reason == nil, Double(tr.memory) > ramLimit, ctx.totalMemory > 0 {
                let pct = Int(Double(tr.memory) / Double(ctx.totalMemory) * 100)
                reason = "\(tr.name) is using \(Fmt.bytes(tr.memory)), \(pct)% of your Mac's memory."
                if Double(tr.memory) > Double(ctx.totalMemory) * 0.5 { sev = .critical }
            }
            guard let reason else { continue }
            var actions = HealthSafety.quitActions(tr.pid, tr.name, ownPID: ctx.ownPID, restart: true)
            actions.append(.ignoreApp(name: tr.name))
            out.append(HealthFinding(key: "leak:\(tr.pid)", ruleID: id, severity: sev,
                                     title: "\(tr.name) may be leaking memory", detail: reason,
                                     actions: actions, appName: tr.name))
        }
        return out
    }
}

// MARK: 3. Memory pressure

struct HealthMemoryPressureRule: HealthRule {
    let id = "memory"
    let title = "Memory pressure & swap"
    let blurb = "Sustained memory pressure or heavy, growing swap."
    let symbol = "gauge.with.dots.needle.67percent"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        var reasons: [String] = []
        var sev: HealthSeverity = .warning

        var run = 0
        var sawCritical = false
        for s in ctx.history.reversed() {
            if s.pressure >= 2 { run += 1; if s.pressure >= 4 { sawCritical = true } } else { break }
        }
        let dur = Double(run) * 10
        if dur >= ctx.t.pressureSeconds {
            reasons.append("Memory pressure has been \(sawCritical ? "critical" : "elevated") for \(HealthMath.minutes(dur)).")
            if sawCritical { sev = .critical }
        }

        let swap = ctx.memory.swapUsed
        if swap > ctx.t.swapBytes {
            // growing: compare with ~10 min ago
            let ref = ctx.history.first { ctx.now.timeIntervalSince($0.date) <= 600 }?.swapUsed
            if let ref, Double(swap) > Double(ref) + 200_000_000 {
                reasons.append("Swap use is \(Fmt.bytes(swap)) and still growing.")
            }
        }
        guard !reasons.isEmpty else { return [] }

        let top = ctx.topMemory.prefix(3).map { "\($0.name) (\(Fmt.bytes($0.memory)))" }.joined(separator: ", ")
        var detail = reasons.joined(separator: " ")
        if !top.isEmpty { detail += " Biggest memory users: \(top)." }
        var actions: [HealthFixAction] = [.showTopMemory, .freeRAM]
        if let p = ctx.topMemory.first(where: { HealthSafety.canQuit(pid: $0.pid, ownPID: ctx.ownPID) }) {
            actions.append(.quit(pid: p.pid, name: p.name))
        }
        return [HealthFinding(key: "memory.pressure", ruleID: id, severity: sev,
                              title: "Your Mac is running low on memory", detail: detail, actions: actions)]
    }
}

// MARK: 4. Disk

struct HealthDiskRule: HealthRule {
    let id = "disk"
    let title = "Low disk space"
    let blurb = "Startup disk nearly full."
    let symbol = "internaldrive.fill"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        let d = ctx.disk
        guard d.total > 0 else { return [] }
        let frac = Double(d.available) / Double(d.total)
        guard frac < ctx.t.diskFreeFraction || d.available < ctx.t.diskFreeBytes else { return [] }
        let sev: HealthSeverity = d.available < ctx.t.diskCriticalBytes ? .critical : .warning
        return [HealthFinding(
            key: "disk.low", ruleID: id, severity: sev,
            title: "Startup disk is almost full",
            detail: "Only \(Fmt.bytes(d.available)) free (\(Int(frac * 100))% of \(Fmt.bytes(d.total))). Low space slows your Mac and can break updates.",
            actions: [.openSection("cleaner", label: "Open Cleaner")])]
    }
}

// MARK: 5. Thermal

struct HealthThermalRule: HealthRule {
    let id = "thermal"
    let title = "Overheating"
    let blurb = "Serious thermal state or sustained high CPU temperature."
    let symbol = "thermometer.high"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        var reasons: [String] = []
        var sev: HealthSeverity = .warning
        switch ctx.thermalState {
        case .serious: reasons.append("macOS reports a serious thermal state and is throttling performance.")
        case .critical: reasons.append("macOS reports a critical thermal state."); sev = .critical
        default: break
        }
        var run = 0
        for s in ctx.history.reversed() {
            if let t = s.cpuTemp, t > ctx.t.tempC { run += 1 } else { break }
        }
        if Double(run) * 10 >= ctx.t.tempSeconds, let t = ctx.cpuTemp {
            reasons.append("CPU has been above \(Int(ctx.t.tempC))°C for \(HealthMath.minutes(Double(run) * 10)) (now \(Fmt.temperature(t))).")
        }
        guard !reasons.isEmpty else { return [] }
        let top = ctx.topCPU.prefix(3).map { "\($0.name) (\(Int($0.cpu * 100))%)" }.joined(separator: ", ")
        var detail = reasons.joined(separator: " ")
        if !top.isEmpty { detail += " Busiest apps: \(top)." }
        return [HealthFinding(key: "thermal.hot", ruleID: id, severity: sev, title: "Your Mac is running hot",
                              detail: detail, actions: [.showTopCPU])]
    }
}

// MARK: 6. Battery

struct HealthBatteryRule: HealthRule {
    let id = "battery"
    let title = "Battery health"
    let blurb = "Low capacity, hot while charging, or fast drain."
    let symbol = "battery.50percent"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        let b = ctx.battery
        guard b.isPresent else { return [] }
        var out: [HealthFinding] = []

        if b.health < 0.8, b.designCapacity > 0 {
            out.append(HealthFinding(
                key: "battery.health", ruleID: id, severity: .info,
                title: "Battery capacity is down to \(Int(b.health * 100))%",
                detail: "Maximum capacity has dropped below 80% of design after \(b.cycleCount) cycles. Runtime on battery will be noticeably shorter; consider a battery service.",
                actions: [.openSection("battery", label: "Open Battery")]))
        }
        if b.isCharging, let t = b.temperature, t > 40 {
            out.append(HealthFinding(
                key: "battery.temp", ruleID: id, severity: .warning,
                title: "Battery is hot while charging",
                detail: "Battery temperature is \(Fmt.temperature(t)). Sustained heat accelerates battery wear. Move the Mac off soft surfaces and close heavy apps.",
                actions: [.showTopCPU]))
        }
        // Fast drain over the last window while unplugged.
        let window = ctx.history.filter { ctx.now.timeIntervalSince($0.date) <= ctx.t.drainSeconds + 15 }
        if window.count >= 2, window.allSatisfy({ $0.onBattery }),
           let first = window.first, let last = window.last,
           let p0 = first.batteryPercent, let p1 = last.batteryPercent {
            let span = last.date.timeIntervalSince(first.date)
            if span >= ctx.t.drainSeconds * 0.9 {
                let perHour = (p0 - p1) / (span / 3600)
                if perHour > ctx.t.drainPerHour {
                    let top = ctx.topCPU.prefix(3).map { $0.name }.joined(separator: ", ")
                    out.append(HealthFinding(
                        key: "battery.drain", ruleID: id, severity: .warning,
                        title: "Battery is draining unusually fast",
                        detail: "Losing about \(Int(perHour * 100))% per hour on battery." + (top.isEmpty ? "" : " Top energy users: \(top)."),
                        actions: [.showTopCPU]))
                }
            }
        }
        return out
    }
}

// MARK: 7. Login items

struct HealthLoginItemsRule: HealthRule {
    let id = "loginItems"
    let title = "Too many startup items"
    let blurb = "Many third-party launch agents / daemons."
    let symbol = "power"
    var cooldown: TimeInterval { 24 * 3600 }

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        guard let n = ctx.loginItemCount, n > ctx.t.loginItems else { return [] }
        return [HealthFinding(
            key: "login.items", ruleID: id, severity: .info,
            title: "\(n) third-party startup items",
            detail: "Lots of background launch agents and daemons slow down startup and use memory. Review which ones you still need.",
            actions: [.openSection("tools", label: "Open Tools")])]
    }
}

// MARK: 8. Kernel / system processes

struct HealthSystemProcessRule: HealthRule {
    let id = "system"
    let title = "System processes"
    let blurb = "kernel_task, Spotlight, WindowServer, iCloud, Photos."
    let symbol = "gearshape.2.fill"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        var out: [HealthFinding] = []
        func check(_ g: HealthSystemGroup, _ thr: Double, _ secs: TimeInterval) -> (TimeInterval, Double)? {
            guard let tr = ctx.sysTracks[g] else { return nil }
            let (dur, mean) = HealthMath.sustained(tr.cpu, floor: thr * 0.7, step: 30, now: ctx.now)
            return dur >= secs && mean >= thr ? (dur, mean) : nil
        }

        if let (dur, mean) = check(.kernel, ctx.t.kernelTaskCPU, ctx.t.kernelSeconds) {
            let hot = ctx.thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue
            out.append(HealthFinding(
                key: "sys.kernel", ruleID: id, severity: .warning,
                title: "kernel_task is working hard",
                detail: "kernel_task has used ~\(Int(mean))% CPU for \(HealthMath.minutes(dur)). macOS does this to throttle the CPU when the Mac is too hot" + (hot ? " — the thermal state is elevated right now." : ". Check ventilation, charging cable/adapter and busy apps."),
                actions: [.showTopCPU]))
        }
        if let (dur, mean) = check(.spotlight, ctx.t.spotlightCPU, ctx.t.spotlightSeconds) {
            out.append(HealthFinding(
                key: "sys.spotlight", ruleID: id, severity: .info,
                title: "Spotlight is indexing heavily",
                detail: "mds/mdworker have used ~\(Int(mean))% CPU for \(HealthMath.minutes(dur)). This is normal after big file changes or an update, but if it never finishes the index may be corrupted. Rebuilding it fixes that (takes a while and needs admin rights).",
                actions: [.rebuildSpotlight]))
        }
        if let (dur, mean) = check(.windowServer, ctx.t.windowServerCPU, ctx.t.windowServerSeconds) {
            out.append(HealthFinding(
                key: "sys.windowserver", ruleID: id, severity: .info,
                title: "WindowServer is busy",
                detail: "WindowServer (draws everything on screen) has used ~\(Int(mean))% CPU for \(HealthMath.minutes(dur)). Common causes: many displays, heavy transparency/animation, screen recording or a misbehaving app redrawing constantly."))
        }
        if let (dur, mean) = check(.photos, ctx.t.backgroundCPU, ctx.t.backgroundSeconds) {
            out.append(HealthFinding(
                key: "sys.photos", ruleID: id, severity: .info,
                title: "Photos is analysing your library",
                detail: "photoanalysisd has used ~\(Int(mean))% CPU for \(HealthMath.minutes(dur)). It scans faces and scenes in the background, usually only while plugged in and idle. It finishes by itself."))
        }
        if let (dur, mean) = check(.icloud, ctx.t.backgroundCPU, ctx.t.backgroundSeconds) {
            out.append(HealthFinding(
                key: "sys.icloud", ruleID: id, severity: .info,
                title: "iCloud is syncing heavily",
                detail: "bird/cloudd have used ~\(Int(mean))% CPU for \(HealthMath.minutes(dur)). This happens while iCloud Drive uploads or downloads lots of files and should settle once sync completes."))
        }
        return out
    }
}

// MARK: 9. Crashing apps

struct HealthCrashRule: HealthRule {
    let id = "crashes"
    let title = "Repeated app crashes"
    let blurb = "The same app crashing 3+ times in 24 hours."
    let symbol = "ladybug.fill"
    var cooldown: TimeInterval { 6 * 3600 }

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        ctx.crashes.compactMap { app, dates in
            guard dates.count >= ctx.t.crashCount else { return nil }
            let latest = dates.max() ?? ctx.now
            return HealthFinding(
                key: "crash:\(app)", ruleID: id, severity: .warning,
                title: "\(app) keeps crashing",
                detail: "\(app) crashed \(dates.count) times in the last 24 hours (latest \(latest.formatted(date: .omitted, time: .shortened))). Corrupted preferences or caches are a common cause — resetting the app's data often fixes it.",
                actions: [.openSection("uninstaller", label: "Reset app data"), .ignoreApp(name: app)],
                appName: app)
        }
    }
}

// MARK: 10. Uptime

struct HealthUptimeRule: HealthRule {
    let id = "uptime"
    let title = "Restart overdue"
    let blurb = "Long uptime combined with high swap."
    let symbol = "clock.arrow.circlepath"
    var cooldown: TimeInterval { 24 * 3600 }

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        guard ctx.uptime > ctx.t.uptimeDays * 86_400, ctx.memory.swapUsed > ctx.t.uptimeSwapBytes else { return [] }
        return [HealthFinding(
            key: "uptime.restart", ruleID: id, severity: .info,
            title: "A restart would help",
            detail: "Your Mac has been up for \(Int(ctx.uptime / 86_400)) days and is using \(Fmt.bytes(ctx.memory.swapUsed)) of swap. Restarting clears leaked memory and applies pending updates.",
            actions: [.restartMac])]
    }
}

// MARK: 11. Hung apps

struct HealthHungRule: HealthRule {
    let id = "hung"
    let title = "Unresponsive apps"
    let blurb = "Apps that stop answering for 30+ seconds (needs Accessibility)."
    let symbol = "hourglass"

    func evaluate(_ ctx: HealthContext) -> [HealthFinding] {
        ctx.hung.map { h in
            var actions: [HealthFixAction] = []
            if HealthSafety.canQuit(pid: h.pid, ownPID: ctx.ownPID) {
                actions = [.forceQuit(pid: h.pid, name: h.name), .restartApp(pid: h.pid, name: h.name)]
            }
            actions.append(.ignoreApp(name: h.name))
            return HealthFinding(key: "hung:\(h.pid)", ruleID: id, severity: .warning,
                                 title: "\(h.name) isn't responding",
                                 detail: "\(h.name) hasn't answered system requests for \(HealthMath.minutes(ctx.now.timeIntervalSince(h.since))). It may be frozen.",
                                 actions: actions, appName: h.name)
        }
    }
}

// MARK: Checkup-derived findings (SMART, backups, updates)

struct HealthCheckupRule: HealthRule {
    let id = "checkup"
    let title = "Checkup findings"
    let blurb = "Disk SMART status, stale backups, pending updates."
    let symbol = "checklist"
    var cooldown: TimeInterval { 24 * 3600 }
    func evaluate(_ ctx: HealthContext) -> [HealthFinding] { ctx.checkupFindings }
}
