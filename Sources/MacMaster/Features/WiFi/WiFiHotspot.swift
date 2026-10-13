import SwiftUI
import AppKit
import CoreWLAN
import ApplicationServices
import Observation

// MARK: - Device

enum WiFiHotspotKind: Sendable { case iPhone, iPad, other }

/// A phone or tablet that Instant Hotspot can see, whether or not its Personal Hotspot is on.
struct WiFiHotspotDevice: Identifiable, @unchecked Sendable {
    let id: String
    var name: String
    var model: String
    var battery: Int?          // 0…100
    var signalBars: Int?       // 0…4 cellular bars
    var network: String?       // "5G", "LTE"…
    /// The live SFRemoteHotspotDevice, needed to ask it to turn the hotspot on.
    let object: NSObject

    var kind: WiFiHotspotKind {
        if model.hasPrefix("iPad") { return .iPad }
        if model.hasPrefix("iPhone") { return .iPhone }
        return .other
    }
    var symbol: String { kind == .iPad ? "ipad" : "iphone" }
    var nameKey: String { WiFiHotspot.normalized(name) }
}

// MARK: - Instant Hotspot bridge (private API, runtime only)

/// Talks to sharingd through Apple's private `SFRemoteHotspotSession` (Sharing.framework), the same service behind
/// the "Personal Hotspot" section of Apple's Wi-Fi menu. Everything is looked up at runtime and guarded, so on a
/// macOS where the classes or selectors differ it simply reports "unavailable". All calls run on one serial queue.
///
/// Verified on macOS 27 from an unsigned process: `startBrowsing` makes sharingd call the delegate's
/// `session:updatedFoundDevices:` with `SFRemoteHotspotDevice` objects (name, model, battery, cellular signal and type),
/// with no entitlement. `enableHotspotForDevice:withCompletionHandler:` (the wake-up) is wired up but not exercised in testing.
final class WiFiInstantHotspot: @unchecked Sendable {
    static let shared = WiFiInstantHotspot()

    private let queue = DispatchQueue(label: "macmaster.wifi.hotspot", qos: .userInitiated)
    private var session: NSObject?
    private var delegate: HotspotDelegate?
    private var handler: (@Sendable ([WiFiHotspotDevice]) -> Void)?
    private static let frameworkPath = "/System/Library/PrivateFrameworks/Sharing.framework/Sharing"

    /// Delegate sharingd calls with the current device list. The session only keeps a weak reference.
    private final class HotspotDelegate: NSObject, @unchecked Sendable {
        let onDevices: @Sendable ([NSObject]) -> Void
        init(_ f: @escaping @Sendable ([NSObject]) -> Void) { onDevices = f }
        @objc(session:updatedFoundDevices:)
        func session(_ session: AnyObject, updatedFoundDevices devices: NSArray) {
            onDevices(devices.compactMap { $0 as? NSObject })
        }
    }

    /// nil when the private classes are available, else why not.
    func unavailableReason() -> String? {
        queue.sync {
            guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else { return "Apple's sharing service isn't available on this Mac." }
            guard let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type,
                  cls.instancesRespond(to: NSSelectorFromString("startBrowsing")),
                  cls.instancesRespond(to: NSSelectorFromString("setDelegate:")) else {
                return "This version of macOS doesn't expose Instant Hotspot to apps."
            }
            return nil
        }
    }

