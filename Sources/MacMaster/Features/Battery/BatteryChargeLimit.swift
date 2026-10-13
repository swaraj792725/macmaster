import SwiftUI
import AppKit
import os

/// macOS's own charge limit (System Settings → Battery → Charge Limit), set through the same PowerUI
/// client the Settings pane uses. Runs as the user: no helper, no root and no SMC writes. macOS decides
/// which values are allowed (80–100% in 5% steps today); 100% means no limit.
struct BatteryChargeLimitState: Equatable, Sendable {
    /// Limits macOS accepts, ascending. Empty when this Mac or macOS version has no charge limit.
    var options: [Int] = []
    /// Active limit in percent; 100 means charging to full.
    var limit: Int?
    /// Last limit stored by the Battery settings UI. Fallback hint when the live API is unavailable.
    var lastLimit: Int?

    var isSupported: Bool { !options.isEmpty }
}

enum BatteryChargeLimitAPI {
    /// PowerUI isn't thread-safe as far as we know: every call goes through one serial queue.
    private static let queue = DispatchQueue(label: "MacMaster.Battery.chargeLimit", qos: .userInitiated)
    private final class Box: @unchecked Sendable { var client: NSObject?; var tried = false }
    private static let box = Box()
    private static let known = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// Limit from the last successful read; readable from any thread without blocking. Nil until read.
    nonisolated static var lastKnownLimit: Int? { known.withLock { $0 } }

    /// True when the battery sits at an active (below 100%) limit, which explains "plugged in, not charging".
    nonisolated static func isHoldingAtLimit(_ r: BatteryReading) -> Int? {
        guard let l = lastKnownLimit, l < 100, r.isPluggedIn, !r.isCharging,
              Int((r.percent * 100).rounded()) >= l - 1 else { return nil }
        return l
    }

    private typealias ObjectFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias ByteFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

    /// Method signatures this code was written against. A mismatch on a future macOS disables the feature
    /// instead of calling into an unknown signature.
    private static let signatures = [
        "initWithClientName:": "@24@0:8@16",
        "availableChargeLimitsWithError:": "@24@0:8^@16",
        "getMCLLimitWithError:": "C24@0:8^@16",
        "setMCLLimit:error:": "B28@0:8C16^@20",
    ]

    /// Created once and kept for the app's lifetime. Call on `queue` only.
    private static func client() -> NSObject? {
        if box.tried { return box.client }
        box.tried = true
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        for (sel, types) in signatures {
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString(sel)),
                  let enc = method_getTypeEncoding(m), String(cString: enc) == types else { return nil }
        }
        guard let raw = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let c = raw.perform(NSSelectorFromString("initWithClientName:"), with: "MacMaster")?
                .takeUnretainedValue() as? NSObject else { return nil }
        box.client = c
        return c
    }

    private static func imp<T>(_ c: NSObject, _ sel: String, as: T.Type) -> (T, Selector) {
        let s = NSSelectorFromString(sel)
        return (unsafeBitCast(c.method(for: s), to: T.self), s)
    }

    /// Blocking (XPC to PowerUIAgent). Keep it off the main thread.
    nonisolated static func read() -> BatteryChargeLimitState {
        let (options, limit) = queue.sync { () -> ([Int], Int?) in
            guard let c = client() else { return ([], nil) }
            var err: NSError?
            let (avail, s1) = imp(c, "availableChargeLimitsWithError:", as: ObjectFn.self)
            let options = (avail(c, s1, &err) as? [NSNumber])?.map(\.intValue).filter { (50...100).contains($0) } ?? []
            guard err == nil, !options.isEmpty else { return ([], nil) }
            let (get, s2) = imp(c, "getMCLLimitWithError:", as: ByteFn.self)
            let v = Int(get(c, s2, &err))
            return (options.sorted(), err == nil && (50...100).contains(v) ? v : nil)
        }
        known.withLock { $0 = limit }
        return BatteryChargeLimitState(options: options, limit: limit, lastLimit: priorLimit())
    }

    /// Returns an error message, or nil on success. Blocking; keep it off the main thread.
    nonisolated static func set(_ percent: Int) -> String? {
        guard (50...100).contains(percent) else { return "\(percent)% isn't a valid limit." }
        return queue.sync {
            guard let c = client() else { return "This version of macOS doesn't let apps change the charge limit." }
            var err: NSError?
            let (set, s) = imp(c, "setMCLLimit:error:", as: SetFn.self)
            if set(c, s, UInt8(percent), &err), err == nil { return nil }
            return err?.localizedDescription ?? "macOS didn't accept a \(percent)% limit."
        }
    }

    private static func priorLimit() -> Int? {
        let domain = "com.apple.batteryui.charging.mac" as CFString
        CFPreferencesAppSynchronize(domain)
        let v = (CFPreferencesCopyAppValue("com.apple.batteryui.charging.mac.prior.limit" as CFString, domain) as? NSNumber)?.intValue
        return v.flatMap { (50...100).contains($0) ? $0 : nil }
    }
}

