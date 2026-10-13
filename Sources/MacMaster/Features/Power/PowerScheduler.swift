import SwiftUI
import AppKit
import Observation

/// Background brain of the Power feature: timers, "when..." automations, the closed-lid guard
/// and the 5-minute power-draw trace. `start()`/`stop()` are idempotent.
@Observable
@MainActor
final class PowerScheduler {
    static let shared = PowerScheduler()

    // MARK: Public state

    /// The timer the user set (persisted).
    private(set) var timer: PowerPending?
    /// An automation that has triggered and is counting down its 60 s warning.
    private(set) var warning: PowerPending?
    /// Whatever will happen soonest (timer or automation warning). Show this in the menu bar.
    var pending: PowerPending? {
        switch (timer, warning) {
        case let (t?, w?): return t.fireDate <= w.fireDate ? t : w
        case let (t?, nil): return t
        case let (nil, w?): return w
        default: return nil
        }
    }

    var automations: PowerAutomations {
        didSet {
            guard automations != oldValue else { return }
            save(automations, key: Keys.automations)
            if automations.processName != oldValue.processName || automations.processEnabled != oldValue.processEnabled {
                processSeen = false; processMisses = 0
            }
            if !automations.idleEnabled { cpuLowSince = nil }
        }
    }

    /// System power draw in watts, one sample per 5 s (about 5 minutes).
    private(set) var powerTrace: [Double] = []

    private(set) var lidState: PowerLidState = .unknown
    private(set) var lidBusy = false
    private(set) var lidError: String?

    // MARK: Private

    private enum Keys {
        static let timer = "mm.power.timer"
        static let automations = "mm.power.automations"
        static let lidUntil = "mm.power.lid.until"
        static let lidFloor = "mm.power.lid.floor"
        static let lidActive = "mm.power.lid.active"
    }

    private enum Trigger { case battery, process, idle }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var warningTrigger: Trigger?
    @ObservationIgnored private var batteryArmed = true
    @ObservationIgnored private var processSeen = false
    @ObservationIgnored private var processMisses = 0
    @ObservationIgnored private var processCheckInFlight = false
    @ObservationIgnored private var cpuLowSince: Date?
    @ObservationIgnored private var lidQuietEnd = false

    private init() {
        automations = Self.load(PowerAutomations.self, key: Keys.automations) ?? PowerAutomations()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        timer = Self.load(PowerPending.self, key: Keys.timer)
        if timer != nil { handleTimer() }   // fire / drop stale timers right away
        sampleTrace()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker?.tolerance = 0.2
        Task { await refreshLid() }
    }

    /// Stops ticking and hands closed-lid mode back to the system. The root watchdog notices the
    /// missing flag file (or the dead app) within a couple of seconds and re-enables sleep.
    func stop() {
        guard started else { return }
        started = false
        ticker?.invalidate(); ticker = nil
        if case .on = lidState { Self.removeFlag(); clearLidDefaults() }
    }

    // MARK: Timer

    /// Starts (or replaces) the timer. Returns false if the target time is not in the future.
    @discardableResult
    func schedule(_ action: PowerTimedAction, at date: Date) -> Bool {
        guard date.timeIntervalSinceNow > 5 else { return false }
        var p = PowerPending(source: .timer, action: action, created: Date(), fireDate: date,
                             reason: "Timer")
        if p.total <= 60 { p.warned = true }
        timer = p
        save(p, key: Keys.timer)
        if !started { start() }
        return true
    }

    @discardableResult
    func schedule(_ action: PowerTimedAction, inMinutes minutes: Int) -> Bool {
        schedule(action, at: Date().addingTimeInterval(Double(max(1, minutes)) * 60))
    }

    func cancelTimer() {
        timer = nil
        UserDefaults.standard.removeObject(forKey: Keys.timer)
        Notifier.post(title: "Timer cancelled", body: "The scheduled power action was cancelled.", id: "mm.power.timer.cancel", sound: false)
    }

