import Foundation
import AppKit
import IOKit
import ObjectiveC
import Observation

// MARK: - Keyboard backlight (CoreBrightness, private)

/// Built-in keyboard backlight. Every selector is optional: Macs without a backlight, or a macOS that
/// renames the class, simply report nil and the tile hides itself.
enum ControlCenterKeyboardBrightness {
    private typealias IDsFn = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    nonisolated(unsafe) private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static func imp<T>(_ selector: String, as: T.Type) -> (NSObject, Selector, T)? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString(selector)
        guard c.responds(to: sel), let m = class_getMethodImplementation(type(of: c), sel) else { return nil }
        return (c, sel, unsafeBitCast(m, to: T.self))
    }

    private static func keyboardID() -> UInt64? {
        guard let (c, sel, fn) = imp("copyKeyboardBacklightIDs", as: IDsFn.self),
              let ids = fn(c, sel) as? [NSNumber], let first = ids.first else { return nil }
        return first.uint64Value
    }

    /// nil = no controllable keyboard backlight.
    static func read() -> Float? {
        guard let id = keyboardID(), let (c, sel, fn) = imp("brightnessForKeyboard:", as: GetFn.self),
              imp("setBrightness:forKeyboard:", as: SetFn.self) != nil else { return nil }
        let v = fn(c, sel, id)
        return v.isFinite ? max(0, min(1, v)) : nil
    }

    static func write(_ value: Float) {
        guard let id = keyboardID(), let (c, sel, fn) = imp("setBrightness:forKeyboard:", as: SetFn.self) else { return }
        _ = fn(c, sel, max(0, min(1, value)), id)
    }
}

// MARK: - Bluetooth device batteries

struct ControlCenterBTDevice: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let kind: String
    /// Label ("Left", "Case"…) and percent. Empty label for a single battery.
    let batteries: [Battery]

    struct Battery: Equatable, Sendable { let label: String; let percent: Int }

    var symbol: String {
        let k = kind.lowercased()
        if k.contains("headphone") || k.contains("headset") { return SymbolKit.firstAvailable(["headphones", "earbuds"]) }
        if k.contains("keyboard") { return "keyboard" }
        if k.contains("mouse") { return SymbolKit.firstAvailable(["computermouse.fill", "computermouse"]) }
        if k.contains("trackpad") { return SymbolKit.firstAvailable(["rectangle.and.hand.point.up.left.fill", "hand.point.up.left"]) }
        if k.contains("speaker") { return SymbolKit.firstAvailable(["hifispeaker.fill", "speaker.wave.2.fill"]) }
        if k.contains("phone") { return "iphone" }
        if k.contains("game") || k.contains("controller") { return SymbolKit.firstAvailable(["gamecontroller.fill", "gamecontroller"]) }
        return SymbolKit.firstAvailable(["dot.radiowaves.left.and.right", "wave.3.right"])
    }

    var lowest: Int? { batteries.map(\.percent).min() }
}

/// Connected Bluetooth devices with battery levels. `system_profiler` is slow (about a second),
/// so it runs off the main thread and the result is cached for a while.
@Observable
@MainActor
final class ControlCenterBluetoothDevices {
    static let shared = ControlCenterBluetoothDevices()

    private(set) var devices: [ControlCenterBTDevice] = []
    private(set) var loaded = false
    @ObservationIgnored private var fetchedAt = Date.distantPast
    @ObservationIgnored private var fetching = false
    private init() {}

    func refresh(force: Bool = false) {
        guard !fetching, force || Date().timeIntervalSince(fetchedAt) > 45 else { return }
        fetching = true
        Task.detached(priority: .utility) {
            let list = Self.scan()
            await MainActor.run {
                let m = ControlCenterBluetoothDevices.shared
                m.devices = list; m.loaded = true; m.fetching = false; m.fetchedAt = Date()
            }
        }
    }

