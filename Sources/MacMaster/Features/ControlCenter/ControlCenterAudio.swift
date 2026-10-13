import Foundation
import CoreAudio
import AudioToolbox
import CoreGraphics
import Observation

struct ControlCenterAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    /// Glyph for the device's connection type.
    func symbol(input: Bool) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return SymbolKit.firstAvailable(["headphones", "speaker.wave.2.fill"])
        case kAudioDeviceTransportTypeBuiltIn:
            return input ? "mic.fill" : SymbolKit.firstAvailable(["laptopcomputer", "speaker.wave.2.fill"])
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return SymbolKit.firstAvailable(["display", "tv"])
        case kAudioDeviceTransportTypeAirPlay:
            return SymbolKit.firstAvailable(["airplayaudio", "speaker.wave.2.fill"])
        case kAudioDeviceTransportTypeUSB:
            return input ? "mic.fill" : SymbolKit.firstAvailable(["hifispeaker.fill", "speaker.wave.2.fill"])
        default:
            return input ? "mic.fill" : "speaker.wave.2.fill"
        }
    }
}

/// Output and input volume, mute and device lists through CoreAudio. Reads happen on open;
/// property listeners are attached only between `startListening()` and `stopListening()`.
@Observable
@MainActor
final class ControlCenterAudio {
    static let shared = ControlCenterAudio()

    // Output
    private(set) var volume: Float = 0
    private(set) var hasVolume = false
    private(set) var muted = false
    private(set) var hasMute = false
    private(set) var devices: [ControlCenterAudioDevice] = []
    private(set) var currentID: AudioDeviceID = 0

    // Input
    private(set) var inputs: [ControlCenterAudioDevice] = []
    private(set) var inputID: AudioDeviceID = 0
    private(set) var micMuted = false
    private(set) var hasMic = false

    /// Volume per device (both directions) for the device panel. Missing key = no volume control.
    private(set) var deviceVolumes: [AudioDeviceID: Float] = [:]

    var currentName: String { devices.first { $0.id == currentID }?.name ?? "Output" }
    var inputName: String { inputs.first { $0.id == inputID }?.name ?? "Input" }

    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var hookedOutput: AudioDeviceID = 0
    @ObservationIgnored private var hookedInput: AudioDeviceID = 0
    private init() {}