    func extendTimer(byMinutes minutes: Int) {
        guard var t = timer else { return }
        t.fireDate = t.fireDate.addingTimeInterval(Double(minutes) * 60)
        t.warned = false
        timer = t
        save(t, key: Keys.timer)
    }

    func cancelWarning() {
        guard warning != nil else { return }
        warning = nil; warningTrigger = nil
        Notifier.post(title: "Automation cancelled", body: "Your Mac will stay as it is.", id: "mm.power.warning.cancel", sound: false)
    }

    /// Cancels whatever `pending` currently shows.
    func cancelPending() {
        guard let p = pending else { return }
        if p.source == .timer { cancelTimer() } else { cancelWarning() }
    }

    // MARK: Tick

    private func tick() {
        tickCount += 1
        if timer != nil { handleTimer() }
        if warning != nil { handleWarning() }
        if tickCount % 5 == 0 {
            sampleTrace()
            evaluateAutomations()
        }
        if tickCount % 10 == 0, lidState != .off, lidState != .unknown, !lidBusy {
            Task { await refreshLid() }
        }
    }

    private func handleTimer() {
        guard var t = timer else { return }
        let rem = t.fireDate.timeIntervalSinceNow
        if rem <= -120 {
            // The Mac was asleep or MacMaster was closed past the deadline: don't act on stale intent.
            timer = nil
            UserDefaults.standard.removeObject(forKey: Keys.timer)
            Notifier.post(title: "Scheduled \(t.action.title.lowercased()) missed",
                          body: "MacMaster wasn't running at the scheduled time, so nothing happened.",
                          id: "mm.power.timer.missed")
            return
        }
        if rem <= 0 {
            timer = nil
            UserDefaults.standard.removeObject(forKey: Keys.timer)
            fire(t.action)
            return
        }
        if rem <= 60, !t.warned {
            t.warned = true
            timer = t
            save(t, key: Keys.timer)
            Notifier.post(title: "Your Mac will \(t.action.progressive) in 1 minute",
                          body: "Open MacMaster › Power › Schedule to cancel.", id: "mm.power.timer.warn")
        }
    }

    private func handleWarning() {
        guard let w = warning else { return }
        // Cancel automatically if the reason went away.
        if let why = warningTrigger, !conditionStillHolds(why) {
            warning = nil; warningTrigger = nil
            Notifier.post(title: "Automation cancelled", body: "The condition no longer applies.", id: "mm.power.warning.cancel", sound: false)
            return
        }
        if w.remaining <= 0 {
            warning = nil; warningTrigger = nil
            fire(w.action)
        }
    }

    private func fire(_ action: PowerTimedAction) {
        // The user scheduled / opted into this and was warned 60 s ahead, which counts as confirmation.
        Task { _ = await PowerActions.perform(action.kind, confirmed: true) }
    }

    // MARK: Automations

    private func startWarning(_ action: PowerTimedAction, reason: String, trigger: Trigger) {
        guard warning == nil else { return }
        let now = Date()
        warning = PowerPending(source: .automation, action: action, created: now,
                               fireDate: now.addingTimeInterval(60), reason: reason, warned: true)
        warningTrigger = trigger
        Notifier.post(title: "Your Mac will \(action.progressive) in 60 seconds",
                      body: "\(reason). Open MacMaster › Power › Schedule to cancel.", id: "mm.power.warning")
    }

    private func conditionStillHolds(_ t: Trigger) -> Bool {
        switch t {
        case .battery: return !BatteryMonitor.shared.reading.isPluggedIn
        case .idle: return Self.hidIdleSeconds() >= 60
        case .process: return true
        }
    }

