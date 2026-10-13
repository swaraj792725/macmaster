import Foundation
import IOKit
import IOKit.ps

struct BatteryReading: Codable, Equatable {
    var isPresent: Bool
    var percent: Double              // 0…1 (user-visible charge)
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var cycleCount: Int
    var designCapacity: Int          // mAh
    var fullChargeCapacity: Int      // mAh (current max)
    var nominalCapacity: Int         // mAh (macOS "Maximum Capacity" basis)
    var remainingCapacity: Int       // mAh
    var voltage: Double              // V
    var amperage: Double             // A (negative = discharging)
    var temperature: Double?         // °C
    var timeToEmpty: Int?            // minutes
    var timeToFull: Int?             // minutes
    var adapterWatts: Int?
    var adapterName: String?
    var systemPowerWatts: Double?    // total system load
    var condition: String?           // "Good", "Service Recommended", …
    var optimizedCharging: Bool?
    var serial: String?
    var deviceName: String?
    var cellVoltages: [Int]          // mV
    var notChargingReason: Int?

    /// Health as macOS reports it (nominal / design).
    var health: Double {
        let basis = nominalCapacity > 0 ? nominalCapacity : fullChargeCapacity
        guard designCapacity > 0, basis > 0 else { return 1 }
        return min(1, Double(basis) / Double(designCapacity))
    }

    /// Instant battery power in watts (negative when discharging).
    var batteryPowerWatts: Double { voltage * amperage }

    static let none = BatteryReading(isPresent: false, percent: 0, isCharging: false, isPluggedIn: true, isFullyCharged: false,
                                     cycleCount: 0, designCapacity: 0, fullChargeCapacity: 0, nominalCapacity: 0,
                                     remainingCapacity: 0, voltage: 0, amperage: 0, temperature: nil, timeToEmpty: nil,
                                     timeToFull: nil, adapterWatts: nil, adapterName: nil, systemPowerWatts: nil,
                                     condition: nil, optimizedCharging: nil, serial: nil, deviceName: nil, cellVoltages: [],
                                     notChargingReason: nil)
}

enum BatteryReader {
    static func read() -> BatteryReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .none }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return .none }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        func int(_ key: String) -> Int? {
            ((props[key] ?? data[key]) as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        }
        func bool(_ key: String) -> Bool { ((props[key] ?? data[key]) as? NSNumber)?.boolValue ?? false }
        func valid(_ minutes: Int?) -> Int? {
            guard let m = minutes, m > 0, m < 65_535 else { return nil }
            return m
        }

        let percentRaw = Double(int("CurrentCapacity") ?? 0)
        let maxPct = Double(int("MaxCapacity") ?? 100)
        let amps = Double(Int16(truncatingIfNeeded: int("InstantAmperage") ?? int("Amperage") ?? 0)) / 1000
        let tempRaw = int("Temperature") ?? int("VirtualTemperature")
        let adapter = props["AdapterDetails"] as? [String: Any]
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        let charger = props["ChargerData"] as? [String: Any]
        let cells = (data["CellVoltage"] as? [NSNumber])?.map(\.intValue) ?? []

        // IOPowerSources gives the user-facing condition and accurate time estimates.
        var condition: String?
        var optimized: Bool?
        var psTimeToEmpty: Int?, psTimeToFull: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                condition = d[kIOPSBatteryHealthKey] as? String
                optimized = (d["Optimized Battery Charging Engaged"] as? NSNumber)?.boolValue
                psTimeToEmpty = (d[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
                psTimeToFull = (d[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue
            }
        }

        let charging = bool("IsCharging")
        let plugged = bool("ExternalConnected")
        return BatteryReading(
            isPresent: true,
            percent: maxPct > 0 ? min(1, percentRaw / maxPct) : percentRaw / 100,
            isCharging: charging,
            isPluggedIn: plugged,
            isFullyCharged: bool("FullyCharged"),
            cycleCount: int("CycleCount") ?? 0,
            designCapacity: int("DesignCapacity") ?? 0,
            fullChargeCapacity: int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? 0,
            nominalCapacity: int("NominalChargeCapacity") ?? 0,
            remainingCapacity: int("AppleRawCurrentCapacity") ?? int("RemainingCapacity") ?? 0,
            voltage: Double(int("Voltage") ?? 0) / 1000,
            amperage: amps,
            temperature: tempRaw.map { Double($0) / 100 } ?? ThermalReader.shared.batteryTemperature(),
            timeToEmpty: !plugged ? valid(psTimeToEmpty ?? int("AvgTimeToEmpty") ?? int("TimeRemaining")) : nil,
            timeToFull: charging ? valid(psTimeToFull ?? int("AvgTimeToFull")) : nil,
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            adapterName: (adapter?["Name"] as? String) ?? (adapter?["Description"] as? String),
            systemPowerWatts: (telemetry?["SystemLoad"] as? NSNumber).map { Double($0.intValue) / 1000 },
            condition: condition,
            optimizedCharging: optimized,
            serial: props["Serial"] as? String,
            deviceName: props["DeviceName"] as? String,
            cellVoltages: cells,
            notChargingReason: (charger?["NotChargingReason"] as? NSNumber)?.intValue
        )
    }
}
