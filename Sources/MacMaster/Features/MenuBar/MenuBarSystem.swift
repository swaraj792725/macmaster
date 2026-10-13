import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import CoreWLAN
import CoreBluetooth
import CoreGraphics

/// Point-in-time reading of system toggles. Built off the main thread.
struct MenuBarSnapshot: Sendable {
    var darkMode = false
    var wifi: Bool?            // nil = no Wi-Fi interface
    var bluetooth: Bool?       // nil = unavailable
    var hideDesktop = false
    var hiddenFiles = false
    var lowPower = false
    var muted: Bool?           // nil = device has no mute control
    var brightness: Float?     // nil = not controllable (external display etc.)
    var volume: Float?         // nil = no volume control
}

/// Blocking system calls. Never call from the main thread.
enum MenuBarSystem {
    // MARK: dlsym plumbing

    private static func load<T>(_ lib: String, _ name: String) -> T? {
        guard let h = dlopen(lib, RTLD_LAZY), let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32
    private typealias BTGetFn = @convention(c) () -> Int32
    private typealias BTSetFn = @convention(c) (Int32) -> Void
    private typealias LockFn = @convention(c) () -> Int32

    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let ioBluetooth = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
    private static let loginFramework = "/System/Library/PrivateFrameworks/login.framework/login"

    private static let getBrightnessFn: GetBrightnessFn? = load(displayServices, "DisplayServicesGetBrightness")
    private static let setBrightnessFn: SetBrightnessFn? = load(displayServices, "DisplayServicesSetBrightness")
    private static let btGetFn: BTGetFn? = load(ioBluetooth, "IOBluetoothPreferenceGetControllerPowerState")
    private static let btSetFn: BTSetFn? = load(ioBluetooth, "IOBluetoothPreferenceSetControllerPowerState")
    private static let lockFn: LockFn? = load(loginFramework, "SACLockScreenImmediate")

    // MARK: Snapshot

    static func snapshot() -> MenuBarSnapshot {
        var s = MenuBarSnapshot()
        s.darkMode = isDarkMode()
        s.wifi = wifiPower()
        // Querying Bluetooth before access is granted blocks on the system prompt, so only read it once allowed.
        s.bluetooth = bluetoothAuthorized ? bluetoothPower() : nil
        s.hideDesktop = !toolsReadBool("CreateDesktop", domain: "com.apple.finder", default: true)
        s.hiddenFiles = toolsReadBool("AppleShowAllFiles", domain: "com.apple.finder")
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.muted = isMuted()
        s.brightness = brightness()
        s.volume = volume()
        return s
    }

    // MARK: Appearance

    static func isDarkMode() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let v = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? String)?.lowercased() == "dark"
    }

    private static let scriptQueue = DispatchQueue(label: "macmaster.menubar.applescript")

    /// Flips dark mode through System Events (needs Automation permission). Returns an error message or nil.
    static func toggleDarkMode() -> String? {
        scriptQueue.sync {
            var error: NSDictionary?
            let src = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
            guard let error else { return nil }
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                return "Allow MacMaster to control System Events in System Settings › Privacy & Security › Automation."
            }
            return (error[NSAppleScript.errorMessage] as? String) ?? "Could not change appearance"
        }
    }

    // MARK: Wi-Fi

    static func wifiPower() -> Bool? { CWWiFiClient.shared().interface()?.powerOn() }

    static func setWifi(_ on: Bool) -> String? {
        guard let i = CWWiFiClient.shared().interface() else { return "No Wi-Fi interface found" }
        do { try i.setPower(on); return nil } catch { return error.localizedDescription }
    }

    // MARK: Bluetooth

    static var bluetoothAvailable: Bool { btGetFn != nil && btSetFn != nil }
    static var bluetoothAuthorized: Bool { CBManager.authorization == .allowedAlways }
    static var bluetoothNeedsPermission: Bool { bluetoothAvailable && CBManager.authorization == .notDetermined }

    nonisolated(unsafe) private static var permissionManager: CBCentralManager?

    /// Shows the system Bluetooth prompt without blocking (the manager is kept alive until answered).
    static func requestBluetoothPermission() {
        DispatchQueue.main.async {
            if permissionManager == nil { permissionManager = CBCentralManager(delegate: nil, queue: nil) }
        }
    }

    static func bluetoothPower() -> Bool? {
        guard let get = btGetFn, btSetFn != nil else { return nil }
        return get() != 0
    }

    static func setBluetooth(_ on: Bool) -> String? {
        guard let set = btSetFn else { return "Bluetooth control is unavailable on this macOS version" }
        set(on ? 1 : 0)
        return nil
    }

    // MARK: Audio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return r == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    static func volume() -> Float? {
        guard let dev = defaultOutputDevice() else { return nil }
        var addr = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return min(max(v, 0), 1)
    }

    static func setVolume(_ value: Float) {
        guard let dev = defaultOutputDevice() else { return }
        var addr = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(dev, &addr) else { return }
        var v = min(max(value, 0), 1)
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if v > 0, isMuted() == true { setMuted(false) }
    }

    private static func muteElements(_ dev: AudioDeviceID) -> [UInt32] {
        var main = outputAddress(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(dev, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { el in
            var a = outputAddress(kAudioDevicePropertyMute, element: el)
            return AudioObjectHasProperty(dev, &a)
        }
    }

    static func isMuted() -> Bool? {
        guard let dev = defaultOutputDevice() else { return nil }
        guard let el = muteElements(dev).first else { return nil }
        var addr = outputAddress(kAudioDevicePropertyMute, element: el)
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr else { return nil }
        return m != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let dev = defaultOutputDevice() else { return }
        for el in muteElements(dev) {
            var addr = outputAddress(kAudioDevicePropertyMute, element: el)
            var m: UInt32 = muted ? 1 : 0
            _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    // MARK: Brightness

    private static func brightnessDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(16, &ids, &count) == .success {
            if let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) { return builtin }
        }
        return CGMainDisplayID()
    }

    static func brightness() -> Float? {
        guard let get = getBrightnessFn, setBrightnessFn != nil else { return nil }
        var v: Float = 0
        guard get(brightnessDisplay(), &v) == 0 else { return nil }
        return min(max(v, 0), 1)
    }

    static func setBrightness(_ value: Float) {
        guard let set = setBrightnessFn else { return }
        _ = set(brightnessDisplay(), min(max(value, 0), 1))
    }

    // MARK: Finder / power / screen

    static func setDesktopIconsHidden(_ hidden: Bool) -> String? {
        let w = Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        guard w.ok else { return "Could not change the setting" }
        Shell.run("/usr/bin/killall", ["Finder"])
        return nil
    }

    static func lockScreen() -> Bool {
        if let f = lockFn { _ = f(); return true }
        return Shell.run("/usr/bin/pmset", ["displaysleepnow"]).ok
    }

    static func sleepDisplays() -> Bool { Shell.run("/usr/bin/pmset", ["displaysleepnow"]).ok }

    static func startScreenSaver() -> Bool { Shell.run("/usr/bin/open", ["-a", "ScreenSaverEngine"]).ok }

    static func openScreenshotTools() -> Bool { Shell.run("/usr/bin/open", ["-a", "Screenshot"]).ok }
}
