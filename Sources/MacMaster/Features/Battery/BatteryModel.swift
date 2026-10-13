import SwiftUI

// MARK: - Formatting / status text

enum BatteryFormat {
    static func minutes(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }

    static func hours(_ h: Double) -> String {
        guard h.isFinite, h >= 0 else { return "—" }
        return minutes(Int((h * 60).rounded()))
    }

    static func watts(_ w: Double, digits: Int = 1) -> String { String(format: "%.\(digits)f W", w) }

    static func isFull(_ r: BatteryReading) -> Bool { r.isFullyCharged || (r.isPluggedIn && r.percent >= 0.995) }

    /// Short headline: "Charging", "On battery", …
    static func headline(_ r: BatteryReading) -> String {
        guard r.isPresent else { return "No battery" }
        if r.isCharging { return "Charging" }
        if r.isPluggedIn { return isFull(r) ? "Fully charged" : "Plugged in" }
        return "On battery"
    }

    /// Secondary detail: "Full in 1h 12m", "3h 35m left", …
    static func detail(_ r: BatteryReading) -> String {
        guard r.isPresent else { return "This Mac has no internal battery." }
        if r.isCharging {
            return r.timeToFull.map { "Full in \(minutes($0))" } ?? "Calculating time to full…"
        }
        if r.isPluggedIn {
            if isFull(r) { return "Plugged in" }
            return notChargingText(r)
        }
        return r.timeToEmpty.map { "\(minutes($0)) left" } ?? "Estimating time remaining…"
    }

    static func notChargingText(_ r: BatteryReading) -> String {
        if r.optimizedCharging == true { return "Not charging (Optimized Battery Charging)" }
        if let reason = r.notChargingReason, reason != 0 { return "Not charging (paused by macOS)" }
        return "Not charging"
    }

    /// Full status line, e.g. "Charging — full in 1h 12m".
    static func statusLine(_ r: BatteryReading) -> String {
        guard r.isPresent else { return "No battery detected" }
        if r.isCharging {
            return "Charging — " + (r.timeToFull.map { "full in \(minutes($0))" } ?? "calculating time to full")
        }
        if r.isPluggedIn {
            if isFull(r) { return "Fully charged — plugged in" }
            return "Plugged in, " + notChargingText(r).prefix(1).lowercased() + notChargingText(r).dropFirst()
        }
        return "On battery — " + (r.timeToEmpty.map { "\(minutes($0)) left" } ?? "estimating time remaining")
    }

    /// Compact status for small captions (dashboard ring, menus).
    static func shortStatus(_ r: BatteryReading) -> String {
        guard r.isPresent else { return "No battery" }
        if r.isCharging { return r.timeToFull.map { "Full in \(minutes($0))" } ?? "Charging" }
        if r.isPluggedIn { return isFull(r) ? "Charged" : "Plugged in" }
        return r.timeToEmpty.map { "\(minutes($0)) left" } ?? "On battery"
    }

    static func tintColors(_ r: BatteryReading) -> [Color] {
        if r.isCharging { return BatteryPalette.green }
        return BatteryPalette.gradient(r.percent)
    }
}

// MARK: - Analytics from history

enum BatteryAnalytics {
    /// Average discharge rate (fraction of full charge per hour) over unplugged segments since `since`.
    static func dischargePerHour(_ pts: [BatteryPoint], since: Date) -> Double? {
        let recent = pts.filter { $0.date >= since }
        guard recent.count > 1 else { return nil }
        var drop = 0.0, secs = 0.0
        for (a, b) in zip(recent, recent.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard dt > 0, dt <= 300, !a.isCharging, !b.isCharging, b.percent <= a.percent else { continue }
            drop += a.percent - b.percent
            secs += dt
        }
        guard secs >= 600 else { return nil }
        return drop / (secs / 3600)
    }

    /// Time on battery and charge used since the battery was last (nearly) full.
    static func sinceFullCharge(_ pts: [BatteryPoint], currentPercent: Double) -> (onBattery: TimeInterval, used: Double, since: Date)? {
        guard let idx = pts.lastIndex(where: { $0.percent >= 0.97 }) else { return nil }
        var secs = 0.0
        let tail = pts[idx...]
        for (a, b) in zip(tail, tail.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            if dt > 0, dt <= 300, !a.isCharging, !b.isCharging { secs += dt }
        }
        return (secs, max(0, pts[idx].percent - currentPercent), pts[idx].date)
    }

    /// Hours remaining if the current draw continued.
    static func hoursAtCurrentDraw(_ r: BatteryReading) -> Double? {
        guard r.isPresent, !r.isPluggedIn || r.amperage < 0, r.amperage < -0.01, r.voltage > 0 else { return nil }
        let wh = Double(r.remainingCapacity) / 1000 * r.voltage
        let draw = abs(r.batteryPowerWatts)
        guard draw > 0.2, wh > 0 else { return nil }
        return wh / draw
    }

    /// Fraction of the last 3 days of samples spent at ≥ 95 %.
    static func fractionNearFull(_ pts: [BatteryPoint]) -> Double {
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        let recent = pts.filter { $0.date >= cutoff }
        guard recent.count > 120 else { return 0 }
        return Double(recent.filter { $0.percent >= 0.95 }.count) / Double(recent.count)
    }
}

// MARK: - Tips

