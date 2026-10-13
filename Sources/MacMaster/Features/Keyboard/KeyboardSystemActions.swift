import AppKit
import CoreGraphics

/// Posts synthetic key events. Every event carries `marker` so MacMaster's own taps ignore it.
enum KeyboardKeyPoster {
    static let marker: Int64 = 0x4D4D4B42 // "MMKB"

    static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let src = CGEventSource(stateID: .privateState),
              let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    static func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(code, down: true, flags: flags)
        post(code, down: false, flags: flags)
    }
}

/// Everything a shortcut or hot corner can do.
enum KeyboardSystemActions {
    // MARK: Private symbols (resolved lazily; every use has a fallback)

    private typealias CoreDockFn = @convention(c) (CFString, Int32) -> Void
    private typealias LockFn = @convention(c) () -> Int32

    private static let coreDockSend: CoreDockFn? = {
        let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        guard let sym = dlsym(h ?? UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockFn.self)
    }()

    private static let lockScreenFn: LockFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(sym, to: LockFn.self)
    }()

    // MARK: Dock-driven

    @discardableResult
    private static func dock(_ name: String) -> Bool {
        guard let f = coreDockSend else { return false }
        f(name as CFString, 0)
        return true
    }

    static func missionControl() {
        if dock("com.apple.expose.awake") { return }
        if !openApp("/System/Applications/Mission Control.app") {
            KeyboardKeyPoster.tap(126, flags: .maskControl)
        }
    }

    static func appExpose() {
        if dock("com.apple.expose.front.awake") { return }
        KeyboardKeyPoster.tap(125, flags: .maskControl)
    }

    static func showDesktop() {
        if dock("com.apple.showdesktop.awake") { return }
        KeyboardKeyPoster.tap(103) // F11
    }

    static func launchpad() {
        for path in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        where FileManager.default.fileExists(atPath: path) {
            if openApp(path) { return }
        }
        if dock("com.apple.launchpad.toggle") { return }
        KeyboardKeyPoster.tap(160) // Launchpad media key
    }

    // MARK: Session

    static func lockScreen() {
        if let f = lockScreenFn { _ = f(); return }
        if Permissions.isGranted(.accessibility) {
            KeyboardKeyPoster.tap(12, flags: [.maskControl, .maskCommand]) // ⌃⌘Q
        } else {
            background("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static func sleepDisplays() { background("/usr/bin/pmset", ["displaysleepnow"]) }

    static func startScreenSaver() {
        _ = openApp("/System/Library/CoreServices/ScreenSaverEngine.app")
    }

    static func toggleDarkMode() {
        background("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
    }

    static func notificationCenter() {
        let script = """
        tell application "System Events"
            tell process "ControlCenter"
                click menu bar item "Clock" of menu bar 1
            end tell
        end tell
        """
        DispatchQueue.global().async {
            let r = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)
            if !r.ok {
                // fn+N opens Notification Center on recent macOS.
                DispatchQueue.main.async {
                    guard let src = CGEventSource(stateID: .privateState) else { return }
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: down)
                        e?.flags = .maskSecondaryFn
                        e?.setIntegerValueField(.eventSourceUserData, value: KeyboardKeyPoster.marker)
                        e?.post(tap: .cghidEventTap)
                    }
                }
            }
        }
    }

    static func emptyClipboard() { NSPasteboard.general.clearContents() }

    static func cycleWindowsOfFrontApp() { KeyboardKeyPoster.tap(50, flags: .maskCommand) } // ⌘`

    static func showWindowSwitcher() {
        NotificationCenter.default.post(name: Notification.Name("MacMaster.showSwitcher"), object: nil)
    }

    // MARK: Launching

    @discardableResult
    static func openApp(_ path: String) -> Bool {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, _ in }
        return true
    }

    static func bundleID(ofAppAt path: String) -> String? { Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier }

    /// Launch, focus, hide or cycle depending on the app's state.
    @MainActor
    static func launchOrToggle(_ s: KeyboardAppShortcut) {
        guard !s.target.isEmpty else { return }
        let bid = s.bundleID ?? bundleID(ofAppAt: s.target)
        if let bid, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid {
            switch s.frontmost {
            case .hide: NSWorkspace.shared.frontmostApplication?.hide()
            case .cycle: cycleWindowsOfFrontApp()
            case .nothing: break
            }
            return
        }
        if let bid, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first, running.isHidden {
            running.unhide()
        }
        _ = openApp(s.target)
    }

    static func openURL(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let withScheme = t.contains("://") || t.hasPrefix("mailto:") ? t : "https://" + t
        if let u = URL(string: withScheme) { NSWorkspace.shared.open(u) }
    }

    /// Runs as the current user via a login shell; stdio discarded, not awaited.
    static func runShell(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", c]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
        }
    }

    private static func background(_ path: String, _ args: [String]) {
        DispatchQueue.global().async { _ = Shell.run(path, args, timeout: 15) }
    }

    // MARK: Dispatch

    @MainActor
    static func perform(_ s: KeyboardAppShortcut) {
        switch s.kind {
        case .app: launchOrToggle(s)
        case .folder:
            if !s.target.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: (s.target as NSString).expandingTildeInPath)) }
        case .url: openURL(s.target)
        case .shell: runShell(s.target)
        case .lockScreen: lockScreen()
        case .sleepDisplays: sleepDisplays()
        case .toggleDarkMode: toggleDarkMode()
        case .emptyClipboard: emptyClipboard()
        case .showDesktop: showDesktop()
        case .missionControl: missionControl()
        }
    }

    @MainActor
    static func perform(_ a: KeyboardCornerAction, appPath: String) {
        switch a {
        case .none: break
        case .missionControl: missionControl()
        case .appExpose: appExpose()
        case .showDesktop: showDesktop()
        case .launchpad: launchpad()
        case .lockScreen: lockScreen()
        case .sleepDisplays: sleepDisplays()
        case .screenSaver: startScreenSaver()
        case .notificationCenter: notificationCenter()
        case .openApp: _ = openApp(appPath)
        case .windowSwitcher: showWindowSwitcher()
        }
    }
}
