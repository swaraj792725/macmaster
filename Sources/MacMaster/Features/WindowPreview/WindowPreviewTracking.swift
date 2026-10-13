import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Most-recently-used tracking

private let recencyAXCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let r = Unmanaged<WindowPreviewRecency>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { r.axFocusChanged(element) }
}

/// Tracks which apps and windows were focused most recently, so the switcher can order by MRU.
/// Event driven (NSWorkspace activation + AX focused-window notifications): zero cost while idle.
@MainActor
final class WindowPreviewRecency {
    static let shared = WindowPreviewRecency()

    private var tick = 0
    private var windowStamp: [UInt32: Int] = [:]
    private var appStamp: [pid_t: Int] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private(set) var started = false
    private(set) var previousPID: pid_t?

    /// Called after the frontmost app changed: (new pid, previous pid).
    var onActivation: ((pid_t, pid_t?) -> Void)?
    /// Called once the newly active app's focused window is known: (window id, pid).
    var onFocusedWindow: ((UInt32, pid_t) -> Void)?
    /// Called when apps launch / quit / hide, so cached window lists can be refreshed.
    var onAppsChanged: (() -> Void)?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        if let f = NSWorkspace.shared.frontmostApplication { appStamp[f.processIdentifier] = next() }
        seedFromZOrder()
        attachAll()

        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.launched(pid) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.terminated(pid) }
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onAppsChanged?() }
            })
        }
    }

    func stop() {
        guard started else { return }
        started = false
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        for (_, o) in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observers = [:]
        previousPID = nil
    }

    // MARK: Scores

    private func next() -> Int { tick += 1; return tick }

    /// Higher = more recently used. Windows never seen focused inherit their app's recency (slightly lower).
    func score(_ w: WindowPreviewWindow) -> Double {
        if let s = windowStamp[w.id] { return Double(s) }
        return Double(appStamp[w.pid] ?? 0) - 0.5
    }

    func appScore(_ pid: pid_t) -> Double { Double(appStamp[pid] ?? 0) }

    func noteWindow(_ id: UInt32, pid: pid_t) {
        windowStamp[id] = next()
        appStamp[pid] = tick
        if windowStamp.count > 600 {
            for (k, _) in windowStamp.sorted(by: { $0.value < $1.value }).prefix(200) { windowStamp[k] = nil }
        }
    }

    // MARK: Events

    private func activated(_ pid: pid_t) {
        let prev = frontPID
        frontPID = pid
        appStamp[pid] = next()
        if observers[pid] == nil { attach(pid) }
        previousPID = (prev != pid) ? prev : previousPID
        onActivation?(pid, prev != pid ? prev : nil)
        // Which window of the app is focused? Read off-main (AX can be slow for busy apps).
        Task { [weak self] in
            let id = await Task.detached(priority: .utility) { () -> UInt32? in
                let a = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(a, 0.3)
                guard let w = WindowPreviewAX.attr(a, kAXFocusedWindowAttribute),
                      CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
                return WindowPreviewAX.windowID(w as! AXUIElement)
            }.value
            if let id, let self, self.started {
                self.noteWindow(id, pid: pid)
                self.onFocusedWindow?(id, pid)
            }
        }
    }

    private var frontPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier

    private func launched(_ pid: pid_t) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.started else { return }
            self.attach(pid)
            self.onAppsChanged?()
        }
    }

    private func terminated(_ pid: pid_t) {
        if let o = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        }
        appStamp[pid] = nil
        onAppsChanged?()
    }

    fileprivate func axFocusChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, let id = WindowPreviewAX.windowID(element) else { return }
        noteWindow(id, pid: pid)
    }

    // MARK: Observers

    private func attachAll() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(\.processIdentifier)
        // One app per turn so a hung app can't stall the main thread for long.
        Task { [weak self] in
            for pid in pids {
                guard let self, self.started else { return }
                self.attach(pid)
                await Task.yield()
            }
        }
    }

    private func attach(_ pid: pid_t) {
        guard observers[pid] == nil, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, recencyAXCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let a = AXObserverAddNotification(obs, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(obs, app, kAXMainWindowChangedNotification as CFString, refcon)
        guard a == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    /// Initial MRU guess from the global z-order (front window = most recent).
    private func seedFromZOrder() {
        Task { [weak self] in
            let infos = await Task.detached(priority: .utility) { WindowPreviewEnumerator.cgInfo() }.value
            guard let self, self.started else { return }
            for i in infos.filter({ $0.onScreen && $0.layer == 0 && $0.bounds.width > 100 }).reversed() {
                if self.windowStamp[i.id] == nil { self.windowStamp[i.id] = self.next() }
                self.appStamp[i.pid] = max(self.appStamp[i.pid] ?? 0, self.windowStamp[i.id] ?? 0)
            }
            if let f = self.frontPID { self.appStamp[f] = self.next() }
        }
    }
}

// MARK: - Window list cache + background thumbnail prefetch

/// Keeps a recent window list and low-resolution thumbnails so the switcher can open instantly
/// from cache (stale-while-revalidate). Work is skipped while the user is idle, and the polling
/// interval backs off exponentially while nothing changes.
@MainActor
final class WindowPreviewWindowCache {
    static let shared = WindowPreviewWindowCache()

    private(set) var windows: [WindowPreviewWindow] = []
    private(set) var hasData = false
    private(set) var lastRefresh = Date.distantPast

    private let baseInterval: TimeInterval = 8
    private let maxInterval: TimeInterval = 90
    private var interval: TimeInterval = 8
    private var started = false
    private var loopTask: Task<Void, Never>?
    private var inflight: Task<[WindowPreviewWindow], Never>?
    private var signature = 0
    private var forcePIDs = Set<pid_t>()

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let rec = WindowPreviewRecency.shared
        rec.start()
        rec.onActivation = { [weak self] _, prev in self?.kick(previous: prev) }
        rec.onAppsChanged = { [weak self] in self?.kick(previous: nil) }
        rec.onFocusedWindow = { [weak self] id, _ in self?.captureActive(id) }
        restartLoop(delay: 0.3)
    }

    func stop() {
        guard started else { return }
        started = false
        loopTask?.cancel(); loopTask = nil
        inflight?.cancel(); inflight = nil
        let rec = WindowPreviewRecency.shared
        rec.onActivation = nil
        rec.onAppsChanged = nil
        rec.onFocusedWindow = nil
        activeCapture?.cancel(); activeCapture = nil
        rec.stop()
        windows = []
        hasData = false
        signature = 0
        Task { await WindowPreviewThumbnailer.shared.clear() }
    }

    /// Re-read the window list now (shared with any refresh already running).
    @discardableResult
    func refresh() async -> [WindowPreviewWindow] {
        if let t = inflight { return await t.value }
        let apps = WindowPreviewEnumerator.runningApps()
        let t = Task { await WindowPreviewEnumerator.allWindows(apps: apps, includeMinimized: true) }
        inflight = t
        let wins = await t.value
        inflight = nil
        windows = wins
        hasData = true
        lastRefresh = Date()
        return wins
    }

    /// The active window is the only one Stage Manager shows full size and untilted, so grab it
    /// shortly after activation (once the slide-in animation settles). That picture is what the
    /// switcher shows later while the window sits in the strip, and it is saved to disk.
    private var activeCapture: Task<Void, Never>?
    private func captureActive(_ id: UInt32) {
        let s = WindowPreviewSettings.shared
        guard started, id & 0x8000_0000 == 0, Permissions.isGranted(.screenRecording) else { return }
        let box = CGSize(width: s.switcherSize.switcherSize.width * 1.5, height: s.switcherSize.switcherSize.height * 1.5)
        activeCapture?.cancel()
        activeCapture = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            _ = await WindowPreviewThumbnailer.shared.capture(id: id, box: box, maxAge: 20)
        }
    }

    /// Something changed (app activated / launched / quit): re-arm the loop with the base interval.
    private func kick(previous: pid_t?) {
        guard started else { return }
        if let previous { forcePIDs.insert(previous) }
        interval = baseInterval
        restartLoop(delay: 0.6)
    }

    // MARK: Loop

    private func restartLoop(delay: TimeInterval) {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                guard let self, self.started else { return }
                var wait: TimeInterval
                if Self.userIsActive() {
                    let changed = await self.tickOnce()
                    self.interval = changed ? self.baseInterval : min(self.interval * 2, self.maxInterval)
                    wait = self.interval
                } else {
                    wait = 30 // idle: do nothing, just re-check occasionally
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled { wait *= 2 }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private static func userIsActive() -> Bool {
        guard let any = CGEventType(rawValue: ~0) else { return true }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < 45
    }

    /// One refresh + prefetch round. Returns whether the window set changed.
    private func tickOnce() async -> Bool {
        let wins = await refresh()
        var h = Hasher()
        for w in wins.sorted(by: { $0.id < $1.id }) {
            h.combine(w.id); h.combine(w.title); h.combine(w.isMinimized); h.combine(w.isOnScreen)
        }
        let sig = h.finalize()
        let changed = sig != signature
        signature = sig
        let force = forcePIDs
        forcePIDs = []
        await prefetch(force: force)
        await WindowPreviewThumbnailer.shared.prune(keeping: Set(wins.map(\.id)))
        return changed
    }

    /// Low-resolution thumbnails of on-screen windows only. Missing ones, plus ones that just lost
    /// focus (`force`), are captured; everything else is left alone.
    private func prefetch(force: Set<pid_t>) async {
        let s = WindowPreviewSettings.shared
        guard s.switcherPrefetch, Permissions.isGranted(.screenRecording),
              ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        let rec = WindowPreviewRecency.shared
        let candidates = windows
            .filter { $0.isOnScreen && !$0.isMinimized && $0.id & 0x8000_0000 == 0 }
            .sorted { rec.score($0) > rec.score($1) }
            .prefix(10)
        let thumbs = WindowPreviewThumbnailer.shared
        let box = CGSize(width: s.switcherSize.switcherSize.width * 1.5, height: s.switcherSize.switcherSize.height * 1.5)
        var todo: [(id: UInt32, maxAge: TimeInterval)] = []
        for w in candidates {
            let age = await thumbs.peek(w.id)?.age ?? .infinity
            let limit: TimeInterval = force.contains(w.pid) ? 2 : 90
            if age > limit { todo.append((w.id, limit)) }
        }
        guard !todo.isEmpty else { return }
        todo = Array(todo.prefix(6))
        await withTaskGroup(of: Void.self) { group in
            var it = todo.makeIterator()
            var running = 0
            while running < 2, let t = it.next() {
                group.addTask(priority: .utility) { _ = await thumbs.capture(id: t.id, box: box, maxAge: t.maxAge) }
                running += 1
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let t = it.next() {
                    group.addTask(priority: .utility) { _ = await thumbs.capture(id: t.id, box: box, maxAge: t.maxAge) }
                }
            }
        }
    }
}
