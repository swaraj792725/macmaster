import SwiftUI
import AppKit

/// Read-only view of what macOS exposes about its own charge limit. Nothing here writes to the SMC or to
/// any system setting; the limit itself is changed in System Settings → Battery.
struct BatteryChargeLimitStatus: Equatable, Sendable {
    /// Last charge limit stored by the Battery settings UI (`com.apple.batteryui.charging.mac`), in percent.
    /// macOS keeps it as the "prior limit", so it is a hint rather than proof the limit is on right now.
    var lastLimit: Int?

    /// Reads the user-level preference. Cheap, but keep it off the main thread like the other readers.
    nonisolated static func read() -> BatteryChargeLimitStatus {
        let domain = "com.apple.batteryui.charging.mac" as CFString
        let key = "com.apple.batteryui.charging.mac.prior.limit" as CFString
        CFPreferencesAppSynchronize(domain)
        let v = (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue
        return BatteryChargeLimitStatus(lastLimit: v.flatMap { (50...100).contains($0) ? $0 : nil })
    }
}

enum BatteryChargeLimitText {
    /// Live observation from the battery registry: plugged in, below full, not charging.
    static func holding(_ r: BatteryReading) -> String? {
        guard r.isPluggedIn, !r.isCharging, !BatteryFormat.isFull(r), r.percent < 0.995 else { return nil }
        if r.optimizedCharging == true { return "Charging is on hold by Optimized Battery Charging." }
        if let reason = r.notChargingReason, reason != 0 {
            return "Charging is on hold. macOS does this for a charge limit, Optimized Battery Charging or heat, and doesn't say which."
        }
        return nil
    }
}

struct BatteryChargeLimitCard: View {
    let reading: BatteryReading
    @State private var status = BatteryChargeLimitStatus(lastLimit: nil)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "leaf.fill", colors: Theme.Palette.cleaner, size: 36)
            VStack(alignment: .leading, spacing: 8) {
                Text("Charge limit").font(.headline)
                Text("Newer macOS versions include a charge limit in System Settings → Battery on supported Macs, and Optimized Battery Charging on all of them. MacMaster only reads their state; it can't change them and never writes to the SMC. Set the limit in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    row("Optimized Battery Charging") {
                        switch reading.optimizedCharging {
                        case .some(true): StatusPill(text: "Holding", color: .green)
                        case .some(false): StatusPill(text: "Not holding", color: .secondary)
                        case .none: StatusPill(text: "Unknown", color: .secondary)
                        }
                    }
                    row("Last limit in System Settings") {
                        if let l = status.lastLimit {
                            Text("\(l)%").monospacedDigit().foregroundStyle(.primary)
                        } else {
                            Text("Not readable").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 2)

                if let note = BatteryChargeLimitText.holding(reading) {
                    Label(note, systemImage: "pause.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.lastLimit != nil {
                    Text("The last limit is the value macOS remembers from the Battery settings. It may not match what is active right now.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Open Battery Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(.top, 2)
            }
        }
        .card()
        .task { status = await Task.detached(priority: .utility) { BatteryChargeLimitStatus.read() }.value }
    }

    private func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
        }
    }
}