    nonisolated private static func scan() -> [ControlCenterBTDevice] {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15)
        var found: [ControlCenterBTDevice] = []
        if r.ok, let data = r.stdout.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
           let connected = section["device_connected"] as? [[String: Any]] {
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    var batteries: [ControlCenterBTDevice.Battery] = []
                    for (key, label) in [("device_batteryLevelMain", ""), ("device_batteryLevel", ""),
                                         ("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
                                         ("device_batteryLevelCase", "Case")] {
                        if let s = props[key] as? String, let p = Int(s.filter(\.isNumber)) {
                            batteries.append(.init(label: label, percent: p))
                        }
                    }
                    found.append(ControlCenterBTDevice(name: name, kind: props["device_minorType"] as? String ?? "", batteries: batteries))
                }
            }
        }
        // HID devices (Magic Keyboard / Mouse / Trackpad) report BatteryPercent in the registry.
        let hid = registryBatteries()
        found = found.map { d in
            guard d.batteries.isEmpty, let p = hid[d.name] else { return d }
            return ControlCenterBTDevice(name: d.name, kind: d.kind, batteries: [.init(label: "", percent: p)])
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Product name -> BatteryPercent for HID devices.
    nonisolated private static func registryBatteries() -> [String: Int] {
        var out: [String: Int] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let p = IORegistryEntryCreateCFProperty(svc, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               let n = IORegistryEntryCreateCFProperty(svc, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                out[n] = p
            }
        }
        return out
    }
}

// MARK: - Now Playing (MediaRemote, private)

struct ControlCenterNowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var playing: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.playing == b.playing
            && (a.artwork == nil) == (b.artwork == nil)
    }
}

/// System Now Playing through MediaRemote. macOS 15.4+ withholds this from apps without an Apple entitlement,
/// in which case `info` stays nil and the tile hides itself. Observers exist only while the popover is open.
@Observable
@MainActor
final class ControlCenterNowPlaying {
    static let shared = ControlCenterNowPlaying()

    private(set) var info: ControlCenterNowPlayingInfo?

    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias CommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    private static let handle = dlopen(path, RTLD_LAZY)
    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
    private static let infoFn = sym("MRMediaRemoteGetNowPlayingInfo", as: InfoFn.self)
    private static let playingFn = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: PlayingFn.self)
    private static let commandFn = sym("MRMediaRemoteSendCommand", as: CommandFn.self)
    private static let registerFn = sym("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
    private static let unregisterFn = sym("MRMediaRemoteUnregisterForNowPlayingNotifications", as: (@convention(c) () -> Void).self)

    var available: Bool { Self.infoFn != nil }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private init() {}

    func startListening() {
        guard observers.isEmpty, Self.infoFn != nil else { return }
        Self.registerFn?(.main)
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ControlCenterNowPlaying.shared.refresh() }
            })
        }
        refresh()
    }

    func stopListening() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        Self.unregisterFn?()
    }

    func refresh() {
        guard let infoFn = Self.infoFn else { return }
        infoFn(.main) { dict in
            // Copy out of the CFDictionary before hopping to the main actor.
            let d = dict as? [String: Any]
            let title = d?["kMRMediaRemoteNowPlayingInfoTitle"] as? String
            let artist = d?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let album = d?["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            let art = (d?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap { NSImage(data: $0) }
            let rate = (d?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
            MainActor.assumeIsolated {
                let m = ControlCenterNowPlaying.shared
                guard let title, !title.isEmpty else { m.info = nil; return }
                m.info = ControlCenterNowPlayingInfo(title: title, artist: artist, album: album, artwork: art, playing: rate > 0)
            }
        }
    }

    enum Command: UInt32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    func send(_ c: Command) {
        guard let fn = Self.commandFn else { return }
        _ = fn(c.rawValue, nil)
        if c == .toggle, var i = info { i.playing.toggle(); info = i }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { self.refresh() } }
    }
}
