import AppKit
import os

let windowExtrasLog = Logger(subsystem: "com.macmaster.app", category: "windowExtras")

/// Persisted settings (`mm.windowExtras.*`). Every feature is off by default.
enum WindowExtrasSettings {
    enum Key {
        static let debounce = "mm.windowExtras.debounce"
        static let debounceMs = "mm.windowExtras.debounceMs"
        static let debounceRight = "mm.windowExtras.debounceRight"
        static let blockedClicks = "mm.windowExtras.blockedClicks"
        static let dockMinimize = "mm.windowExtras.dockMinimize"
        static let quitOnLastClose = "mm.windowExtras.quitOnLastClose"
        static let quitExcluded = "mm.windowExtras.quitExcluded"
        static let greenMaximize = "mm.windowExtras.greenMaximize"
    }

    static let debounceRange: ClosedRange<Double> = 30...150
    static let defaultDebounceMs = 60.0

    /// Never quit: Finder and MacMaster itself. Not editable.
    static let builtInExcluded: [String] = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "com.macmaster.app"]

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var debounceMs: Double {
        let v = UserDefaults.standard.object(forKey: Key.debounceMs) as? Double ?? defaultDebounceMs
        return min(max(v, debounceRange.lowerBound), debounceRange.upperBound)
    }

    /// Bundle ids the user added to the "keep open" list.
    static var userExcluded: [String] {
        get {
            (UserDefaults.standard.string(forKey: Key.quitExcluded) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: Key.quitExcluded) }
    }

    static var excluded: Set<String> { Set(builtInExcluded).union(userExcluded) }
}

/// Click debounce, Dock-click minimize, quit-on-last-window and green-button maximize.
/// Each feature starts its own tap or monitor only while it is on; with everything off nothing runs.
/// `start()` runs once at launch from `Services.startAll()`.
@MainActor @Observable
final class WindowExtrasEngine {
    static let shared = WindowExtrasEngine()
    private init() {}

    /// The click tap (debounce, green button) is running.
    private(set) var clickTapRunning = false