    /// Starts discovery. `onDevices` is called (on an arbitrary thread) every time the list changes.
    func start(onDevices: @escaping @Sendable ([WiFiHotspotDevice]) -> Void) {
        queue.async {
            self.stopLocked()
            guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil,
                  let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return }
            let setDelegate = NSSelectorFromString("setDelegate:"), startBrowsing = NSSelectorFromString("startBrowsing")
            guard cls.instancesRespond(to: setDelegate), cls.instancesRespond(to: startBrowsing) else { return }
            let s = cls.init()
            self.handler = onDevices
            let d = HotspotDelegate { objs in
                let devices = objs.compactMap(Self.parse)
                onDevices(devices)
            }
            self.delegate = d
            self.session = s
            _ = s.perform(setDelegate, with: d)
            _ = s.perform(startBrowsing)
        }
    }

    func stop() { queue.async { self.stopLocked() } }

    private func stopLocked() {
        if let s = session {
            let sel = NSSelectorFromString("stopBrowsing")
            if s.responds(to: sel) { _ = s.perform(sel) }
            let setDelegate = NSSelectorFromString("setDelegate:")
            if s.responds(to: setDelegate) { _ = s.perform(setDelegate, with: nil) }
        }
        session = nil; delegate = nil; handler = nil
    }

    /// Asks the device to switch its Personal Hotspot on. Completion gets the hotspot's SSID and password (never stored),
    /// or an error. Gives up after `timeout` seconds.
    func enable(_ device: WiFiHotspotDevice, timeout: TimeInterval = 30,
                completion: @escaping @Sendable (_ ssid: String?, _ password: String?, _ error: String?) -> Void) {
        queue.async {
            let sel = NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:")
            guard let s = self.session, s.responds(to: sel) else {
                completion(nil, nil, "Instant Hotspot isn't running."); return
            }
            let lock = NSLock()
            nonisolated(unsafe) var finished = false
            let finish: @Sendable (String?, String?, String?) -> Void = { a, b, c in
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if !already { completion(a, b, c) }
            }
            // Sharing calls the handler as (ssid, password, error) — disassembled on macOS 27. Type-check each
            // argument instead of trusting the shape, so a changed signature can't crash us.
            let block: @convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void = { a, b, c in
                if let err = [c, b, a].lazy.compactMap({ $0 as? NSError }).first {
                    finish(nil, nil, err.localizedDescription); return
                }
                finish(a as? String, b as? String, nil)
            }
            self.queue.asyncAfter(deadline: .now() + timeout) { finish(nil, nil, "The iPhone didn't respond in time.") }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void) -> Void
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {   // RTLD_DEFAULT
                finish(nil, nil, "Couldn't call Instant Hotspot."); return
            }
            unsafeBitCast(sym, to: Fn.self)(s, sel, device.object, block)
        }
    }

    // MARK: Parsing

    private static func string(_ o: NSObject?, _ key: String) -> String? {
        guard let o, o.responds(to: NSSelectorFromString(key)) else { return nil }
        return o.value(forKey: key) as? String
    }

    private static func number(_ o: NSObject, _ key: String) -> Int? {
        guard o.responds(to: NSSelectorFromString(key)) else { return nil }
        return (o.value(forKey: key) as? NSNumber)?.intValue
    }

    /// SFRemoteHotspotDevice → value type. Every property is optional: a missing selector just leaves it nil.
    fileprivate static func parse(_ o: NSObject) -> WiFiHotspotDevice? {
        guard let name = string(o, "deviceName"), !name.isEmpty else { return nil }
        let id = string(o, "deviceIdentifier") ?? name
        var net: String?
        if o.responds(to: NSSelectorFromString("networkType")), let t = (o.value(forKey: "networkType") as? NSNumber)?.intValue {
            net = networkLabel(t)
        }
        let batt = number(o, "batteryLife").map { max(0, min(100, $0)) }
        let sig = number(o, "signalStrength").map { max(0, min(4, $0)) }
        return WiFiHotspotDevice(id: id, name: name, model: string(o, "model") ?? "", battery: batt, signalBars: sig,
                                 network: net, object: o)
    }

    /// Values of SFRemoteHotspotDevice.networkType (matches the labels Apple prints in its own description).
    private static func networkLabel(_ t: Int) -> String? {
        switch t {
        case 1: "1x"
        case 2: "GPRS"
        case 3: "EDGE"
        case 4: "3G"
        case 5: "HSDPA"
        case 6: "4G"
        case 7: "LTE"
        case 8: "5G"
        default: nil
        }
    }
}

// MARK: - Join + helpers

