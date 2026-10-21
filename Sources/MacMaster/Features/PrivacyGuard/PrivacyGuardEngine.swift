import AppKit
import AVFoundation
import Observation
import os

/// Keys and defaults for Privacy Guard settings (`@AppStorage` in the view, read here every frame).
enum PrivacyGuardKeys {
    static let enabled = "mm.privacyGuard.enabled"
    static let hotkey = "mm.privacyGuard.hotkey"
    static let menuBar = "mm.privacyGuard.menuBar"
    static let walkAway = "mm.privacyGuard.walkAway"
    static let walkAwayDelay = "mm.privacyGuard.walkAwayDelay"
    static let lockEnabled = "mm.privacyGuard.lock"
    static let lockDelay = "mm.privacyGuard.lockDelay"
    static let shoulder = "mm.privacyGuard.shoulder"
    static let shoulderNotify = "mm.privacyGuard.shoulderNotify"
    static let lookAway = "mm.privacyGuard.lookAway"
    static let lookAwayDelay = "mm.privacyGuard.lookAwayDelay"
    static let lookAwayAngle = "mm.privacyGuard.lookAwayAngle"
}

private struct PrivacyGuardSettings {
    var walkAway: Bool
    var walkAwayDelay: Double
    var lock: Bool
    var lockDelay: Double
    var shoulder: Bool
    var shoulderNotify: Bool
    var lookAway: Bool
    var lookAwayDelay: Double
    var lookAwayAngle: Double

    static func load() -> PrivacyGuardSettings {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        return PrivacyGuardSettings(
            walkAway: bool(PrivacyGuardKeys.walkAway, true),
            walkAwayDelay: max(1, num(PrivacyGuardKeys.walkAwayDelay, 5)),
            lock: bool(PrivacyGuardKeys.lockEnabled, false),
            lockDelay: max(5, num(PrivacyGuardKeys.lockDelay, 60)),
            shoulder: bool(PrivacyGuardKeys.shoulder, true),
            shoulderNotify: bool(PrivacyGuardKeys.shoulderNotify, true),
            lookAway: bool(PrivacyGuardKeys.lookAway, false),
            lookAwayDelay: max(1, num(PrivacyGuardKeys.lookAwayDelay, 3)),
            lookAwayAngle: max(15, num(PrivacyGuardKeys.lookAwayAngle, 40)))
    }
}

/// Watches the camera for faces and covers the screen when you walk away, someone looks over your shoulder, or
/// you look away. The camera only runs while the guard is on and not paused, locked or asleep.
@MainActor @Observable
final class PrivacyGuardEngine {
    static let shared = PrivacyGuardEngine()

    // MARK: Observable state (for the view)

    /// The user turned the guard on. Persisted.
    private(set) var isOn: Bool
    /// Temporarily off (hotkey or menu bar). Not persisted.
    private(set) var isPaused = false
    /// Display asleep, screen locked or system asleep.
    private(set) var isSuspended = false
    /// Faces in the latest frame; nil when the camera is not running.
    private(set) var faceCount: Int?
    private(set) var blurReason: PrivacyGuardReason?
    private(set) var snoozedUntil: Date?
    /// Set when the camera is missing, busy or failed. Shown in the view.
    private(set) var problem: String?
    /// The user tried to turn it on and macOS said no.
    private(set) var cameraDenied = false
    /// True once the camera is delivering frames.
    private(set) var cameraLive = false

    /// The live feed, for the optional preview in the tool view.
    var previewSession: AVCaptureSession { camera.session }

    // MARK: Private

    @ObservationIgnored private let log = Logger(subsystem: "com.macmaster.app", category: "privacyGuard")
    @ObservationIgnored private let camera = PrivacyGuardCamera()
    @ObservationIgnored private let overlay = PrivacyGuardOverlay()
    @ObservationIgnored private var cameraRunning = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var menuItem: NSStatusItem?
    @ObservationIgnored private var menuTarget: MenuTarget?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    // Detection timing (all in ProcessInfo.systemUptime seconds).
    @ObservationIgnored private var lastFaceAt: TimeInterval = 0
    @ObservationIgnored private var multiFaceSince: TimeInterval?
    @ObservationIgnored private var lookAwaySince: TimeInterval?
    @ObservationIgnored private var clearSince: TimeInterval?
    @ObservationIgnored private var lockedThisAbsence = false
    @ObservationIgnored private var lastNotifyAt: TimeInterval = 0
    @ObservationIgnored private var snoozeTask: Task<Void, Never>?

    /// A face must be gone this long before the cover is lifted again, so it doesn't flicker.
    private let clearGrace: TimeInterval = 0.7
    /// More than one face must stay for this long before it counts (a passer-by or a glitch is not a surfer).
    private let shoulderConfirm: TimeInterval = 0.8

    private init() {
        isOn = UserDefaults.standard.bool(forKey: PrivacyGuardKeys.enabled)
        overlay.onSnooze = { [weak self] in self?.snooze() }
    }