    @ObservationIgnored private var runner: KeyboardTapRunner?
    @ObservationIgnored private var clickTap: WindowExtrasClickTap?
    @ObservationIgnored private var tapShape = ""
    @ObservationIgnored private let watchers = WindowExtrasWatchers()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var reconcilePending = false
    /// Part of this run's blocked clicks already added to the saved total.
    @ObservationIgnored private var savedOfRun = 0
    /// Uptime of the last failed tap start, so a missing permission doesn't retry on every defaults change.
    @ObservationIgnored private var lastFailedStart = -100.0

    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        }
        reconcile()
    }

    /// Settings views call this after a change; it also runs on any UserDefaults change.
    func settingsChanged() { scheduleReconcile() }

    /// Total chattering clicks blocked so far.
    var blockedClicks: Int {
        UserDefaults.standard.integer(forKey: WindowExtrasSettings.Key.blockedClicks)
            + max(0, (clickTap?.blockedThisRun ?? 0) - savedOfRun)
    }

    func resetBlockedClicks() {
        savedOfRun = clickTap?.blockedThisRun ?? 0
        UserDefaults.standard.set(0, forKey: WindowExtrasSettings.Key.blockedClicks)
    }

    // MARK: Internals

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcilePending = false
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        if Services.isSnapshotRun { return }
        typealias K = WindowExtrasSettings.Key
        let debounce = WindowExtrasSettings.bool(K.debounce)
        let green = WindowExtrasSettings.bool(K.greenMaximize)
        let dock = WindowExtrasSettings.bool(K.dockMinimize)
        let quit = WindowExtrasSettings.bool(K.quitOnLastClose)

        guard debounce || green || dock || quit else {
            stopTap()
            watchers.apply(dockMinimize: false, quitOnLastClose: false)
            timer?.invalidate()
            timer = nil
            return
        }
        guard Permissions.isGranted(.accessibility) else {
            stopTap()
            watchers.apply(dockMinimize: false, quitOnLastClose: false)
            startTimer()   // keeps polling so the features come up once Accessibility is granted
            return
        }

        let shape = "\(debounce || green)/\(quit)"
        if clickTap != nil && tapShape != shape {
            stopTap()   // the event mask is fixed when the tap is created
        }
        if debounce || green || quit {
            let cfg = WindowExtrasClickTap.Config(
                debounce: debounce, debounceRight: WindowExtrasSettings.bool(K.debounceRight),
                thresholdNs: UInt64(WindowExtrasSettings.debounceMs * 1_000_000), green: green)
            if let tap = clickTap {
                tap.config.withLock { $0 = cfg }
            } else if ProcessInfo.processInfo.systemUptime - lastFailedStart > 5 {
                let tap = WindowExtrasClickTap(config: cfg)
                let quitter = watchers.quit
                if quit { tap.onCloseShortcut = { quitter.closeShortcut() } }
                let r = KeyboardTapRunner(name: "macmaster.windowextras", types: WindowExtrasClickTap.eventTypes(mouse: debounce || green, keys: quit),
                                          onDisabled: { [weak tap] in
                    windowExtrasLog.error("click tap was disabled by the system; re-enabled")
                    tap?.reset()
                }) { type, event in tap.handle(type, event) }
                if r.start() {
                    clickTap = tap
                    tapShape = shape
                    runner = r
                    savedOfRun = 0
                    clickTapRunning = true
                    windowExtrasLog.info("click tap started")
                } else {
                    windowExtrasLog.error("click tap failed to start")
                    lastFailedStart = ProcessInfo.processInfo.systemUptime
                }
            }
        } else {
            stopTap()
        }
        watchers.apply(dockMinimize: dock, quitOnLastClose: quit)
        startTimer()
    }

    private func stopTap() {
        saveBlocked()
        guard let r = runner else { return }
        windowExtrasLog.info("click tap stopped")
        r.stop()
        runner = nil
        clickTap = nil
        savedOfRun = 0
        clickTapRunning = false
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 1
        timer = t
    }

    private func tick() {
        saveBlocked()
        let granted = Permissions.isGranted(.accessibility)
        if granted != (runner != nil || watchers.isRunning) {
            reconcile()   // permission came or went
        } else if let r = runner, !r.isEnabled {
            windowExtrasLog.error("click tap unhealthy; restarting")
            stopTap()
            reconcile()
        }
    }

    /// Adds this run's new blocked clicks to the saved total.
    private func saveBlocked() {
        guard let tap = clickTap else { return }
        let n = tap.blockedThisRun
        guard n > savedOfRun else { return }
        let key = WindowExtrasSettings.Key.blockedClicks
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + (n - savedOfRun), forKey: key)
        savedOfRun = n
    }
}

extension AppSearchIndex {
    /// Window and mouse extras settings, added to the global search.
    static let windowExtrasEntries: [SearchEntry] = [
        SearchEntry(.mouse, crumb: "Clicks", "Fix double-clicks (click debounce)",
                    "chattering worn mouse double click ghost click bounce ignore repeated", anchor: "mouse.clicks"),
        SearchEntry(.mouse, crumb: "Clicks", "Debounce time", "milliseconds ms chatter threshold right click", anchor: "mouse.clicks"),
        SearchEntry(.windows, crumb: "Window behavior", "Click Dock icon to minimize",
                    "dock taskbar minimize restore active app windows", anchor: "windows.behavior"),
        SearchEntry(.windows, crumb: "Window behavior", "Quit app when its last window closes",
                    "close window quit terminate red button command w exclude keep open", anchor: "windows.behavior"),
        SearchEntry(.windows, crumb: "Window behavior", "Green button maximizes instead of full screen",
                    "zoom green traffic light fullscreen maximize fill option click", anchor: "windows.behavior"),
    ]
    /// Clipboard upgrades (plain-text paste, link cleaning, auto-clear), added to the global search.
    static let clipboardExtrasEntries: [SearchEntry] = []
    /// Cleaner project junk and Uninstaller unused-apps entries, added to the global search.
    static let devToolsEntries: [SearchEntry] = []
}