enum WiFiHotspot {
    /// Apple names hotspots with a typographic apostrophe; scans and settings may use either.
    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'").lowercased()
    }

    /// Scans for `ssid` and joins it, retrying while the phone's hotspot comes up (it can take ~10 s).
    /// Blocking; call from a detached task. Returns nil on success, else an error message.
    static func join(ssid: String, password: String?, attempts: Int = 8) -> String? {
        guard let i = CWWiFiClient.shared().interface() else { return "No Wi-Fi interface" }
        guard i.powerOn() else { return "Wi-Fi is off" }
        var lastError = "The hotspot didn't show up. Check that Personal Hotspot is allowed on the iPhone."
        for n in 0..<attempts {
            if n > 0 { Thread.sleep(forTimeInterval: 2) }
            guard let found = try? i.scanForNetworks(withName: ssid), let net = found.first else { continue }
            do {
                try i.associate(to: net, password: password)
                return nil
            } catch {
                lastError = password == nil ? "Couldn't join (\(error.localizedDescription))." : "Couldn't join the hotspot."
                if n >= 1 { break }
            }
        }
        return lastError
    }

    /// Opens Apple's Wi-Fi menu extra (Instant Hotspot lives there) by pressing it through Accessibility.
    /// Needs the Accessibility permission; without it, or if the menu extra can't be found, opens Wi-Fi settings.
    @MainActor
    static func openAppleWiFiMenu() {
        if AXIsProcessTrusted(), pressWiFiMenuExtra() { return }
        WiFiModel.openWiFiSettings()
    }

    @MainActor
    private static func pressWiFiMenuExtra() -> Bool {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return false }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { return false }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return false }
        for item in items {
            var ident: CFTypeRef?, desc: CFTypeRef?
            AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &ident)
            AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &desc)
            let id = (ident as? String)?.lowercased() ?? "", d = (desc as? String)?.lowercased() ?? ""
            if id.contains("wifi") || d.contains("wi-fi") || d.contains("wifi") {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }
}

// MARK: - Model

/// Instant Hotspot state for the popover and the Wi-Fi page. Discovery (Bluetooth scanning in sharingd) only runs
/// while a Personal Hotspot section is on screen.
@Observable
@MainActor
final class WiFiHotspotModel {
    static let shared = WiFiHotspotModel()

    enum Discovery: Equatable { case idle, searching, found, empty, unavailable(String) }

    private(set) var devices: [WiFiHotspotDevice] = []
    private(set) var discovery: Discovery = .idle
    private(set) var connectingID: String?
    private(set) var step: String?
    private(set) var error: String?

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var emptyTimer: Task<Void, Never>?

    private init() {}

    func sectionAppeared() {
        users += 1
        guard users == 1 else { return }
        error = nil
        if let reason = WiFiInstantHotspot.shared.unavailableReason() { discovery = .unavailable(reason); return }
        discovery = .searching
        WiFiInstantHotspot.shared.start { list in
            Task { @MainActor in WiFiHotspotModel.shared.received(list) }
        }
        // Sharingd sends nothing when no device is around; stop saying "Looking…" after a few seconds.
        emptyTimer?.cancel()
        emptyTimer = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled, devices.isEmpty, discovery == .searching { discovery = .empty }
        }
    }

    func sectionDisappeared() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        emptyTimer?.cancel()
        WiFiInstantHotspot.shared.stop()
        if connectingID == nil { devices = [] }
        if case .unavailable = discovery {} else { discovery = .idle }
    }

    /// Restarts discovery (the Refresh button).
    func refresh() {
        guard users > 0, connectingID == nil else { return }
        let n = users
        users = 1; sectionDisappeared(); sectionAppeared()
        users = n
    }

    private func received(_ list: [WiFiHotspotDevice]) {
        guard users > 0 else { return }
        devices = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        discovery = devices.isEmpty ? .empty : .found
    }

    /// Whether the Mac is currently on this device's hotspot.
    func isConnected(_ d: WiFiHotspotDevice) -> Bool {
        guard let ssid = WiFiModel.shared.link.ssid else { return false }
        return WiFiHotspot.normalized(ssid) == d.nameKey
    }

    /// Asks the device to turn Personal Hotspot on, then joins it.
    func connect(_ d: WiFiHotspotDevice) {
        guard connectingID == nil else { return }
        connectingID = d.id
        error = nil
        step = "Asking \(d.name) to turn on Personal Hotspot…"
        WiFiInstantHotspot.shared.enable(d) { ssid, password, err in
            Task { @MainActor in await WiFiHotspotModel.shared.finishEnable(d, ssid: ssid, password: password, error: err) }
        }
    }

    private func finishEnable(_ d: WiFiHotspotDevice, ssid: String?, password: String?, error err: String?) async {
        if let err { fail(err); return }
        let name = (ssid?.isEmpty == false ? ssid : nil) ?? d.name
        step = "Joining \(name)…"
        let message = await Task.detached(priority: .userInitiated) { WiFiHotspot.join(ssid: name, password: password) }.value
        if let message { fail(message); return }
        connectingID = nil; step = nil
        WiFiModel.shared.tick()
    }

    private func fail(_ m: String) {
        connectingID = nil; step = nil; error = m
    }
}
