import Foundation
import CoreFoundation

/// Pointer acceleration / speed for external mice.
///
/// Uses two mechanisms, resolved with `dlsym` so a missing private symbol never breaks the link:
///  1. IOKit `IOHIDSetAccelerationWithKey` on the HID system connection (public-but-deprecated).
///  2. `IOHIDEventSystemClientSetProperty` (private) with the same key.
/// The value is the `com.apple.mouse.scaling` scale (default ~0.6875); `-1` means "no acceleration".
/// The change is live-only (not persisted by the system) and is undone by `reset()` / when the engine stops.
@MainActor
enum MousePointerControl {
    private static let key = "HIDMouseAcceleration"
    private static var applied = false
    private static var lastValue: Double?

    private typealias OpenFn = @convention(c) () -> UInt32
    private typealias CloseFn = @convention(c) (UInt32) -> Int32
    private typealias SetAccFn = @convention(c) (UInt32, CFString, Double) -> Int32
    private typealias ClientCreateFn = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> UnsafeMutableRawPointer?
    private typealias ClientSetFn = @convention(c) (UnsafeMutableRawPointer, CFString, CFTypeRef) -> UInt8

    private static let ioKit: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let h = ioKit, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    /// The user's own scaling value, to restore on reset.
    static var systemDefault: Double {
        if let v = CFPreferencesCopyAppValue("com.apple.mouse.scaling" as CFString, kCFPreferencesAnyApplication) as? Double,
           v >= 0 { return v }
        return 0.6875
    }

    /// Apply per config. Returns a short status message for the UI.
    @discardableResult
    static func apply(_ cfg: MouseConfig) -> String {
        let wanted: Double?
        if cfg.disableAcceleration { wanted = -1 }
        else if cfg.customPointerSpeed { wanted = cfg.pointerSpeed }
        else { wanted = nil }

        guard let value = wanted else {
            if applied { return reset() }
            return "System default"
        }
        if applied, lastValue == value { return "Applied" }
        let ok = set(value)
        if ok { applied = true; lastValue = value }
        return ok ? "Applied" : "Not supported on this system"
    }

    @discardableResult
    static func reset() -> String {
        guard applied else { return "System default" }
        _ = set(systemDefault)
        applied = false
        lastValue = nil
        return "System default"
    }

    private static func set(_ value: Double) -> Bool {
        var ok = false
        if let open = sym("NXOpenEventStatus", as: OpenFn.self),
           let close = sym("NXCloseEventStatus", as: CloseFn.self),
           let setAcc = sym("IOHIDSetAccelerationWithKey", as: SetAccFn.self) {
            let h = open()
            if h != 0 {
                ok = setAcc(h, key as CFString, value) == 0
                _ = close(h)
            }
        }
        if let create = sym("IOHIDEventSystemClientCreateWithType", as: ClientCreateFn.self),
           let setProp = sym("IOHIDEventSystemClientSetProperty", as: ClientSetFn.self),
           let client = create(kCFAllocatorDefault, 0, nil) {
            let fixed = NSNumber(value: Int(value * 65536))
            if setProp(client, key as CFString, fixed) != 0 { ok = true }
            // `client` is a CF object we own (Create rule).
            Unmanaged<AnyObject>.fromOpaque(client).release()
        }
        return ok
    }
}
