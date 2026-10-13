import Foundation
import IOKit

// Private IOKit HID event APIs used for Apple Silicon temperature sensors
// (same approach as the open-source Stats app). Symbols are exported by IOKit.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

struct TemperatureSensor: Identifiable, Hashable {
    let name: String
    let celsius: Double
    var id: String { name }
}

struct ThermalReading {
    var cpu: Double?        // °C average of CPU die sensors
    var gpu: Double?
    var battery: Double?
    var ssd: Double?
    var hottest: Double?
    var sensors: [TemperatureSensor]
    var state: ProcessInfo.ThermalState
}

final class ThermalReader {
    static let shared = ThermalReader()
    private let lock = NSLock()
    private var client: AnyObject?

    private static let kTemperatureEvent: Int64 = 15
    private static var temperatureField: Int32 { Int32(kTemperatureEvent << 16) }

    private init() {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(c, matching)
        client = c
    }

    func sensors() -> [TemperatureSensor] {
        lock.lock(); defer { lock.unlock() }
        guard let client, let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var out: [String: Double] = [:]
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(s, Self.kTemperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let t = IOHIDEventGetFloatValue(event, Self.temperatureField)
            if t > 0, t < 130 { out[name] = t }
        }
        return out.map { TemperatureSensor(name: $0.key, celsius: $0.value) }.sorted { $0.name < $1.name }
    }

    /// Battery temperature changes slowly; reuse the last full read for up to a minute instead of
    /// walking every HID sensor again.
    func batteryTemperature() -> Double? {
        lock.lock()
        if let c = cachedBattery, Date().timeIntervalSince(c.at) < 60 { lock.unlock(); return c.value }
        lock.unlock()
        let v = avg(sensors().filter { $0.name.localizedCaseInsensitiveContains("battery") })
        lock.lock(); cachedBattery = (v, Date()); lock.unlock()
        return v
    }
    private var cachedBattery: (value: Double?, at: Date)?

    func read() -> ThermalReading {
        let all = sensors()
        let batt = avg(all.filter { $0.name.localizedCaseInsensitiveContains("battery") })
        lock.lock(); cachedBattery = (batt, Date()); lock.unlock()
        // Apple Silicon naming: "PMU tdie*" = CPU/SoC die, "PMU tdev*" = devices, "GPU MTR"/"PMU2 tdie" vary by chip.
        let cpu = all.filter { $0.name.contains("tdie") || $0.name.hasPrefix("pACC") || $0.name.hasPrefix("eACC") }
        let gpu = all.filter { $0.name.localizedCaseInsensitiveContains("gpu") }
        let bat = all.filter { $0.name.localizedCaseInsensitiveContains("battery") }
        let ssd = all.filter { $0.name.localizedCaseInsensitiveContains("nand") }
        return ThermalReading(cpu: avg(cpu), gpu: avg(gpu), battery: avg(bat), ssd: avg(ssd),
                              hottest: all.map(\.celsius).max(), sensors: all,
                              state: ProcessInfo.processInfo.thermalState)
    }

    private func avg(_ s: [TemperatureSensor]) -> Double? {
        s.isEmpty ? nil : s.map(\.celsius).reduce(0, +) / Double(s.count)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
