import AppKit

struct RunningAppInfo: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let isRegular: Bool
}

/// Snapshot of `NSWorkspace.runningApplications`. Every `NSRunningApplication` property read is a
/// synchronous round trip to LaunchServices, so samplers that run every few seconds read this instead.
/// Rebuilt only when an app launches or quits. Safe to read from any thread.
final class RunningAppCache: @unchecked Sendable {
    static let shared = RunningAppCache()

    private let lock = NSLock()
    private var byPID: [pid_t: RunningAppInfo] = [:]
    private var stale = true
    private var observing = false

    /// All running apps (any activation policy).
    var apps: [RunningAppInfo] {
        ensureFresh()
        lock.lock(); defer { lock.unlock() }
        return Array(byPID.values)
    }

    var regularApps: [RunningAppInfo] { apps.filter(\.isRegular) }

    subscript(pid: pid_t) -> RunningAppInfo? {
        ensureFresh()
        lock.lock(); defer { lock.unlock() }
        return byPID[pid]
    }

    func invalidate() {
        lock.lock(); stale = true; lock.unlock()
    }

    private func ensureFresh() {
        lock.lock()
        let needs = stale
        lock.unlock()
        guard needs else { return }
        startObserving()
        var map: [pid_t: RunningAppInfo] = [:]
        for a in NSWorkspace.shared.runningApplications where !a.isTerminated {
            let pid = a.processIdentifier
            guard pid > 0 else { continue }
            map[pid] = RunningAppInfo(pid: pid, name: a.localizedName ?? ProcessReader.name(of: pid),
                                      bundleID: a.bundleIdentifier, bundlePath: a.bundleURL?.path,
                                      isRegular: a.activationPolicy == .regular)
        }
        lock.lock()
        byPID = map
        stale = false
        lock.unlock()
    }

    private func startObserving() {
        lock.lock()
        let already = observing
        observing = true
        lock.unlock()
        guard !already else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.invalidate() }
        }
        // Activation policy can change at runtime (apps toggling their Dock icon); cheap to catch here.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.lock.lock()
            let known = self.byPID[pid]?.isRegular == true
            self.lock.unlock()
            if !known { self.invalidate() }
        }
    }
}
