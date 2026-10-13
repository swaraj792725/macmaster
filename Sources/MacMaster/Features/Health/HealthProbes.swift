import Foundation
import AppKit
import ApplicationServices

// MARK: - System process groups (root processes whose rusage we can't read)

enum HealthSystemGroup: String, CaseIterable {
    case kernel, spotlight, windowServer, photos, icloud

    static func group(for name: String) -> HealthSystemGroup? {
        switch name {
        case "kernel_task": return .kernel
        case "mds", "mds_stores": return .spotlight
        case "WindowServer": return .windowServer
        case "photoanalysisd": return .photos
        case "bird", "cloudd": return .icloud
        default: return name.hasPrefix("mdworker") ? .spotlight : nil
        }
    }
}

struct HealthSysTrack {
    var cpu: [HealthTimedValue] = []   // percent (100 = one core), 30 s cadence
}

// MARK: - `ps` supplemental sampler

enum HealthPS {
    /// Parses `ps -Ao pid,pcpu,rss,comm` and sums %CPU per watched group.
    static func parse(_ output: String) -> [HealthSystemGroup: Double] {
        var sums: [HealthSystemGroup: Double] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let cpu = Double(parts[1]) else { continue }
            let comm = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let name = (comm as NSString).lastPathComponent
            if let g = HealthSystemGroup.group(for: name) { sums[g, default: 0] += cpu }
        }
        return sums
    }

    static func sample() -> [HealthSystemGroup: Double] {
        let r = Shell.run("/bin/ps", ["-Ao", "pid,pcpu,rss,comm"], timeout: 10)
        return r.ok ? parse(r.stdout) : [:]
    }
}

// MARK: - Crash reports

struct HealthCrashScan {
    var crashes: [String: [Date]] = [:]   // app → dates within 24 h
    var files: Set<String> = []
}

enum HealthCrashReports {
    static var directory: URL { AppPaths.home.appendingPathComponent("Library/Logs/DiagnosticReports") }

    static func appName(fromFile file: String) -> String? {
        let ext = (file as NSString).pathExtension.lowercased()
        guard ext == "ips" || ext == "crash" else { return nil }
        let skip = ["JetsamEvent", "Retired", "ResetCounter", "stacks", "log-aggregated", "ExcUserFault", "ExcResource"]
        if skip.contains(where: { file.hasPrefix($0) }) { return nil }
        let base = (file as NSString).deletingPathExtension
        guard let re = try? NSRegularExpression(pattern: #"^(.+?)[-_ ]\d{4}-\d{2}-\d{2}[-_ ]\d{6}"#) else { return base }
        let range = NSRange(base.startIndex..., in: base)
        if let m = re.firstMatch(in: base, range: range), let r = Range(m.range(at: 1), in: base) {
            return String(base[r])
        }
        return base
    }

    static func scan(now: Date = Date()) -> HealthCrashScan {
        var result = HealthCrashScan()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return result }
        let cutoff = now.addingTimeInterval(-86_400)
        for url in urls {
            guard let app = appName(fromFile: url.lastPathComponent) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            guard date > cutoff else { continue }
            result.files.insert(url.lastPathComponent)
            result.crashes[app, default: []].append(date)
        }
        return result
    }
}

/// Fires `onChange` (on a background queue) when a directory changes.
final class HealthDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename],
                                                          queue: DispatchQueue.global(qos: .utility))
        s.setEventHandler(handler: onChange)
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func cancel() { source?.cancel(); source = nil }
    deinit { source?.cancel() }
}

// MARK: - Accessibility responsiveness

enum HealthAXProbe {
    enum Result { case responsive, hung, unknown }

    static func probe(pid: pid_t) -> Result {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value)
        switch err {
        case .success: return .responsive
        case .cannotComplete: return .hung
        default: return .unknown
        }
    }

    static func probeAll(_ pids: [pid_t]) -> [pid_t: Result] {
        var out: [pid_t: Result] = [:]
        for p in pids { out[p] = probe(pid: p) }
        return out
    }
}

// MARK: - Third-party startup items

