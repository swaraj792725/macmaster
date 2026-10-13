import Foundation
import Darwin
import AppKit

struct ProcessSample: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    var cpu: Double          // fraction of ONE core (1.0 = 100% of a core, like Activity Monitor)
    var memory: UInt64       // physical footprint bytes
    var bundleID: String?
    var id: pid_t { pid }
}

/// Samples per-process CPU and memory. Only processes readable by this user
/// (root-owned processes need privileges and are skipped).
final class ProcessReader {
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var lastSample: Date?
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func read() -> [ProcessSample] {
        let now = Date()
        let interval = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        let running = RunningAppCache.shared
        var nextCPU: [pid_t: UInt64] = [:]
        var result: [ProcessSample] = []
        result.reserveCapacity(Int(n))

        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpuTicks = info.ri_user_time + info.ri_system_time
            nextCPU[pid] = cpuTicks
            var cpu = 0.0
            if interval > 0, let prev = lastCPUTime[pid], cpuTicks >= prev {
                cpu = Double(cpuTicks - prev) * timebase / 1e9 / interval
            }
            let app = running[pid]
            result.append(ProcessSample(pid: pid, name: app?.name ?? name(of: pid, cpuTicks: cpuTicks, start: info.ri_proc_start_abstime),
                                        cpu: cpu, memory: info.ri_phys_footprint,
                                        bundleID: app?.bundleID))
        }
        lastCPUTime = nextCPU
        if names.count > nextCPU.count + 64 { names = names.filter { nextCPU[$0.key] != nil } }
        return result
    }

    /// proc_name per pid, remembered while the process (same start time) lives.
    private var names: [pid_t: (start: UInt64, name: String)] = [:]
    private func name(of pid: pid_t, cpuTicks: UInt64, start: UInt64) -> String {
        if let n = names[pid], n.start == start { return n.name }
        let n = Self.name(of: pid)
        names[pid] = (start, n)
        return n
    }

    static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 {
            let s = String(cString: buf)
            if !s.isEmpty { return s }
        }
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            return (String(cString: buf) as NSString).lastPathComponent
        }
        return "pid \(pid)"
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
}
