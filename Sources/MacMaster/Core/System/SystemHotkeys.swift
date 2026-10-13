import AppKit
import CoreGraphics

/// Triggers macOS "symbolic hotkeys" (the shortcuts in System Settings › Keyboard › Shortcuts) by posting
/// whatever key combo the user has bound to them. If one is disabled or unbound, it's bound to an unused
/// key code for a moment and restored afterwards, so it works regardless of the user's settings.
/// Same approach as Mac Mouse Fix. All private symbols are resolved at runtime with fallbacks.
enum SystemHotkeys {
    enum ID: Int32 {
        case missionControl = 32
        case appWindows = 33
        case showDesktop = 36
        case spotlight = 64
        case spaceLeft = 79
        case spaceRight = 81
        case launchpad = 160
        case notificationCenter = 163
    }

    /// Stamped on posted events so MacMaster's own taps ignore them.
    static let marker: Int64 = 0x4D4D_484B_4559 // "MMHKEY"

    private typealias GetValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias SetValueFn = @convention(c) (Int32, UInt16, UInt16, UInt64) -> Int32

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        for lib in ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"] {
            if let h = dlopen(lib, RTLD_LAZY), let s = dlsym(h, name) { return unsafeBitCast(s, to: T.self) }
        }
        return nil
    }

    private static let getValue = sym("CGSGetSymbolicHotKeyValue", GetValueFn.self)
    private static let isEnabled = sym("CGSIsSymbolicHotKeyEnabled", IsEnabledFn.self)
    private static let setEnabled = sym("CGSSetSymbolicHotKeyEnabled", SetEnabledFn.self)
    private static let setValue = sym("CGSSetSymbolicHotKeyValue", SetValueFn.self)

    private static let lock = NSLock()
    private static var restoreWork: [Int32: DispatchWorkItem] = [:]

    /// Returns false when the private API is missing (caller should fall back).
    @discardableResult
    static func post(_ id: ID) -> Bool {
        guard let getValue, let isEnabled, let setEnabled, let setValue else { return false }
        let hk = id.rawValue
        var equiv: UInt16 = 0, code: UInt16 = 0
        var flags: UInt64 = 0
        let err = getValue(hk, &equiv, &code, &flags)
        let wasEnabled = isEnabled(hk)
        let unbound = err != 0 || code == UInt16.max || code >= 400

        lock.lock()
        let pendingRestore = restoreWork.removeValue(forKey: hk)
        lock.unlock()
        pendingRestore?.cancel()

        if !wasEnabled { _ = setEnabled(hk, true) }
        if unbound {
            code = UInt16(400 + hk)
            flags = 0xA0_0000 // fn + numpad bits: never collides with a real key
            _ = setValue(hk, 0xFFFF, code, flags)
        }

        let current = CGEventSource.flagsState(.combinedSessionState)
        let src = CGEventSource(stateID: .privateState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.flags = CGEventFlags(rawValue: flags)
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.flags = current
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            up.post(tap: .cgSessionEventTap)
        }

        if !wasEnabled || unbound {
            // Put the user's settings back once the system has handled the key.
            let work = DispatchWorkItem {
                if unbound { _ = setValue(hk, equiv, UInt16.max, 0) }
                if !wasEnabled { _ = setEnabled(hk, false) }
                lock.lock(); restoreWork[hk] = nil; lock.unlock()
            }
            lock.lock(); restoreWork[hk] = work; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        return true
    }
}

/// Hardware media keys (play/pause, volume…), posted as `NSSystemDefined` events like a real keyboard.
enum MediaKeys {
    enum Key: Int { case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18 }

    static func tap(_ key: Key) {
        let post = {
            for down in [true, false] {
                let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
                let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
                e?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
