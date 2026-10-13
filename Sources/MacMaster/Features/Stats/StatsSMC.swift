import Foundation
import IOKit

struct StatsFan: Identifiable, Equatable {
    let index: Int
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double
    var id: Int { index }
    var fraction: Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return maxRPM > 0 ? min(1, rpm / maxRPM) : 0 }
        return min(1, max(0, (rpm - minRPM) / span))
    }
}

enum StatsFanState: Equatable {
    case unavailable          // SMC could not be opened
    case none                 // FNum == 0
    case fans([StatsFan])
}

/// Minimal AppleSMC user-client reader (read-only). The kernel struct is 80 bytes;
/// we poke offsets directly instead of mirroring the C layout.
final class StatsSMCReader: @unchecked Sendable {
    static let shared = StatsSMCReader()

    private var conn: io_connect_t = 0
    private let lock = NSLock()

    private enum Off {
        static let key = 0, dataSize = 28, dataType = 32, result = 40, command = 42, bytes = 48, total = 80
    }

    private init() {}
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func openIfNeeded() -> Bool {
        if conn != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == KERN_SUCCESS, c != 0 else { return false }
        conn = c
        return true
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        let inBuf = input
        var out = [UInt8](repeating: 0, count: Off.total)
        var outSize = Off.total
        let kr = inBuf.withUnsafeBytes { ib in
            out.withUnsafeMutableBytes { ob in
                IOConnectCallStructMethod(conn, 2, ib.baseAddress, Off.total, ob.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS, out[Off.result] == 0 else { return nil }
        return out
    }

    private func put32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        withUnsafeBytes(of: v) { raw in for i in 0..<4 { buf[off + i] = raw[i] } }
    }
    private func get32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
    }

    /// Returns a numeric value for `key`, or nil when it doesn't exist.
    private func readNumber(_ key: String) -> Double? {
        var req = [UInt8](repeating: 0, count: Off.total)
        put32(&req, Off.key, Self.fourCC(key))
        req[Off.command] = 9                          // read key info
        guard let info = call(req) else { return nil }
        let size = Int(get32(info, Off.dataSize))
        let type = get32(info, Off.dataType)
        guard size > 0, size <= 32 else { return nil }

        var req2 = [UInt8](repeating: 0, count: Off.total)
        put32(&req2, Off.key, Self.fourCC(key))
        put32(&req2, Off.dataSize, UInt32(size))
        req2[Off.command] = 5                         // read bytes
        guard let out = call(req2) else { return nil }
        let b = Array(out[Off.bytes..<(Off.bytes + size)])

        switch type {
        case Self.fourCC("ui8 "): return Double(b[0])
        case Self.fourCC("ui16"): return size >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case Self.fourCC("ui32"): return size >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        case Self.fourCC("fpe2"): return size >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case Self.fourCC("sp78"):
            guard size >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case Self.fourCC("flt "):
            guard size >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24   // little-endian on arm64
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        default: return nil
        }
    }

    func fans() -> StatsFanState {
        lock.lock(); defer { lock.unlock() }
        guard openIfNeeded() else { return .unavailable }
        guard let n = readNumber("FNum") else { return .none }
        let count = Int(n)
        guard count > 0, count <= 8 else { return .none }
        var list: [StatsFan] = []
        for i in 0..<count {
            let rpm = readNumber("F\(i)Ac") ?? 0
            let lo = readNumber("F\(i)Mn") ?? 0
            let hi = readNumber("F\(i)Mx") ?? 0
            list.append(StatsFan(index: i, rpm: rpm, minRPM: lo, maxRPM: hi))
        }
        return .fans(list)
    }
}
