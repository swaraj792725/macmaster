import AppKit
import ApplicationServices
import os

/// Click-only event tap (left and right button down/up; no scroll, move or drag events) behind two features:
/// - click debounce: drops a button press that follows the previous release by less than a few milliseconds,
///   plus the release that belongs to it;
/// - green button: turns a click on the green full-screen button into "fill the screen" (and back).
/// The callback does O(1) work. Only a click inside the top-left corner of a window ever reaches Accessibility,
/// and that call has a very short timeout; the window move itself runs on a background queue.
final class WindowExtrasClickTap: @unchecked Sendable {
    struct Config: Sendable {
        var debounce: Bool
        var debounceRight: Bool
        var thresholdNs: UInt64
        var green: Bool
    }

    /// Fired for ⌘W (only when the tap was created with `keys`). Must not block.
    var onCloseShortcut: (@Sendable () -> Void)?

    static func eventTypes(mouse: Bool, keys: Bool) -> [CGEventType] {
        (mouse ? [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] : []) + (keys ? [.keyDown] : [])
    }

    let config: OSAllocatedUnfairLock<Config>
    private let blocked = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Chattering clicks dropped since this tap started.
    var blockedThisRun: Int { blocked.withLock { $0 } }

    // Tap-thread-only state. Index 0 = left, 1 = right.
    private var lastUpNs: (UInt64, UInt64) = (0, 0)
    private var swallowedDown: (Bool, Bool) = (false, false)
    private var greenSwallowed = false

    init(config: Config) {
        self.config = OSAllocatedUnfairLock(initialState: config)
    }

    /// Called after the system re-enables a disabled tap: forget half-seen clicks.
    func reset() {
        // Runs on the tap thread (from the disabled-callback), same as `handle`.
        lastUpNs = (0, 0)
        swallowedDown = (false, false)
        greenSwallowed = false
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == mouseSyntheticMagic { return pass }
        let cfg = config.withLock { $0 }
        let now = DispatchTime.now().uptimeNanoseconds

        switch type {
        case .leftMouseDown:
            swallowedDown.0 = false
            greenSwallowed = false
            if cfg.debounce, lastUpNs.0 != 0, now &- lastUpNs.0 < cfg.thresholdNs {
                swallowedDown.0 = true
                blocked.withLock { $0 += 1 }
                return nil
            }
            if cfg.green, !event.flags.contains(.maskAlternate),
               let win = WindowExtrasAX.fullScreenButtonWindow(at: event.location) {
                greenSwallowed = true
                WindowExtrasMaximizer.shared.toggle(win)
                return nil
            }
            return pass
        case .leftMouseUp:
            if swallowedDown.0 { swallowedDown.0 = false; return nil }
            if greenSwallowed { greenSwallowed = false; return nil }
            lastUpNs.0 = now
            return pass
        case .rightMouseDown:
            swallowedDown.1 = false
            if cfg.debounce, cfg.debounceRight, lastUpNs.1 != 0, now &- lastUpNs.1 < cfg.thresholdNs {
                swallowedDown.1 = true
                blocked.withLock { $0 += 1 }
                return nil
            }
            return pass
        case .rightMouseUp:
            if swallowedDown.1 { swallowedDown.1 = false; return nil }
            lastUpNs.1 = now
            return pass
        case .keyDown:
            // Only ⌘W is looked at; nothing about other keys is read or stored.
            if event.getIntegerValueField(.keyboardEventKeycode) == 13,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskCommand {
                onCloseShortcut?()
            }
            return pass
        default:
            return pass
        }
    }
}

// MARK: - AX helpers

enum WindowExtrasAX {
    /// Cheap check: is `p` (top-left global coordinates) in the top-left corner of the front window under it,
    /// where the traffic lights are? One window-list snapshot, no Accessibility.
    static func inTrafficLightCorner(_ p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(p) else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                  owner != SelfAX.pid else { return false }
            return p.x - r.minX <= 130 && p.y - r.minY <= 54
        }
        return false
    }

    /// The window whose green full-screen button is at `p`, if any. Blocking, but bounded: nothing outside the
    /// window corner reaches Accessibility, and the call itself times out after 60 ms.
    static func fullScreenButtonWindow(at p: CGPoint) -> TilingWindow? {
        guard inTrafficLightCorner(p), let el = SelfAX.element(at: p, timeout: 0.06) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.06)
        guard TilingAX.string(el, "AXSubrole") == "AXFullScreenButton" else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid != SelfAX.pid,
              let win = TilingAX.enclosingWindow(of: el),
              TilingAX.bool(win, "AXFullScreen") != true else { return nil }
        return TilingWindow(element: win, pid: pid)
    }
}

// MARK: - Maximize / restore

/// Fills the visible frame of the window's screen; a second click puts the window back where it was.
final class WindowExtrasMaximizer: @unchecked Sendable {
    static let shared = WindowExtrasMaximizer()

    private let queue = DispatchQueue(label: "MacMaster.WindowExtras.maximize", qos: .userInitiated)
    private let lock = NSLock()
    private var previous: [Int: CGRect] = [:]

    func toggle(_ win: TilingWindow) {
        // Screen geometry comes from AppKit, so read it on main; the Accessibility work runs on the queue.
        DispatchQueue.main.async { [self] in
            let screens = MainActor.assumeIsolated { TilingScreens.snapshot() }
            queue.async { [self] in apply(win, screens: screens) }
        }
    }

    private func apply(_ win: TilingWindow, screens: [TilingScreenInfo]) {
        guard win.pid != SelfAX.pid else { return }
        AXUIElementSetMessagingTimeout(win.element, 0.4)
        guard let cur = TilingAX.frame(win.element), let screen = TilingScreens.screen(for: cur, in: screens) else { return }
        let target = screen.visible
        let key = win.key
        if TilingGeometry.approx(cur, target, tol: 12) {
            lock.lock(); let prev = previous.removeValue(forKey: key); lock.unlock()
            let back = prev ?? target.insetBy(dx: target.width * 0.15, dy: target.height * 0.15)
            _ = TilingAX.setFrame(win, back)
        } else {
            lock.lock()
            if previous.count > 100 { previous.removeAll() }
            previous[key] = cur
            lock.unlock()
            _ = TilingAX.setFrame(win, target)
        }
        TilingAX.raise(win)
    }
}
