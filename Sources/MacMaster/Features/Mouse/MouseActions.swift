import AppKit
import CoreGraphics

/// Magic value stamped on every synthetic event we post so our own tap ignores them.
let mouseSyntheticMagic: Int64 = 0x4D4D_4D4F_5553_4531

/// Executes `MouseAction`s. Safe to call from any thread.
enum MouseActionRunner {
    private static let source = CGEventSource(stateID: .privateState)

    static func run(_ action: MouseAction, button: Int) {
        switch action.kind {
        case .none:
            break
        case .middleClick:
            replayClick(button: 2)
        case .missionControl:
            missionControl()
        case .appExpose:
            if !coreDock("com.apple.expose.front.awake") { key(125, flags: .maskControl) }
        case .showDesktop:
            if !coreDock("com.apple.showdesktop.awake") { key(103) }
        case .launchpad:
            launchpad()
        case .back:
            key(33, flags: .maskCommand)
        case .forward:
            key(30, flags: .maskCommand)
        case .spaceLeft:
            key(123, flags: .maskControl)
        case .spaceRight:
            key(124, flags: .maskControl)
        case .lookUp:
            key(2, flags: [.maskControl, .maskCommand])
        case .smartZoom:
            smartZoom()
        case .copy:
            key(8, flags: .maskCommand)
        case .paste:
            key(9, flags: .maskCommand)
        case .shortcut:
            if let s = action.shortcut {
                key(CGKeyCode(s.keyCode), flags: CGEventFlags(rawValue: s.flags))
            }
        case .openApp:
            let path = action.target
            guard !path.isEmpty else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
        case .openURL:
            guard let url = URL(string: action.target), url.scheme != nil else { return }
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

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        var f = flags
        if (123...126).contains(Int(code)) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }
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
