import AppKit
import CoreGraphics

/// Magic value stamped on every synthetic event we post so our own tap ignores them.
let mouseSyntheticMagic: Int64 = 0x4D4D_4D4F_5553_4531

/// Executes `MouseAction`s. Safe to call from any thread.
enum MouseActionRunner {
    private static let source = CGEventSource(stateID: .privateState)

    static func run(_ action: MouseAction, button: Int) {
        let cmd = CGEventFlags.maskCommand, ctrl = CGEventFlags.maskControl, shift = CGEventFlags.maskShift
        switch action.kind {
        case .none:
            break
        case .middleClick:
            replayClick(button: 2)
        case .rightClick:
            rightClick()
        case .missionControl:
            if !SystemHotkeys.post(.missionControl) { missionControl() }
        case .appExpose:
            if !SystemHotkeys.post(.appWindows), !coreDock("com.apple.expose.front.awake") { key(125, flags: ctrl) }
        case .showDesktop:
            if !SystemHotkeys.post(.showDesktop), !coreDock("com.apple.showdesktop.awake") { key(103) }
        case .launchpad:
            launchpad()
        case .notificationCenter:
            if !SystemHotkeys.post(.notificationCenter) { DispatchQueue.main.async { KeyboardSystemActions.notificationCenter() } }
        case .spotlight:
            if !SystemHotkeys.post(.spotlight) { key(49, flags: cmd) }
        case .screenshot:
            openApp("/System/Applications/Utilities/Screenshot.app")
        case .lockScreen:
            DispatchQueue.main.async { KeyboardSystemActions.lockScreen() }
        case .back:
            key(33, flags: cmd)
        case .forward:
            key(30, flags: cmd)
        case .spaceLeft:
            if !SystemHotkeys.post(.spaceLeft) { key(123, flags: ctrl) }
        case .spaceRight:
            if !SystemHotkeys.post(.spaceRight) { key(124, flags: ctrl) }
        case .lookUp:
            key(2, flags: [ctrl, cmd])
        case .smartZoom:
            smartZoom()
        case .pageUp:
            key(116)
        case .pageDown:
            key(121)
        case .scrollTop:
            key(126, flags: cmd)
        case .scrollBottom:
            key(125, flags: cmd)
        case .nextTab:
            key(48, flags: ctrl)
        case .prevTab:
            key(48, flags: [ctrl, shift])
        case .newTab:
            key(17, flags: cmd)
        case .closeTab:
            key(13, flags: cmd)
        case .reopenTab:
            key(17, flags: [cmd, shift])
        case .minimize:
            key(46, flags: cmd)
        case .fullScreen:
            key(3, flags: [ctrl, cmd])
        case .hideApp:
            key(4, flags: cmd)
        case .copy:
            key(8, flags: cmd)
        case .paste:
            key(9, flags: cmd)
        case .cut:
            key(7, flags: cmd)
        case .undo:
            key(6, flags: cmd)
        case .redo:
            key(6, flags: [cmd, shift])
        case .playPause: MediaKeys.tap(.playPause)
        case .nextTrack: MediaKeys.tap(.next)
        case .prevTrack: MediaKeys.tap(.previous)
        case .volumeUp: MediaKeys.tap(.volumeUp)
        case .volumeDown: MediaKeys.tap(.volumeDown)
        case .mute: MediaKeys.tap(.mute)
        case .shortcut:
            if let s = action.shortcut {
                key(CGKeyCode(s.keyCode), flags: CGEventFlags(rawValue: s.flags))
            }
        case .openApp:
            let path = action.target
            guard !path.isEmpty else { return }
            openApp(path)
        case .openURL:
            let t = action.target.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = t.contains("://") || t.hasPrefix("mailto:") ? t : "https://" + t
            guard !t.isEmpty, let url = URL(string: raw) else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Synthetic input

    static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Re-post a plain click of `button` (used when we swallowed the original press).
    static func replayClick(button: Int) {
        let loc = currentLocation()
        for down in [true, false] {
            guard let e = CGEvent(mouseEventSource: source,
                                  mouseType: down ? .otherMouseDown : .otherMouseUp,
                                  mouseCursorPosition: loc, mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
            e.post(tap: .cgSessionEventTap)
        }
    }

    static func rightClick() {
        let loc = currentLocation()
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: loc, mouseButton: .right) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
            e.post(tap: .cgSessionEventTap)
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        var f = flags
        if (123...126).contains(Int(code)) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }
        if [115, 116, 119, 121].contains(Int(code)) { f.insert(.maskSecondaryFn) } // Home / PgUp / End / PgDn
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = f
            e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: System features

    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private static func openApp(_ path: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func missionControl() {
        let path = "/System/Applications/Mission Control.app"
        if exists(path) { openApp(path); return }
        if !coreDock("com.apple.expose.awake") { key(160) }
    }

    private static func launchpad() {
        // macOS 26 replaced Launchpad with "Apps".
        if exists("/System/Applications/Launchpad.app") { openApp("/System/Applications/Launchpad.app"); return }
        if exists("/System/Applications/Apps.app") { openApp("/System/Applications/Apps.app"); return }
        if !coreDock("com.apple.launchpad.toggle") { key(160) }
    }

    /// Best-effort: smart-magnify is a private gesture event type (32). Falls back to nothing if refused.
    private static func smartZoom() {
        guard let e = CGEvent(source: source) else { return }
        e.type = CGEventType(rawValue: 32) ?? .null
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
        e.post(tap: .cgSessionEventTap)
    }

    /// `CoreDockSendNotification` is a private-but-stable HIServices symbol; resolved at runtime so a
    /// missing symbol can never break linking.
    private typealias CoreDockFn = @convention(c) (CFString, Int32) -> Void
    private static let coreDockFn: CoreDockFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockFn.self)
    }()

    @discardableResult
    private static func coreDock(_ name: String) -> Bool {
        guard let fn = coreDockFn else { return false }
        fn(name as CFString, 0)
        return true
    }
}