    private func evaluateAutomations() {
        let a = automations
        let r = BatteryMonitor.shared.reading

        if a.batteryEnabled, r.isPresent {
            let pct = Int((r.percent * 100).rounded())
            if r.isPluggedIn || pct > a.batteryPercent + 3 { batteryArmed = true }
            if !r.isPluggedIn, pct < a.batteryPercent, batteryArmed, warning == nil {
                batteryArmed = false
                startWarning(.sleep, reason: "Battery is below \(a.batteryPercent)%", trigger: .battery)
            }
        }

        if a.processEnabled {
            let name = a.processName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { checkProcess(name: name, action: a.processAction) }
        }

        if a.idleEnabled {
            let cpu = SystemMonitor.shared.cpu.total
            if cpu < 0.10 { if cpuLowSince == nil { cpuLowSince = Date() } } else { cpuLowSince = nil }
            let need = Double(max(1, a.idleMinutes)) * 60
            if let since = cpuLowSince, Date().timeIntervalSince(since) >= need,
               Self.hidIdleSeconds() >= need, warning == nil {
                cpuLowSince = nil
                startWarning(.shutDown, reason: "Mac has been idle for \(a.idleMinutes) minutes", trigger: .idle)
            }
        }
    }

    private func checkProcess(name: String, action: PowerTimedAction) {
        guard !processCheckInFlight else { return }
        processCheckInFlight = true
        let lower = name.lowercased()
        let guiRunning = NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").lowercased() == lower
                || ($0.executableURL?.lastPathComponent ?? "").lowercased() == lower
                || ($0.bundleIdentifier ?? "").lowercased() == lower
        }
        Task { [weak self] in
            var running = guiRunning
            if !running {
                let r = await Shell.runAsync("/usr/bin/pgrep", ["-ix", name], timeout: 5)
                running = r.ok && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard let self else { return }
            self.processCheckInFlight = false
            guard self.automations.processEnabled, self.automations.processName.trimmingCharacters(in: .whitespaces) == name else { return }
            if running { self.processSeen = true; self.processMisses = 0 }
            else if self.processSeen {
                self.processMisses += 1
                if self.processMisses >= 2, self.warning == nil {
                    self.processSeen = false; self.processMisses = 0
                    self.startWarning(action, reason: "\(name) has quit", trigger: .process)
                }
            }
        }
    }

    private static func hidIdleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Power trace

    private func sampleTrace() {
        let r = BatteryMonitor.shared.reading
        guard r.isPresent else { return }
        let w: Double
        if let s = r.systemPowerWatts { w = s }
        else if !r.isPluggedIn { w = max(0, -r.batteryPowerWatts) }
        else { return }
        powerTrace.append(max(0, w))
        if powerTrace.count > 60 { powerTrace.removeFirst(powerTrace.count - 60) }
    }

    // MARK: Closed-lid mode

    private static var flagURL: URL { AppPaths.supportFile("power-lid.flag") }
    private static func removeFlag() { try? FileManager.default.removeItem(at: flagURL) }