    // MARK: Addresses

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func addr(_ sel: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }
    private static func scope(_ input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }
    private static func defaultAddr(input: Bool) -> AudioObjectPropertyAddress {
        addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
             scope: kAudioObjectPropertyScopeGlobal)
    }
    private static var devicesAddr: AudioObjectPropertyAddress {
        addr(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
    }

    // MARK: Volume / mute primitives

    /// Addresses that together carry a device's volume: the virtual main volume if present,
    /// else the main scalar, else the first two channels.
    private static func volumeAddrs(_ id: AudioDeviceID, input: Bool) -> [AudioObjectPropertyAddress] {
        let s = scope(input)
        let candidates: [[AudioObjectPropertyAddress]] = [
            [addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: s)],
            [addr(kAudioDevicePropertyVolumeScalar, scope: s, element: kAudioObjectPropertyElementMain)],
            [addr(kAudioDevicePropertyVolumeScalar, scope: s, element: 1),
             addr(kAudioDevicePropertyVolumeScalar, scope: s, element: 2)],
        ]
        for set in candidates {
            let ok = set.allSatisfy { a in
                var a = a
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(id, &a)
                    && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
            }
            if ok { return set }
        }
        return []
    }

    private static func readVolume(_ id: AudioDeviceID, input: Bool) -> Float? {
        let set = volumeAddrs(id, input: input)
        guard !set.isEmpty else { return nil }
        var total: Float = 0
        for a in set {
            var a = a
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
            total += v
        }
        return total / Float(set.count)
    }

    private static func writeVolume(_ id: AudioDeviceID, input: Bool, _ value: Float) {
        var v = max(0, min(1, value))
        for a in volumeAddrs(id, input: input) {
            var a = a
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    private static func readMute(_ id: AudioDeviceID, input: Bool) -> Bool? {
        var a = addr(kAudioDevicePropertyMute, scope: scope(input))
        var settable: DarwinBoolean = false
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &a),
              AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue,
              AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    private static func writeMute(_ id: AudioDeviceID, input: Bool, _ on: Bool) {
        var a = addr(kAudioDevicePropertyMute, scope: scope(input))
        var v: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // MARK: Reading

    func refresh() {
        devices = Self.devices(input: false)
        inputs = Self.devices(input: true)
        currentID = Self.defaultDevice(input: false) ?? 0
        inputID = Self.defaultDevice(input: true) ?? 0

        if currentID != 0, let v = Self.readVolume(currentID, input: false) {
            hasVolume = true; volume = v
        } else { hasVolume = false }
        if currentID != 0, let m = Self.readMute(currentID, input: false) {
            hasMute = true; muted = m
        } else { hasMute = false; muted = false }

        if inputID != 0 {
            if let m = Self.readMute(inputID, input: true) {
                hasMic = true; micMuted = m
            } else if let v = Self.readVolume(inputID, input: true) {
                hasMic = true; micMuted = v <= 0.001
            } else { hasMic = false; micMuted = false }
        } else { hasMic = false; micMuted = false }

        var vols: [AudioDeviceID: Float] = [:]
        for d in devices { if let v = Self.readVolume(d.id, input: false) { vols[d.id] = v } }
        for d in inputs { if let v = Self.readVolume(d.id, input: true) { vols[d.id] = v } }
        deviceVolumes = vols
    }

    // MARK: Writing

    func setVolume(_ value: Float) {
        guard hasVolume, currentID != 0 else { return }
        let v = max(0, min(1, value))
        Self.writeVolume(currentID, input: false, v)
        volume = v
        deviceVolumes[currentID] = v
        if v > 0, muted { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        guard hasMute, currentID != 0 else { return }
        Self.writeMute(currentID, input: false, on)
        muted = on
    }

    func toggleMute() { setMuted(!muted) }

    /// Volume of one specific device (output or input), from the device panel.
    func setDeviceVolume(_ device: ControlCenterAudioDevice, input: Bool, _ value: Float) {
        let v = max(0, min(1, value))
        Self.writeVolume(device.id, input: input, v)
        deviceVolumes[device.id] = v
        if !input, device.id == currentID { volume = v }
    }

    func select(_ device: ControlCenterAudioDevice) {
        var id = device.id
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var a = Self.addr(sel, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectSetPropertyData(Self.system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        }
        refresh()
        rehookDeviceListeners()
    }

    func selectInput(_ device: ControlCenterAudioDevice) {
        var id = device.id
        var a = Self.addr(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectSetPropertyData(Self.system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        refresh()
        rehookDeviceListeners()
    }

    /// Mutes the current input. Uses the device's mute switch when it has one,
    /// otherwise drops the gain to zero and remembers the old gain so unmuting restores it.
    func setMicMuted(_ on: Bool) {
        guard hasMic, inputID != 0 else { return }
        if Self.readMute(inputID, input: true) != nil {
            Self.writeMute(inputID, input: true, on)
        } else {
            let key = "mm.controlcenter.micGain." + (Self.uid(inputID) ?? String(inputID))
            if on {
                if let v = Self.readVolume(inputID, input: true), v > 0.001 {
                    UserDefaults.standard.set(Double(v), forKey: key)
                }
                Self.writeVolume(inputID, input: true, 0)
            } else {
                let prev = UserDefaults.standard.object(forKey: key) as? Double ?? 0.75
                Self.writeVolume(inputID, input: true, Float(prev))
            }
        }
        micMuted = on
        deviceVolumes[inputID] = Self.readVolume(inputID, input: true)
    }

    func toggleMic() { setMicMuted(!micMuted) }

    // MARK: Listeners (only while the popover is open)

    func startListening() {
        guard listeners.isEmpty else { return }
        add(Self.system, Self.defaultAddr(input: false)) { $0.defaultChanged() }
        add(Self.system, Self.defaultAddr(input: true)) { $0.defaultChanged() }
        add(Self.system, Self.devicesAddr) { $0.refresh() }
        rehookDeviceListeners()
    }

    func stopListening() {
        for (obj, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(obj, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
        hookedOutput = 0; hookedInput = 0
    }

    private func defaultChanged() {
        refresh()
        rehookDeviceListeners()
    }

    /// Volume/mute listeners follow the current default output and input devices.
    private func rehookDeviceListeners() {
        guard !listeners.isEmpty, currentID != hookedOutput || inputID != hookedInput else { return }
        let keep = listeners.filter { $0.0 == Self.system }
        for l in listeners where l.0 != Self.system {
            var a = l.1
            AudioObjectRemovePropertyListenerBlock(l.0, &a, DispatchQueue.main, l.2)
        }
        listeners = keep
        hookedOutput = currentID; hookedInput = inputID
        if currentID != 0 {
            add(currentID, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)) { $0.refresh() }
            add(currentID, Self.addr(kAudioDevicePropertyMute)) { $0.refresh() }
        }
        if inputID != 0 {
            add(inputID, Self.addr(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)) { $0.refresh() }
            add(inputID, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeInput)) { $0.refresh() }
        }
    }

    private func add(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress,
                     _ handler: @escaping @MainActor (ControlCenterAudio) -> Void) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        var a = address
        if AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main, block) == noErr {
            listeners.append((obj, address, block))
        }
    }

    // MARK: Device enumeration

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var a = defaultAddr(input: input)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func devices(input: Bool) -> [ControlCenterAudioDevice] {
        var a = devicesAddr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasStreams(id, input: input), !isHidden(id), let name = name(id) else { return nil }
            return ControlCenterAudioDevice(id: id, name: name, transport: transport(id))
        }
    }

    private static func hasStreams(_ id: AudioDeviceID, input: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope: scope(input))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return 0 }
        return v
    }

    private static func cfString(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel, scope: kAudioObjectPropertyScopeGlobal)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    private static func name(_ id: AudioDeviceID) -> String? { cfString(id, kAudioObjectPropertyName) }
    private static func uid(_ id: AudioDeviceID) -> String? { cfString(id, kAudioDevicePropertyDeviceUID) }
}

// MARK: - Display brightness (DisplayServices, private)

/// Built-in display brightness. Hidden when the symbols are missing or the Mac has no built-in display.
enum ControlCenterBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let lib = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let getFn: GetFn? = {
        guard let h = dlopen(lib, RTLD_LAZY), let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    private static let setFn: SetFn? = {
        guard let h = dlopen(lib, RTLD_LAZY), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// nil = not controllable (no built-in display, external only, or API missing).
    static func read() -> Float? {
        guard let get = getFn, setFn != nil, let d = builtInDisplay() else { return nil }
        var v: Float = 0
        return get(d, &v) == 0 ? v : nil
    }

    static func write(_ value: Float) {
        guard let set = setFn, let d = builtInDisplay() else { return }
        _ = set(d, max(0, min(1, value)))
    }
}
