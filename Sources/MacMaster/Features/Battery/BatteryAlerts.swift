import Foundation

/// Low / high battery notifications. Settings live in UserDefaults (`mm.battery.alerts.*`).
@MainActor
final class BatteryAlerts {
    static let shared = BatteryAlerts()

    enum Key {
        static let lowEnabled = "mm.battery.alerts.low.enabled"
        static let lowThreshold = "mm.battery.alerts.low.threshold"
        static let highEnabled = "mm.battery.alerts.high.enabled"
        static let highThreshold = "mm.battery.alerts.high.threshold"
    }

    private var timer: Timer?
    private var lowFired = false
    private var highFired = false

    private init() {
        UserDefaults.standard.register(defaults: [
            Key.lowEnabled: true, Key.lowThreshold: 20,
            Key.highEnabled: false, Key.highThreshold: 80,
        ])
    }

    func start() {
        guard timer == nil else { return }
        BatteryMonitor.shared.start()   // idempotent
        Notifier.requestAuthorization()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let r = BatteryMonitor.shared.reading
        guard r.isPresent else { return }
        let d = UserDefaults.standard
        let pct = Int((r.percent * 100).rounded())

        let low = d.integer(forKey: Key.lowThreshold)
        if d.bool(forKey: Key.lowEnabled), !r.isPluggedIn {
            if pct <= low, !lowFired {
                lowFired = true
                Notifier.post(title: "Battery low — \(pct)%",
                              body: r.timeToEmpty.map { "About \(BatteryFormat.minutes($0)) left. Plug in your charger." } ?? "Plug in your charger.",
                              id: "mm.battery.low")
            }
        }
        if pct > low + 3 || r.isPluggedIn { lowFired = false }

        let high = d.integer(forKey: Key.highThreshold)
        if d.bool(forKey: Key.highEnabled), r.isCharging {
            if pct >= high, !highFired {
                highFired = true
                Notifier.post(title: "Battery at \(pct)%",
                              body: "You can unplug now to keep the battery healthy.",
                              id: "mm.battery.high")
            }
        }
        if pct < high - 3 || !r.isPluggedIn { highFired = false }
    }
}