/// Shared state for every charge-limit control (Battery page, menu bar dropdown, Power settings).
@MainActor @Observable
final class BatteryChargeLimiter {
    static let shared = BatteryChargeLimiter()

    private(set) var state = BatteryChargeLimitState()
    private(set) var loaded = false
    /// Limit being applied right now; the picker shows it until macOS confirms.
    private(set) var pending: Int?
    private(set) var error: String?

    func refresh() async {
        let s = await Task.detached(priority: .userInitiated) { BatteryChargeLimitAPI.read() }.value
        state = s
        loaded = true
    }

    func set(_ percent: Int) async {
        guard pending == nil, percent != state.limit else { return }
        pending = percent
        error = nil
        error = await Task.detached(priority: .userInitiated) { BatteryChargeLimitAPI.set(percent) }.value
        await refresh()
        pending = nil
    }
}

enum BatteryChargeLimitText {
    /// Live observation from the battery registry: plugged in, below full, not charging.
    static func holding(_ r: BatteryReading) -> String? {
        guard r.isPluggedIn, !r.isCharging, !BatteryFormat.isFull(r), r.percent < 0.995,
              BatteryChargeLimitAPI.isHoldingAtLimit(r) == nil else { return nil }
        if r.optimizedCharging == true { return "Charging is on hold by Optimized Battery Charging." }
        if let reason = r.notChargingReason, reason != 0 {
            return "Charging is on hold. macOS does this for a charge limit, Optimized Battery Charging or heat, and doesn't say which."
        }
        return nil
    }

    static func summary(_ s: BatteryChargeLimitState, reading r: BatteryReading) -> String {
        guard let l = s.limit else { return "Couldn't read the current limit." }
        if l >= 100 { return "No limit. The battery charges to 100%." }
        if r.isPluggedIn, !r.isCharging, Int((r.percent * 100).rounded()) >= l - 1 {
            return "Reached the \(l)% limit. Charging is paused."
        }
        return "Charging stops at \(l)%."
    }

    static let lowerLimitNote = "macOS allows 80–100%. The same setting is in System Settings → Battery."
}

/// Segmented picker for the system charge limit. Used in the menu bar dropdown and the app.
struct BatteryChargeLimitControl: View {
    let reading: BatteryReading
    var showsHeader = true
    private var limiter: BatteryChargeLimiter { .shared }

    var body: some View {
        let s = limiter.state
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Text("Charge limit").font(.subheadline.weight(.semibold))
                    Spacer()
                    if limiter.pending != nil { ProgressView().controlSize(.mini) }
                }
            }
            if s.isSupported {
                Picker("Charge limit", selection: Binding(
                    get: { limiter.pending ?? s.limit ?? 100 },
                    set: { v in Task { await limiter.set(v) } })) {
                    ForEach(s.options, id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(limiter.pending != nil)

                Text(BatteryChargeLimitText.summary(s, reading: reading))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = limiter.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if limiter.loaded {
                Text(s.lastLimit.map { "This Mac doesn't let apps change the charge limit. Last limit set in System Settings: \($0)%." }
                     ?? "This Mac or macOS version doesn't offer a charge limit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await limiter.refresh() }
    }
}

struct BatteryChargeLimitCard: View {
    let reading: BatteryReading

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "leaf.fill", colors: Theme.Palette.cleaner, size: 36)
            VStack(alignment: .leading, spacing: 10) {
                Text("Charge limit").font(.headline)
                Text("Stop charging before 100% to slow battery aging. This is macOS's own charge limit, so it keeps working when MacMaster isn't running. \(BatteryChargeLimitText.lowerLimitNote)")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                BatteryChargeLimitControl(reading: reading, showsHeader: false)
                    .frame(maxWidth: 420, alignment: .leading)

                HStack {
                    Text("Optimized Battery Charging").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    switch reading.optimizedCharging {
                    case .some(true): StatusPill(text: "Holding", color: .green)
                    case .some(false): StatusPill(text: "Not holding", color: .secondary)
                    case .none: StatusPill(text: "Unknown", color: .secondary)
                    }
                }
                .font(.callout)

                if let note = BatteryChargeLimitText.holding(reading) {
                    Label(note, systemImage: "pause.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
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
    }
}