enum HealthStartupItems {
    static func count() -> Int {
        let dirs = [AppPaths.home.appendingPathComponent("Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons")]
        var n = 0
        for d in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            n += items.filter { $0.hasSuffix(".plist") && !$0.hasPrefix("com.apple.") }.count
        }
        return n
    }
}

// MARK: - pmset assertions

enum HealthAssertions {
    static func parse(_ output: String) -> [HealthSleepBlocker] {
        guard let re = try? NSRegularExpression(
            pattern: #"pid (\d+)\((.+?)\):\s+\[0x[0-9a-fA-F]+\]\s+(\d+):(\d+):(\d+)\s+(\w+)\s+named:\s+"(.*?)""#) else { return [] }
        var seen = Set<String>()
        var out: [HealthSleepBlocker] = []
        for line in output.split(separator: "\n") {
            let s = String(line)
            let ns = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: ns) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            let type = g(6)
            guard type.hasPrefix("Prevent") || type.hasPrefix("NoIdle") || type.hasPrefix("NoDisplay") else { continue }
            let app = g(2)
            if app == "powerd" { continue }
            let secs = (Int(g(3)) ?? 0) * 3600 + (Int(g(4)) ?? 0) * 60 + (Int(g(5)) ?? 0)
            let b = HealthSleepBlocker(pid: Int32(g(1)) ?? 0, app: app, type: type, reason: g(7), seconds: secs)
            if seen.insert(b.id).inserted { out.append(b) }
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    static func read() -> [HealthSleepBlocker] {
        let r = Shell.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 10)
        return r.ok ? parse(r.stdout) : []
    }

    static func describe(_ type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": return "Prevents idle sleep"
        case "PreventSystemSleep": return "Prevents system sleep"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "Keeps display on"
        default: return type
        }
    }
}

// MARK: - Deep checkup commands (parsers + runners; call off the main thread)

enum HealthCheckup {
    static let templates: [HealthCheckItem] = [
        .init(id: "smart", title: "Disk health (SMART)", detail: "", status: .unknown, symbol: "internaldrive"),
        .init(id: "filevault", title: "FileVault encryption", detail: "", status: .unknown, symbol: "lock.doc"),
        .init(id: "sip", title: "System Integrity Protection", detail: "", status: .unknown, symbol: "shield.lefthalf.filled"),
        .init(id: "firewall", title: "Firewall", detail: "", status: .unknown, symbol: "flame"),
        .init(id: "gatekeeper", title: "Gatekeeper", detail: "", status: .unknown, symbol: "checkmark.seal"),
        .init(id: "backup", title: "Time Machine backup", detail: "", status: .unknown, symbol: "clock.arrow.2.circlepath"),
        .init(id: "updates", title: "macOS updates", detail: "", status: .unknown, symbol: "arrow.down.circle"),
        .init(id: "startup", title: "Startup items", detail: "", status: .unknown, symbol: "power"),
    ]

    private static func item(_ id: String, _ detail: String, _ status: HealthCheckStatus) -> HealthCheckItem {
        var t = templates.first { $0.id == id } ?? HealthCheckItem(id: id, title: id, detail: "", status: .unknown, symbol: "questionmark")
        t.detail = detail
        t.status = status
        return t
    }

