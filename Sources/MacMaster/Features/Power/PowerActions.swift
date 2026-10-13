import SwiftUI
import AppKit
import Darwin

/// Reusable power actions. Destructive ones (`restart`, `shutDown`, `logOut`) do nothing unless
/// `confirmed` is true: the caller must have asked the user first (see `PowerConfirm`).
enum PowerActions {
    static func sleep() async {
        _ = await Shell.runAsync("/usr/bin/pmset", ["sleepnow"])
    }

    static func displaySleep() async {
        _ = await Shell.runAsync("/usr/bin/pmset", ["displaysleepnow"])
    }

    static func screenSaver() async {
        _ = await Shell.runAsync("/usr/bin/open", ["-a", "ScreenSaverEngine"])
    }

    /// Locks the screen via the login framework; falls back to the Ctrl-Cmd-Q keystroke.
    static func lock() async {
        let ok = PowerPrivateLock.lockNow()
        if !ok {
            _ = await Shell.runAsync("/usr/bin/osascript", ["-e",
                "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"])
        }
    }

    /// - Parameter force: skips the app-by-app quit negotiation (unsaved work may be lost).
    @discardableResult
    static func restart(confirmed: Bool, force: Bool = false) async -> Bool {
        await systemEvent(confirmed: confirmed, force: force, normal: "restart", forceEvent: "aevtrrst")
    }

    @discardableResult
    static func shutDown(confirmed: Bool, force: Bool = false) async -> Bool {
        await systemEvent(confirmed: confirmed, force: force, normal: "shut down", forceEvent: "aevtrsdn")
    }

    @discardableResult
    static func logOut(confirmed: Bool, force: Bool = false) async -> Bool {
        await systemEvent(confirmed: confirmed, force: force, normal: "log out", forceEvent: "aevtrlgo")
    }

    /// Runs a (non-destructive or already-confirmed) action. Destructive kinds need `confirmed`.
    @discardableResult
    static func perform(_ kind: PowerActionKind, confirmed: Bool = false, force: Bool = false) async -> Bool {
        switch kind {
        case .sleep: await sleep(); return true
        case .displaySleep: await displaySleep(); return true
        case .lock: await lock(); return true
        case .screenSaver: await screenSaver(); return true
        case .restart: return await restart(confirmed: confirmed, force: force)
        case .shutDown: return await shutDown(confirmed: confirmed, force: force)
        case .logOut: return await logOut(confirmed: confirmed, force: force)
        }
    }

    private static func systemEvent(confirmed: Bool, force: Bool, normal: String, forceEvent: String) async -> Bool {
        guard confirmed else { return false }
        let script = force
            ? "tell application \"loginwindow\" to «event \(forceEvent)»"
            : "tell application \"System Events\" to \(normal)"
        let r = await Shell.runAsync("/usr/bin/osascript", ["-e", script], timeout: 20)
        return r.ok
    }
}

/// `SACLockScreenImmediate` from the (private but long-stable) login framework.
private enum PowerPrivateLock {
    static func lockNow() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return false }
        typealias Fn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        _ = fn()
        return true
    }
}

// MARK: - Confirmation UI (NSAlert)

/// Confirmation dialogs usable from both SwiftUI views and the menu bar.
@MainActor
enum PowerConfirm {
    /// Asks, then runs. Destructive actions get a warning and an optional "Force" path behind a second confirmation.
    static func run(_ kind: PowerActionKind) async {
        guard kind.isDestructive else { _ = await PowerActions.perform(kind); return }
        switch confirm(kind) {
        case .cancel: return
        case .normal: _ = await PowerActions.perform(kind, confirmed: true)
        case .force:
            if confirmForce(kind) { _ = await PowerActions.perform(kind, confirmed: true, force: true) }
        }
    }

    enum Choice { case cancel, normal, force }

    static func confirm(_ kind: PowerActionKind) -> Choice {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(kind.title) your Mac now?"
        a.informativeText = kind == .logOut
            ? "Apps will be asked to quit. Any unsaved work may be lost."
            : "Apps will be asked to quit before the Mac \(kind == .restart ? "restarts" : "shuts down"). Unsaved work may be lost."
        // Cancel is the default (Return) button so a stray keypress never powers the Mac off.
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: kind.title)
        a.addButton(withTitle: "Force \(kind.title)…")
        a.buttons[1].hasDestructiveAction = true
        switch a.runModal() {
        case .alertSecondButtonReturn: return .normal
        case .alertThirdButtonReturn: return .force
        default: return .cancel
        }
    }

    static func confirmForce(_ kind: PowerActionKind) -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Force \(kind.title.lowercased())?"
        a.informativeText = "This skips the usual save prompts. Anything you have not saved will be lost."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Force \(kind.title)")
        a.buttons[1].hasDestructiveAction = true
        return a.runModal() == .alertSecondButtonReturn
    }

    /// Confirmation for scheduling a destructive timed action. Returns true to proceed.
    static func confirmSchedule(_ action: PowerTimedAction, at date: Date) -> Bool {
        guard action != .sleep else { return true }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Schedule \(action.title.lowercased()) at \(f.string(from: date))?"
        a.informativeText = "MacMaster will notify you one minute before. Unsaved work may be lost, so save before then. You can cancel any time before it happens."
        a.addButton(withTitle: "Schedule")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Generic yes/no.
    static func ask(_ title: String, _ message: String, confirm: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.alertStyle = destructive ? .warning : .informational
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: confirm)
        a.addButton(withTitle: "Cancel")
        if destructive { a.buttons[0].hasDestructiveAction = true }
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Confirms and quits a process (apps get a polite terminate; offers Force Quit if it lingers).
    static func quitProcess(pid: Int32, name: String) async {
        guard ask("Quit \(name)?", "Unsaved changes in \(name) may be lost.", confirm: "Quit", destructive: true) else { return }
        PowerProcessControl.terminate(pid: pid)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if PowerProcessControl.isRunning(pid: pid),
           ask("\(name) did not quit", "It may be busy or showing a save dialog. Force quitting discards unsaved changes.",
               confirm: "Force Quit", destructive: true) {
            PowerProcessControl.terminate(pid: pid, force: true)
        }
    }
}

enum PowerProcessControl {
    static func isRunning(pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) { return !app.isTerminated }
        return kill(pid, 0) == 0
    }

    static func terminate(pid: Int32, force: Bool = false) {
        guard pid > 1, pid != getpid() else { return }
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
    }

    /// Path of the outermost `.app` bundle containing the process executable.
    static func bundlePath(forExecutable path: String?) -> String? {
        guard let path, let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// pid of the running app whose bundle lives at `bundlePath`.
    static func appPID(bundlePath: String?) -> Int32? {
        guard let bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleURL?.path == bundlePath }?.processIdentifier
    }

    /// System-owned processes must not be offered a Quit button.
    static func isProtected(path: String?) -> Bool {
        guard let path else { return true }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/private/var/")
    }
}
