import SwiftUI

enum HealthScoring {
    /// Weighted 0–100 score: active issues plus current resource headroom.
    static func score(issues: [HealthIssue], ctx: HealthContext) -> Int {
        var issuePenalty = 0.0
        for i in issues {
            switch i.severity {
            case .info: issuePenalty += 2
            case .warning: issuePenalty += 8
            case .critical: issuePenalty += 18
            }
        }
        var penalty = min(issuePenalty, 55)

        // CPU headroom (1-minute average)
        let recent = ctx.history.suffix(6)
        if !recent.isEmpty {
            let avg = recent.map(\.cpu).reduce(0, +) / Double(recent.count)
            penalty += max(0, avg - 0.6) / 0.4 * 8
        }
        // Memory
        if ctx.memory.pressureLevel >= 4 { penalty += 14 } else if ctx.memory.pressureLevel >= 2 { penalty += 7 }
        penalty += max(0, ctx.memory.usedFraction - 0.85) / 0.15 * 4
        // Disk
        if ctx.disk.total > 0 {
            let free = Double(ctx.disk.available) / Double(ctx.disk.total)
            penalty += max(0, 0.2 - free) / 0.2 * 10
        }
        // Thermal
        switch ctx.thermalState {
        case .fair: penalty += 2
        case .serious: penalty += 10
        case .critical: penalty += 20
        default: break
        }
        // Battery health
        if ctx.battery.isPresent, ctx.battery.designCapacity > 0 {
            penalty += min(6, max(0, 0.9 - ctx.battery.health) / 0.3 * 6)
        }
        return Int(max(0, min(100, (100 - penalty).rounded())))
    }

    static func label(_ score: Int) -> String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Good"
        case 55..<75: "Fair"
        default: "Poor"
        }
    }

    static func colors(_ score: Int) -> [Color] {
        switch score {
        case 90...: [Color(hex: 0x34D399), Color(hex: 0x10B981)]
        case 75..<90: [Color(hex: 0x4ADE80), Color(hex: 0x22D3EE)]
        case 55..<75: [Color(hex: 0xFBBF24), Color(hex: 0xF59E0B)]
        default: [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
        }
    }

    static func summary(issues: [HealthIssue]) -> String {
        guard let top = issues.first else { return "All systems healthy. Nothing needs your attention." }
        let rest = issues.count - 1
        return rest > 0 ? "\(top.title) (+\(rest) more)" : top.title
    }
}