    static func smart() -> HealthCheckItem {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "disk0"], timeout: 15)
        let line = r.stdout.split(separator: "\n").first { $0.contains("SMART Status") }
        guard let line else { return item("smart", "Status not reported for this disk.", .unknown) }
        let v = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Unknown"
        switch v.lowercased() {
        case "verified": return item("smart", "SMART status: Verified. The disk reports healthy.", .ok)
        case "not supported": return item("smart", "SMART not supported by this disk.", .unknown)
        case "failing": return item("smart", "SMART status: Failing. Back up now and plan to replace the disk.", .warning)
        default: return item("smart", "SMART status: \(v)", .info)
        }
    }

    static func fileVault() -> HealthCheckItem {
        let r = Shell.run("/usr/bin/fdesetup", ["status"], timeout: 10)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("FileVault is On") { return item("filevault", "Disk is encrypted.", .ok) }
        if s.contains("FileVault is Off") { return item("filevault", "Disk is not encrypted. Turn on FileVault in System Settings > Privacy & Security.", .warning) }
        return item("filevault", s.isEmpty ? "Couldn't determine status." : s, .unknown)
    }

    static func sip() -> HealthCheckItem {
        let r = Shell.run("/usr/bin/csrutil", ["status"], timeout: 10)
        let s = (r.stdout + r.stderr).lowercased()
        if s.contains("enabled") { return item("sip", "Enabled. System files are protected.", .ok) }
        if s.contains("disabled") { return item("sip", "Disabled. System files are not protected.", .warning) }
        return item("sip", "Couldn't determine status.", .unknown)
    }

    static func firewall() -> HealthCheckItem {
        let r = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 10)
        let s = r.stdout.lowercased()
        if s.contains("disabled") || s.contains("state = 0") {
            return item("firewall", "Firewall is off. Enable it in System Settings > Network > Firewall.", .warning)
        }
        if s.contains("enabled") || s.contains("state = 1") || s.contains("state = 2") { return item("firewall", "Firewall is on.", .ok) }
        return item("firewall", "Couldn't determine status.", .unknown)
    }

    static func gatekeeper() -> HealthCheckItem {
        let r = Shell.run("/usr/sbin/spctl", ["--status"], timeout: 10)
        let s = (r.stdout + r.stderr).lowercased()
        if s.contains("assessments enabled") { return item("gatekeeper", "Enabled. Unsigned apps are checked.", .ok) }
        if s.contains("assessments disabled") { return item("gatekeeper", "Disabled. Any app can run unchecked.", .warning) }
        return item("gatekeeper", "Couldn't determine status.", .unknown)
    }

    static func backupDate(fromPath path: String) -> Date? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})-(\d{6})"#),
              let m = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return nil }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: path).map { String(path[$0]) } ?? "0" }
        let hms = g(4)
        var c = DateComponents()
        c.year = Int(g(1)); c.month = Int(g(2)); c.day = Int(g(3))
        c.hour = Int(hms.prefix(2)); c.minute = Int(hms.dropFirst(2).prefix(2)); c.second = Int(hms.suffix(2))
        return Calendar.current.date(from: c)
    }

    static func backup() -> (HealthCheckItem, Date?) {
        let r = Shell.run("/usr/bin/tmutil", ["latestbackup"], timeout: 20)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok, let d = backupDate(fromPath: out) {
            let days = Int(Date().timeIntervalSince(d) / 86_400)
            let when = d.formatted(date: .abbreviated, time: .shortened)
            if days > 7 { return (item("backup", "Last backup \(when) (\(days) days ago). Back up soon.", .warning), d) }
            return (item("backup", "Last backup \(when).", .ok), d)
        }
        let err = (r.stdout + r.stderr).lowercased()
        if err.contains("no backups") || err.contains("no machine directory") {
            return (item("backup", "No Time Machine backups found.", .warning), nil)
        }
        return (item("backup", "Couldn't read backup status. Full Disk Access may be required, or the backup disk isn't connected.", .unknown), nil)
    }

    static func updates() -> (HealthCheckItem, Int?) {
        let r = Shell.run("/usr/sbin/softwareupdate", ["-l"], timeout: 120)
        let s = r.stdout + "\n" + r.stderr
        if s.contains("No new software available") { return (item("updates", "Your Mac is up to date.", .ok), 0) }
        let labels = s.split(separator: "\n").filter { $0.contains("Label:") }
        if !labels.isEmpty {
            let names = labels.compactMap { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } }
            let plural = labels.count == 1 ? "" : "s"
            return (item("updates", "\(labels.count) update\(plural) available: \(names.prefix(3).joined(separator: ", ")).", .info), labels.count)
        }
        return (item("updates", "Couldn't check for updates.", .unknown), nil)
    }

    static func startup(count: Int, limit: Int) -> HealthCheckItem {
        count > limit
            ? item("startup", "\(count) third-party launch agents/daemons. Consider trimming.", .info)
            : item("startup", "\(count) third-party launch agents/daemons.", .ok)
    }
}