    private func clearLidDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.lidUntil); d.removeObject(forKey: Keys.lidFloor); d.set(false, forKey: Keys.lidActive)
    }

    /// Reads `pmset -g` (no admin needed) to learn the real SleepDisabled state.
    func refreshLid() async {
        let r = await Shell.runAsync("/usr/bin/pmset", ["-g"], timeout: 10)
        guard r.ok else { return }
        let disabled = PowerParsers.parseSleepDisabled(r.stdout) ?? false
        applyLid(disabled: disabled)
    }

    private func applyLid(disabled: Bool) {
        let d = UserDefaults.standard
        if !disabled {
            if case .on = lidState, !lidQuietEnd {
                Notifier.post(title: "Closed-lid mode ended", body: "Your Mac can sleep normally again.", id: "mm.power.lid.ended", sound: false)
            }
            lidState = .off
            Self.removeFlag(); clearLidDefaults()
            return
        }
        let ours = d.bool(forKey: Keys.lidActive) && FileManager.default.fileExists(atPath: Self.flagURL.path)
        if ours {
            let until = d.double(forKey: Keys.lidUntil)
            let floor = d.integer(forKey: Keys.lidFloor)
            lidState = .on(until: until > 0 ? Date(timeIntervalSince1970: until) : nil, floor: floor > 0 ? floor : nil)
        } else {
            lidState = .external
        }
    }

    /// Turns on closed-lid mode (`pmset -a disablesleep 1`, one admin prompt) and spawns a root
    /// watchdog that turns it back off on timeout, low battery, flag removal or when MacMaster exits.
    func enableClosedLid(duration: TimeInterval?, batteryFloor: Int?) async {
        guard !lidBusy else { return }
        lidBusy = true; lidError = nil
        defer { lidBusy = false }

        let flag = Self.flagURL
        try? Data("1".utf8).write(to: flag)
        let deadline = duration.map { Int(Date().timeIntervalSince1970 + $0) } ?? 0
        let floor = max(0, batteryFloor ?? 0)
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = [
            "FLAG=\(Shell.quote(flag.path)); PID=\(pid); DL=\(deadline); FLOOR=\(floor)",
            "/usr/bin/pmset -a disablesleep 1 || exit 1",
            "( trap \"\" HUP; i=0; while :; do /bin/sleep 2; i=$((i+1));"
                + " [ -e \"$FLAG\" ] || break;"
                + " kill -0 $PID 2>/dev/null || break;"
                + " if [ $DL -gt 0 ] && [ $(/bin/date +%s) -ge $DL ]; then break; fi;"
                + " if [ $FLOOR -gt 0 ] && [ $((i % 10)) -eq 0 ]; then o=$(/usr/bin/pmset -g batt);"
                + " case \"$o\" in *\"Battery Power\"*) p=$(echo \"$o\" | /usr/bin/grep -Eo \"[0-9]+%\" | /usr/bin/head -1 | /usr/bin/tr -d \"%\");"
                + " if [ -n \"$p\" ] && [ \"$p\" -lt $FLOOR ]; then break; fi;; esac; fi;"
                + " done; /usr/bin/pmset -a disablesleep 0 ) >/dev/null 2>&1 &",
        ].joined(separator: "; ")

        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/bin/sh", ["-c", script],
                             prompt: "MacMaster wants to keep your Mac awake with the lid closed. It will switch back automatically.")
        }.value

        if r.ok {
            let d = UserDefaults.standard
            d.set(true, forKey: Keys.lidActive)
            d.set(deadline > 0 ? Double(deadline) : 0, forKey: Keys.lidUntil)
            d.set(floor, forKey: Keys.lidFloor)
            lidState = .on(until: deadline > 0 ? Date(timeIntervalSince1970: Double(deadline)) : nil, floor: floor > 0 ? floor : nil)
            if !started { start() }
        } else {
            Self.removeFlag()
            let msg = r.stderr.lowercased().contains("cancel") ? nil : r.stderr
            lidError = msg.flatMap { $0.isEmpty ? nil : $0 }
            await refreshLid()
        }
    }

    /// One-click off. MacMaster-started sessions turn off without a password (the watchdog sees the
    /// flag disappear); anything else needs admin.
    func disableClosedLid() async {
        guard !lidBusy else { return }
        lidBusy = true; lidError = nil; lidQuietEnd = true
        defer { lidBusy = false; lidQuietEnd = false }

        if case .on = lidState {
            Self.removeFlag()
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshLid()
                if lidState == .off { return }
            }
        }
        // Watchdog missing or externally enabled: ask for admin.
        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/usr/bin/pmset", ["-a", "disablesleep", "0"],
                             prompt: "MacMaster wants to let your Mac sleep normally again.")
        }.value
        if !r.ok, !r.stderr.lowercased().contains("cancel") { lidError = r.stderr }
        Self.removeFlag(); clearLidDefaults()
        await refreshLid()
    }

    // MARK: Persistence helpers

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