    // MARK: Lifecycle

    /// Runs once at launch: hooks system events and the hotkey, and resumes the guard if it was left on.
    func start() {
        guard !started else { return }
        started = true
        observeSystem()
        registerHotKey()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMenuBar() }
        }
        if isOn {
            // Never prompt at launch: without permission the guard waits for the user to open the tool.
            if Permissions.isGranted(.camera) { reconcile() } else { cameraDenied = true }
        }
        updateMenuBar()
    }

    func registerHotKey() {
        GlobalHotKeys.shared.register("privacyGuard.toggle", defaultsKey: PrivacyGuardKeys.hotkey, press: { [weak self] in
            self?.hotKeyPressed()
        })
    }

    /// The big switch in the tool view and the Stop item in the menu bar.
    func setOn(_ on: Bool) {
        if on {
            guard !isOn || cameraDenied else { return }
            Permissions.requestMedia(.camera) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.cameraDenied = false
                    self.isOn = true
                    self.isPaused = false
                    UserDefaults.standard.set(true, forKey: PrivacyGuardKeys.enabled)
                    self.reconcile()
                } else {
                    self.cameraDenied = true
                    self.isOn = false
                    UserDefaults.standard.set(false, forKey: PrivacyGuardKeys.enabled)
                    self.reconcile()
                }
            }
        } else {
            isOn = false
            isPaused = false
            cameraDenied = false
            UserDefaults.standard.set(false, forKey: PrivacyGuardKeys.enabled)
            reconcile()
        }
    }

    func setPaused(_ paused: Bool) {
        guard isOn, isPaused != paused else { return }
        isPaused = paused
        reconcile()
    }

    private func hotKeyPressed() {
        if !isOn { setOn(true) } else { setPaused(!isPaused) }
    }

    /// Hides the cover and ignores triggers for a minute.
    func snooze(seconds: TimeInterval = 60) {
        snoozedUntil = Date().addingTimeInterval(seconds)
        clearCover()
        resetTimers()
        snoozeTask?.cancel()
        snoozeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.snoozedUntil = nil
        }
    }

    // MARK: Camera on / off

    /// Brings the camera and the cover in line with the current state.
    private func reconcile() {
        let shouldRun = isOn && !isPaused && !isSuspended && Permissions.isGranted(.camera)
        if shouldRun, !cameraRunning {
            cameraRunning = true
            problem = nil
            resetTimers()
            lastFaceAt = ProcessInfo.processInfo.systemUptime
            camera.start(onReading: { [weak self] reading in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(reading) } }
            }, onFailure: { [weak self] failure in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.cameraStatus(failure) } }
            })
        } else if !shouldRun, cameraRunning {
            cameraRunning = false
            camera.stop()
            cameraLive = false
            faceCount = nil
            clearCover()
            resetTimers()
        }
        if isOn, !Permissions.isGranted(.camera) { cameraDenied = true }
        updateMenuBar()
    }

    private func cameraStatus(_ failure: PrivacyGuardCamera.Failure?) {
        guard cameraRunning else { return }
        guard let failure else { cameraLive = true; problem = nil; return }
        cameraLive = false
        switch failure {
        case .noCamera: problem = "No camera found. Connect one and turn Privacy Guard on again."
        case .cannotOpen: problem = "The camera could not be opened. Another app may be using it."
        case .interrupted: problem = "Another app took the camera. Privacy Guard will carry on when it lets go."
        case .runtime: problem = "The camera stopped. Trying again."
        }
        // Without a picture nothing can be judged: don't keep the screen covered on a guess.
        if failure != .interrupted && failure != .runtime { faceCount = nil }
    }

    // MARK: Detection

    private func resetTimers() {
        multiFaceSince = nil
        lookAwaySince = nil
        clearSince = nil
        lockedThisAbsence = false
        lastFaceAt = ProcessInfo.processInfo.systemUptime
    }

    private func handle(_ r: PrivacyGuardReading) {
        guard cameraRunning else { return }
        cameraLive = true
        if faceCount != r.faces { faceCount = r.faces }
        let now = ProcessInfo.processInfo.systemUptime
        let s = PrivacyGuardSettings.load()

        if r.faces >= 1 { lastFaceAt = now; lockedThisAbsence = false }
        multiFaceSince = r.faces >= 2 ? (multiFaceSince ?? now) : nil
        if r.faces == 1, let yaw = r.yawDegrees, yaw > s.lookAwayAngle { lookAwaySince = lookAwaySince ?? now } else { lookAwaySince = nil }

        // Which trigger (if any) is active right now. Order = importance.
        var active: PrivacyGuardReason?
        if s.shoulder, let t = multiFaceSince, now - t >= shoulderConfirm { active = .shoulderSurfer }
        else if s.walkAway, r.faces == 0, now - lastFaceAt >= s.walkAwayDelay { active = .walkAway }
        else if s.lookAway, let t = lookAwaySince, now - t >= s.lookAwayDelay { active = .lookAway }

        if let snooze = snoozedUntil, snooze > Date() { active = nil }

        if let active {
            clearSince = nil
            if blurReason != active { cover(active, settings: s) }
            if active == .walkAway, s.lock, !lockedThisAbsence, now - lastFaceAt >= s.lockDelay {
                lockedThisAbsence = true
                log.notice("walk away: locking the screen")
                KeyboardSystemActions.lockScreen()
            }
        } else if blurReason != nil {
            // Wait a moment before uncovering so a blink or a turned head doesn't flicker the screen.
            clearSince = clearSince ?? now
            if now - (clearSince ?? now) >= clearGrace { clearCover() }
        }
    }

    private func cover(_ reason: PrivacyGuardReason, settings s: PrivacyGuardSettings) {
        let wasShoulder = blurReason == .shoulderSurfer
        blurReason = reason
        overlay.show(reason)
        updateMenuBar()
        if reason == .shoulderSurfer, !wasShoulder, s.shoulderNotify {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastNotifyAt > 30 {
                lastNotifyAt = now
                Notifier.post(title: "Privacy Guard", body: "Someone is looking at your screen", id: "mm.privacyGuard.shoulder", sound: false)
            }
        }
    }

    private func clearCover() {
        clearSince = nil
        guard blurReason != nil || overlay.isShown else { return }
        blurReason = nil
        overlay.hide()
        updateMenuBar()
    }

    // MARK: Sleep / lock

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (PrivacyGuardEngine) -> Void) {
            observers.append((c, c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }))
        }
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            on(ws, n) { $0.setSuspended(true) }
        }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            on(ws, n) { $0.setSuspended(false) }
        }
        on(dn, Notification.Name("com.apple.screenIsLocked")) { $0.setSuspended(true) }
        on(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspended(false) }
        on(NotificationCenter.default, NSApplication.willTerminateNotification) { $0.shutdown() }
    }

    private func setSuspended(_ s: Bool) {
        guard isSuspended != s else { return }
        // Waking while still locked: the unlock notification brings us back, not the wake.
        if !s, Self.screenIsLocked() { return }
        isSuspended = s
        reconcile()
    }

    private static func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func shutdown() {
        camera.stop()
        overlay.hide(animated: false)
    }

    // MARK: Menu bar

    private final class MenuTarget: NSObject {
        let engine: PrivacyGuardEngine
        init(_ e: PrivacyGuardEngine) { engine = e }
        @MainActor @objc func togglePause() { engine.setPaused(!engine.isPaused) }
        @MainActor @objc func stop() { engine.setOn(false) }
        @MainActor @objc func snoozeNow() { engine.snooze() }
    }

    private func updateMenuBar() {
        let want = isOn && (UserDefaults.standard.object(forKey: PrivacyGuardKeys.menuBar) as? Bool ?? true)
        guard want else {
            if let it = menuItem { NSStatusBar.system.removeStatusItem(it); menuItem = nil }
            return
        }
        let item: NSStatusItem
        if let it = menuItem { item = it } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            menuItem = item
            if menuTarget == nil { menuTarget = MenuTarget(self) }
        }
        let symbol = isPaused ? "eye.slash" : "eye"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Privacy Guard")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = isPaused ? "Privacy Guard (paused)" : "Privacy Guard"

        let menu = NSMenu()
        let status: String
        if isPaused { status = "Paused" }
        else if blurReason != nil { status = "Screen covered" }
        else if let n = faceCount { status = n == 1 ? "Watching • 1 face" : "Watching • \(n) faces" }
        else { status = isSuspended ? "Waiting for the screen to wake" : "Starting…" }
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        guard let t = menuTarget else { return }
        let pause = NSMenuItem(title: isPaused ? "Resume" : "Pause", action: #selector(MenuTarget.togglePause), keyEquivalent: "")
        pause.target = t
        menu.addItem(pause)
        if blurReason != nil {
            let sn = NSMenuItem(title: "Show screen for 1 minute", action: #selector(MenuTarget.snoozeNow), keyEquivalent: "")
            sn.target = t
            menu.addItem(sn)
        }
        let stop = NSMenuItem(title: "Stop Privacy Guard", action: #selector(MenuTarget.stop), keyEquivalent: "")
        stop.target = t
        menu.addItem(stop)
        item.menu = menu
    }
}

extension AppSearchIndex {
    /// Privacy Guard settings, added to the global search.
    static let privacyGuardEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Privacy Guard", "Blur when I walk away", "walk away no face absent screen blur hide", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Lock the screen after walking away", "lock sleep display password absent", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Shoulder surfer alert", "someone looking over shoulder second person blur notification", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Blur when I look away", "look away head turn yaw attention", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Privacy Guard shortcut", "pause resume hotkey toggle camera guard", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Privacy Guard menu bar icon", "eye menu bar pause stop", tab: "privacyGuard"),
        SearchEntry(.tools, crumb: "Privacy Guard", "Camera preview", "camera face preview live", tab: "privacyGuard"),
    ]
}
