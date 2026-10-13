import Foundation
import Darwin
import IOKit

// Low-level, dependency-free system readers. Stateful readers compute deltas
// between calls, so keep one instance alive and call `read()` periodically.

// MARK: - sysctl helpers

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}

// MARK: - CPU

struct CPUReading {
    var total: Double          // 0…1
    var user: Double
    var system: Double
    var perCore: [Double]      // 0…1 each
    var loadAverage: (Double, Double, Double)
}

final class CPUReader {
    private var previous: [[UInt32]] = []

    func read() -> CPUReading {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let load = (loads[0], loads[1], loads[2])
        guard kr == KERN_SUCCESS, let info else {
            return CPUReading(total: 0, user: 0, system: 0, perCore: [], loadAverage: load)
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var current: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            current.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = current }
        guard previous.count == current.count else {
            return CPUReading(total: 0, user: 0, system: 0, perCore: Array(repeating: 0, count: current.count), loadAverage: load)
        }
        var perCore: [Double] = []
        var tUser = 0.0, tSys = 0.0, tAll = 0.0
        for (cur, prev) in zip(current, previous) {
            let user = Double(cur[Int(CPU_STATE_USER)] &- prev[Int(CPU_STATE_USER)])
            let sys = Double(cur[Int(CPU_STATE_SYSTEM)] &- prev[Int(CPU_STATE_SYSTEM)])
            let nice = Double(cur[Int(CPU_STATE_NICE)] &- prev[Int(CPU_STATE_NICE)])
            let idle = Double(cur[Int(CPU_STATE_IDLE)] &- prev[Int(CPU_STATE_IDLE)])
            let all = user + sys + nice + idle
            perCore.append(all > 0 ? (user + sys + nice) / all : 0)
            tUser += user + nice; tSys += sys; tAll += all
        }
        guard tAll > 0 else { return CPUReading(total: 0, user: 0, system: 0, perCore: perCore, loadAverage: load) }
        return CPUReading(total: (tUser + tSys) / tAll, user: tUser / tAll, system: tSys / tAll, perCore: perCore, loadAverage: load)
    }
}

// MARK: - Memory

struct MemoryReading {
    var total: UInt64
    var used: UInt64        // app + wired + compressed (Activity Monitor "Memory Used")
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64      // file-backed + purgeable
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level)
    var pressureLevel: Int
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryReader {
    static func read() -> MemoryReading {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let pressure = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        guard kr == KERN_SUCCESS else {
            return MemoryReading(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: 0,
                                 swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressureLevel: pressure)
        }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = min(total, app + wired + compressed)
        return MemoryReading(total: total, used: used, app: app, wired: wired, compressed: compressed,
                             cached: cached, free: total > used ? total - used : 0,
                             swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressureLevel: pressure)
    }
}

// MARK: - Disk

struct DiskReading {
    var total: Int64
    var available: Int64
    var readRate: Double    // bytes/s
    var writeRate: Double
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

final class DiskReader {
    private var lastBytes: (read: UInt64, write: UInt64)?
    private var lastTime: Date?

    private var capacity: (total: Int64, avail: Int64, at: Date)?

    func read() -> DiskReading {
        let now = Date()
        // "Available for important usage" asks the cache-delete service about purgeable space: slow,
        // and free space barely moves between 2 s samples. Refresh it every 30 s.
        if capacity == nil || now.timeIntervalSince(capacity!.at) > 30 {
            let root = URL(fileURLWithPath: "/")
            let v = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            capacity = (Int64(v?.volumeTotalCapacity ?? 0),
                        v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0), now)
        }
        let total = capacity?.total ?? 0, avail = capacity?.avail ?? 0

        let bytes = Self.ioBytes()
        var r = 0.0, w = 0.0
        if let last = lastBytes, let t = lastTime {
            let dt = now.timeIntervalSince(t)
            if dt > 0 {
                r = Double(bytes.read &- last.read) / dt
                w = Double(bytes.write &- last.write) / dt
            }
        }
        lastBytes = bytes; lastTime = now
        return DiskReading(total: total, available: avail, readRate: max(0, r), writeRate: max(0, w))
    }

    private static func ioBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                read += (props["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (props["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}

// MARK: - Network

struct NetworkReading {
    var downRate: Double   // bytes/s
    var upRate: Double
    var totalDown: UInt64  // since boot
    var totalUp: UInt64
    var primaryInterface: String?
    var localIP: String?
}

final class NetworkReader {
    private var last: (down: UInt64, up: UInt64, time: Date)?

    func read() -> NetworkReading {
        let (down, up) = Self.interfaceTotals()
        let now = Date()
        var dr = 0.0, ur = 0.0
        if let last {
            let dt = now.timeIntervalSince(last.time)
            if dt > 0, down >= last.down, up >= last.up {
                dr = Double(down - last.down) / dt
                ur = Double(up - last.up) / dt
            }
        }
        last = (down, up, now)
        let (iface, ip) = Self.primaryAddress()
        return NetworkReading(downRate: dr, upRate: ur, totalDown: down, totalUp: up, primaryInterface: iface, localIP: ip)
    }

    /// 64-bit counters via NET_RT_IFLIST2 (getifaddrs uses 32-bit counters that wrap).
    private static func interfaceTotals() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var down: UInt64 = 0, up: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if (h2.ifm_flags & IFF_LOOPBACK) == 0 {
                        down += h2.ifm_data.ifi_ibytes
                        up += h2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return (down, up)
    }

    private static func primaryAddress() -> (String?, String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (nil, nil) }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        let best = candidates.first { $0.0.hasPrefix("en") } ?? candidates.first
        return (best?.0, best?.1)
    }
}

// MARK: - GPU

enum GPUReader {
    /// Device utilization 0…1 from IOAccelerator PerformanceStatistics.
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util / 100)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }
}

// MARK: - System info

struct SystemInfo {
    let modelIdentifier: String
    let chip: String
    let osVersion: String
    let performanceCores: Int
    let efficiencyCores: Int
    let logicalCores: Int
    let memory: UInt64
    let hostName: String

    static let current: SystemInfo = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            performanceCores: Sysctl.int("hw.perflevel0.logicalcpu") ?? 0,
            efficiencyCores: Sysctl.int("hw.perflevel1.logicalcpu") ?? 0,
            logicalCores: ProcessInfo.processInfo.activeProcessorCount,
            memory: ProcessInfo.processInfo.physicalMemory,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }()

    static var uptime: TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }
}