struct BatteryTip: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let title: String
    let message: String
}

enum BatteryTips {
    static func make(reading r: BatteryReading, history: [BatteryPoint]) -> [BatteryTip] {
        guard r.isPresent else { return [] }
        var tips: [BatteryTip] = []

        if let t = r.temperature, t >= 40, r.isCharging {
            tips.append(.init(id: "hot", symbol: "thermometer.high", color: .orange, title: "Running warm while charging",
                              message: String(format: "The battery is at %.0f°C. Heat accelerates wear — keep vents clear, avoid soft surfaces and heavy workloads while charging.", t)))
        } else if let t = r.temperature, t >= 45 {
            tips.append(.init(id: "hot2", symbol: "thermometer.high", color: .red, title: "Battery is hot",
                              message: String(format: "%.0f°C is high. Let the Mac cool down and close demanding apps.", t)))
        }

        if r.health < 0.8 {
            tips.append(.init(id: "health", symbol: "heart.slash.fill", color: .red, title: "Battery health below 80%",
                              message: "Maximum capacity is \(Int((r.health * 100).rounded()))% of design. Apple considers a battery worn below 80% — consider a battery service."))
        }
        if let c = r.condition, !["Good", "Normal"].contains(c) {
            tips.append(.init(id: "cond", symbol: "wrench.and.screwdriver.fill", color: .orange, title: "Condition: \(c)",
                              message: "macOS reports this battery needs attention. Visit Apple Support or an authorized service provider."))
        }
        if r.cycleCount >= 800 {
            tips.append(.init(id: "cycles", symbol: "arrow.triangle.2.circlepath", color: .yellow, title: "Approaching rated cycle life",
                              message: "\(r.cycleCount) cycles used of a typical 1000. Capacity loss will become more noticeable."))
        }
        if BatteryAnalytics.fractionNearFull(history) > 0.6, r.optimizedCharging != true {
            tips.append(.init(id: "oc", symbol: "leaf.fill", color: .green, title: "Turn on Optimized Battery Charging",
                              message: "Your Mac sits near 100% most of the time. Enable System Settings → Battery → Battery Health → Optimized Battery Charging to reduce aging."))
        }
        if !r.isPluggedIn, r.percent <= 0.2 {
            tips.append(.init(id: "low", symbol: "battery.25percent", color: .red, title: "Battery is low",
                              message: "Plug in soon. Enabling Low Power Mode can stretch the remaining charge."))
        }
        let cells = r.cellVoltages.filter { $0 > 0 }
        if let lo = cells.min(), let hi = cells.max(), hi - lo > 30 {
            tips.append(.init(id: "cells", symbol: "chart.bar.xaxis", color: .orange, title: "Cell imbalance detected",
                              message: "Cell voltages differ by \(hi - lo) mV. A full charge/discharge cycle can help rebalance them."))
        }
        if tips.isEmpty {
            tips.append(.init(id: "ok", symbol: "checkmark.seal.fill", color: .green, title: "Battery looks healthy",
                              message: "No issues found. Keep it between 20% and 80% when you can for the longest lifespan."))
        }
        return tips
    }
}

// MARK: - Chart data preparation

enum BatteryRange: String, CaseIterable, Identifiable {
    case day = "24 h", week = "7 days"
    var id: String { rawValue }
    var seconds: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
}

struct BatterySeriesPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
    let charging: Bool
    var stateLabel: String { charging ? "Charging" : "On battery" }
}

enum BatteryChartPrep {
    /// Downsamples to ≈`maxPoints` buckets and splits into charging / discharging segments.
    static func prepare(_ history: [BatteryPoint], range: BatteryRange, maxPoints: Int = 280,
                        value: (BatteryPoint) -> Double?) -> [BatterySeriesPoint] {
        let since = Date().addingTimeInterval(-range.seconds)
        let pts = history.filter { $0.date >= since }
        guard !pts.isEmpty else { return [] }
        let bucket = max(60, range.seconds / Double(maxPoints))

        // bucket average
        var buckets: [(date: Date, value: Double, charging: Bool)] = []
        var curKey = -1
        var sum = 0.0, n = 0.0, lastDate = Date(), lastCharging = false
        func flush() {
            if n > 0 { buckets.append((lastDate, sum / n, lastCharging)) }
            sum = 0; n = 0
        }
        for p in pts {
            guard let v = value(p) else { continue }
            let key = Int(p.date.timeIntervalSince1970 / bucket)
            if key != curKey { flush(); curKey = key }
            sum += v; n += 1; lastDate = p.date; lastCharging = p.isCharging
        }
        flush()

        var out: [BatterySeriesPoint] = []
        var seg = 0
        var nextID = 0
        for (i, b) in buckets.enumerated() {
            if i > 0 {
                let prev = buckets[i - 1]
                let gap = b.date.timeIntervalSince(prev.date)
                if gap > max(900, bucket * 3) {
                    seg += 1
                } else if b.charging != prev.charging {
                    seg += 1
                    // bridge so the line is continuous across the state change
                    out.append(BatterySeriesPoint(id: nextID, date: prev.date, value: prev.value, segment: seg, charging: b.charging))
                    nextID += 1
                }
            }
            out.append(BatterySeriesPoint(id: nextID, date: b.date, value: b.value, segment: seg, charging: b.charging))
            nextID += 1
        }
        return out
    }
}
