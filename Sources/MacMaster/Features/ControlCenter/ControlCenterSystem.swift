import Foundation
import AppKit
import CoreWLAN
import CoreBluetooth
import ObjectiveC

/// Point-in-time system toggle state. Built off the main thread.
struct ControlCenterSnapshot: Sendable {
    var wifi: Bool?          // nil = no Wi-Fi interface
    var bluetooth: Bool?     // nil = unavailable or not yet authorized
    var darkMode = false
    var nightShift: Bool?    // nil = unavailable on this Mac / macOS
}

/// Blocking system calls for the Control Center tiles. Never call from the main thread.
/// Private frameworks are loaded lazily and every symbol is optional, so a missing symbol only hides a feature.
enum ControlCenterSystem {
    static let queue = DispatchQueue(label: "macmaster.controlcenter.system", qos: .userInitiated)

    // MARK: dlsym plumbing

    private static func load<T>(_ lib: String, _ name: String) -> T? {
        guard let h = dlopen(lib, RTLD_LAZY), let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private typealias BTGetFn = @convention(c) () -> Int32
    private typealias BTSetFn = @convention(c) (Int32) -> Void
    private typealias LockFn = @convention(c) () -> Int32

    private static let btGet: BTGetFn? =
        load("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", "IOBluetoothPreferenceGetControllerPowerState")
    private static let btSet: BTSetFn? =
        load("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", "IOBluetoothPreferenceSetControllerPowerState")
    private static let lockFn: LockFn? =
        load("/System/Library/PrivateFrameworks/login.framework/login", "SACLockScreenImmediate")

    // MARK: Snapshot

    static func snapshot() -> ControlCenterSnapshot {
        ControlCenterSnapshot(
            wifi: CWWiFiClient.shared().interface()?.powerOn(),
            bluetooth: bluetoothAuthorized ? bluetoothPower() : nil,
            darkMode: isDarkMode(),
            nightShift: nightShiftEnabled())
    }

    // MARK: Wi-Fi

    static func setWifi(_ on: Bool) -> String? {
        guard let i = CWWiFiClient.shared().interface() else { return "No Wi-Fi interface found." }
        do { try i.setPower(on); return nil } catch { return error.localizedDescription }
    }

    // MARK: Bluetooth

    static var bluetoothAvailable: Bool { btGet != nil && btSet != nil }
    static var bluetoothAuthorized: Bool { CBManager.authorization == .allowedAlways }
    static var bluetoothNeedsPermission: Bool { bluetoothAvailable && CBManager.authorization == .notDetermined }

    static func bluetoothPower() -> Bool? {
        guard let get = btGet, btSet != nil else { return nil }
        return get() != 0
    }

    /// Returns nil on success, otherwise a message (caller can fall back to opening Bluetooth settings).
    static func setBluetooth(_ on: Bool) -> String? {
        guard let set = btSet else { return "Bluetooth control isn't available on this macOS version." }
        set(on ? 1 : 0)
        return nil
    }

    // MARK: Appearance

    static func isDarkMode() -> Bool {
        let v = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? String)?.lowercased() == "dark"
    }

    /// Flips dark mode through System Events (needs Automation permission). Returns an error message or nil.
    static func toggleDarkMode() -> String? {
        let src = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        var error: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            return "Allow MacMaster to control System Events in Privacy & Security > Automation."
        }
        return (error[NSAppleScript.errorMessage] as? String) ?? "Couldn't change appearance."
    }

    // MARK: Night Shift (CoreBrightness, private)

    private typealias StatusFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabledFn = @convention(c) (AnyObject, Selector, Bool) -> Bool

    nonisolated(unsafe) private static let blueLight: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static func imp<T>(_ obj: NSObject, _ selector: String, as: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel), let m = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        return (sel, unsafeBitCast(m, to: T.self))
    }

    /// nil when CoreBrightness or the selector is unavailable.
    static func nightShiftEnabled() -> Bool? {
        guard let c = blueLight, let (sel, fn) = imp(c, "getBlueLightStatus:", as: StatusFn.self) else { return nil }
        // Status struct: char active, enabled, sunSchedulePermitted; int mode; schedule; uint64 flags; char available.
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        guard fn(c, sel, buf) else { return nil }
        return buf.load(fromByteOffset: 1, as: UInt8.self) != 0
    }

    static func setNightShift(_ on: Bool) -> String? {
        guard let c = blueLight, let (sel, fn) = imp(c, "setEnabled:", as: SetEnabledFn.self) else {
            return "Night Shift isn't available on this Mac."
        }
        return fn(c, sel, on) ? nil : "macOS refused to change Night Shift."
    }

    // MARK: Low Power Mode

    /// Prompts with the system's own administrator dialog (we never see the password).
    static func setLowPower(_ on: Bool) -> String? {
        let r = Shell.runAsAdmin("/usr/bin/pmset", ["-a", "lowpowermode", on ? "1" : "0"],
                                 prompt: "MacMaster wants to turn Low Power Mode \(on ? "on" : "off").")
        if r.ok { return nil }
        // -128 = user cancelled the password dialog.
        return r.status == -128 || r.stderr.localizedCaseInsensitiveContains("cancel") ? nil : "Couldn't change Low Power Mode."
    }

    // MARK: Lock screen

    static func lockScreen() {
        if let lock = lockFn { _ = lock(); return }
        let cg = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.isExecutableFile(atPath: cg) { Shell.run(cg, ["-suspend"], timeout: 5) }
    }

    // MARK: Focus

    /// Runs the user's Shortcut by name. Returns an error message or nil.
    static func runShortcut(_ name: String) -> String? {
        let r = Shell.run("/usr/bin/shortcuts", ["run", name], timeout: 20)
        return r.ok ? nil : "Shortcut \"\(name)\" failed. Check the name in the Shortcuts app."
    }

    // MARK: Opening things

    static func openSettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// Asks for Bluetooth access without blocking, then reports the answer.
@MainActor
final class ControlCenterBluetoothAsker: NSObject, CBCentralManagerDelegate {
    static let shared = ControlCenterBluetoothAsker()
    private var manager: CBCentralManager?
    var onAnswer: (() -> Void)?

    func request() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onAnswer?() } }
    }
}
