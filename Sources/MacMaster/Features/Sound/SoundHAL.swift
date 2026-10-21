import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Model types

enum SoundScope: Sendable {
    case output, input
    var hal: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
}

enum SoundTransport: String, Sendable {
    case builtIn, usb, bluetooth, display, airplay, aggregate, virtual, thunderbolt, other

    init(raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeAirPlay: self = .airplay
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire: self = .thunderbolt
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .display: "HDMI / DisplayPort"
        case .airplay: "AirPlay"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .thunderbolt: "Thunderbolt / FireWire"
        case .other: "Audio device"
        }
    }
}

/// One audio device as read from the HAL. Plain values only, so it can cross threads.
struct SoundDevice: Identifiable, Hashable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transport: SoundTransport
    var outChannels = 0
    var inChannels = 0
    var outVolume: Float?
    var outVolumeSettable = false
    var outMuted: Bool?
    var outMuteSettable = false
    var inVolume: Float?
    var inVolumeSettable = false
    var inMuted: Bool?
    var inMuteSettable = false
    var dataSource: UInt32?
    var rate: Double = 0
    var rates: [Double] = []

    var isOutput: Bool { outChannels > 0 }
    var isInput: Bool { inChannels > 0 }

    static let headphonesSource: UInt32 = 0x6864706E   // 'hdpn'
    static let speakerSource: UInt32 = 0x6973706B      // 'ispk'

    var onHeadphoneJack: Bool { transport == .builtIn && dataSource == Self.headphonesSource }
    /// Output that only the listener hears (so an unplug could suddenly blast the speakers).
    var isPrivateOutput: Bool { transport == .bluetooth || onHeadphoneJack }
    var isBuiltInSpeakers: Bool { transport == .builtIn && isOutput && dataSource != Self.headphonesSource }

    var isAirPods: Bool { name.localizedCaseInsensitiveContains("airpods") }
    var looksLikeHeadphones: Bool {
        let n = name.lowercased()
        return n.contains("headphone") || n.contains("headset") || n.contains("beats") || n.contains("buds") || n.contains("wh-") || n.contains("wf-")
    }

    var displayName: String { onHeadphoneJack ? "Headphones" : name }

    func subtitle(for scope: SoundScope) -> String {
        if transport == .builtIn {
            if scope == .output { return onHeadphoneJack ? "Built-in · Headphone jack" : "Built-in" }
            return "Built-in"
        }
        return transport.label
    }

    func symbol(for scope: SoundScope) -> String {
        switch transport {
        case .builtIn:
            if scope == .input { return "mic.fill" }
            return onHeadphoneJack ? "headphones" : "laptopcomputer"
        case .bluetooth:
            if isAirPods { return SymbolKit.firstAvailable(["airpods.gen3", "airpods", "headphones"]) }
            if looksLikeHeadphones { return "headphones" }
            return scope == .input ? "mic.fill" : SymbolKit.firstAvailable(["hifispeaker.fill", "speaker.wave.2.fill"])
        case .usb:
            return scope == .input ? "mic" : SymbolKit.firstAvailable(["cable.connector", "speaker.wave.2"])
        case .display:
            return SymbolKit.firstAvailable(["display", "tv"])
        case .airplay:
            return SymbolKit.firstAvailable(["airplayaudio", "airplay.audio", "speaker.wave.2"])
        case .aggregate:
            return SymbolKit.firstAvailable(["square.stack.3d.up.fill", "square.stack.3d.up"])
        case .virtual:
            return SymbolKit.firstAvailable(["waveform.path", "waveform"])
        case .thunderbolt:
            return SymbolKit.firstAvailable(["bolt.horizontal.fill", "cable.connector"])
        case .other:
            return scope == .input ? "mic" : "speaker.wave.2"
        }
    }
}

struct SoundSnapshot: Sendable {
    var devices: [SoundDevice]
    var defaultOutput: AudioObjectID
    var defaultInput: AudioObjectID
    var defaultSystemOutput: AudioObjectID
}

// MARK: - HAL access
//
// Every function here may block (Bluetooth devices can take seconds to answer), so callers use `SoundHAL.queue`,
// never the main thread. Each OSStatus is checked; a device that vanishes mid-call just yields nil/false.

enum SoundHAL {
    /// All HAL reads and writes run here, one at a time.
    static let queue = DispatchQueue(label: "com.macmaster.sound.hal", qos: .userInitiated)
    /// 'vmvc': the volume the system's own keys and menu control. Works on devices with no plain volume scalar.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663

    private static let standardRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    // MARK: Low-level

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        guard AudioObjectHasProperty(id, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, zero: T) -> T? {
        var a = address(sel, scope, element)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        var value = zero
        let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
        return st == noErr ? value : nil
    }

    @discardableResult
    static func write<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, value: T) -> OSStatus {
        var a = address(sel, scope, element)
        guard isSettable(id, a) else { return kAudioHardwareUnknownPropertyError }
        var v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(sel, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    static func array<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) -> [T] {
        var a = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var out = [T](repeating: zero, count: count)
        var sz = UInt32(count * MemoryLayout<T>.size)
        let st = out.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, base)
        }
        return st == noErr ? out : []
    }

    // MARK: Devices

    static func deviceIDs() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, zero: AudioObjectID(0))
    }

    static func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioObjectID {
        read(AudioObjectID(kAudioObjectSystemObject), sel, zero: AudioObjectID(0)) ?? 0
    }

    static func channelCount(_ id: AudioObjectID, _ scope: SoundScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope.hal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func snapshot() -> SoundSnapshot {
        var devices: [SoundDevice] = []
        for id in deviceIDs() {
            if let d = readDevice(id) { devices.append(d) }
        }
        return SoundSnapshot(devices: devices,
                             defaultOutput: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                             defaultInput: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                             defaultSystemOutput: defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice))
    }

    /// nil for devices that can't be used (hidden helpers, no streams, no uid).
    static func readDevice(_ id: AudioObjectID) -> SoundDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        if uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
        if let hidden: UInt32 = read(id, kAudioDevicePropertyIsHidden, zero: 0), hidden != 0 { return nil }
        let outCh = channelCount(id, .output), inCh = channelCount(id, .input)
        guard outCh > 0 || inCh > 0 else { return nil }
        var d = SoundDevice(id: id, uid: uid,
                            name: string(id, kAudioObjectPropertyName) ?? "Audio device",
                            transport: SoundTransport(raw: read(id, kAudioDevicePropertyTransportType, zero: UInt32(0)) ?? 0))
        d.outChannels = outCh
        d.inChannels = inCh
        if outCh > 0 {
            let v = volume(id, .output)
            d.outVolume = v?.value
            d.outVolumeSettable = v?.settable ?? false
            let m = mute(id, .output)
            d.outMuted = m?.value
            d.outMuteSettable = m?.settable ?? false
            d.dataSource = read(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, zero: UInt32(0))
        }
        if inCh > 0 {
            let v = volume(id, .input)
            d.inVolume = v?.value
            d.inVolumeSettable = v?.settable ?? false
            let m = mute(id, .input)
            d.inMuted = m?.value
            d.inMuteSettable = m?.settable ?? false
        }
        d.rate = read(id, kAudioDevicePropertyNominalSampleRate, zero: Float64(0)) ?? 0
        d.rates = availableRates(id)
        return d
    }

    // MARK: Volume / mute

    static func volume(_ id: AudioObjectID, _ scope: SoundScope) -> (value: Float, settable: Bool)? {
        let s = scope.hal
        let main = kAudioObjectPropertyElementMain
        for sel in [virtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            if let v: Float32 = read(id, sel, scope: s, element: main, zero: 0) {
                return (v, isSettable(id, address(sel, s, main)))
            }
        }
        var values: [Float32] = []
        var settable = true
        for ch in 1...2 {
            let el = AudioObjectPropertyElement(ch)
            if let v: Float32 = read(id, kAudioDevicePropertyVolumeScalar, scope: s, element: el, zero: 0) {
                values.append(v)
                if !isSettable(id, address(kAudioDevicePropertyVolumeScalar, s, el)) { settable = false }
            }
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Float(values.count), settable)
    }

    @discardableResult
    static func setVolume(_ id: AudioObjectID, _ scope: SoundScope, _ value: Float) -> OSStatus {
        let v = min(max(value, 0), 1)
        let s = scope.hal
        let main = kAudioObjectPropertyElementMain
        for sel in [virtualMainVolume, kAudioDevicePropertyVolumeScalar] where isSettable(id, address(sel, s, main)) {
            return write(id, sel, scope: s, element: main, value: Float32(v))
        }
        var st: OSStatus = kAudioHardwareUnknownPropertyError
        for ch in 1...2 {
            let r = write(id, kAudioDevicePropertyVolumeScalar, scope: s, element: AudioObjectPropertyElement(ch), value: Float32(v))
            if r == noErr { st = noErr }
        }
        return st
    }

    static func mute(_ id: AudioObjectID, _ scope: SoundScope) -> (value: Bool, settable: Bool)? {
        let s = scope.hal
        if let m: UInt32 = read(id, kAudioDevicePropertyMute, scope: s, zero: 0) {
            return (m != 0, isSettable(id, address(kAudioDevicePropertyMute, s)))
        }
        var values: [Bool] = []
        var settable = true
        for ch in 1...2 {
            let el = AudioObjectPropertyElement(ch)
            if let m: UInt32 = read(id, kAudioDevicePropertyMute, scope: s, element: el, zero: 0) {
                values.append(m != 0)
                if !isSettable(id, address(kAudioDevicePropertyMute, s, el)) { settable = false }
            }
        }
        guard !values.isEmpty else { return nil }
        return (values.allSatisfy { $0 }, settable)
    }

    @discardableResult
    static func setMute(_ id: AudioObjectID, _ scope: SoundScope, _ muted: Bool) -> OSStatus {
        let s = scope.hal
        let v: UInt32 = muted ? 1 : 0
        if isSettable(id, address(kAudioDevicePropertyMute, s)) {
            return write(id, kAudioDevicePropertyMute, scope: s, value: v)
        }
        var st: OSStatus = kAudioHardwareUnknownPropertyError
        for ch in 1...2 {
            let r = write(id, kAudioDevicePropertyMute, scope: s, element: AudioObjectPropertyElement(ch), value: v)
            if r == noErr { st = noErr }
        }
        return st
    }

    // MARK: Defaults / sample rate

    @discardableResult
    static func setDefault(_ sel: AudioObjectPropertySelector, _ id: AudioObjectID) -> OSStatus {
        var a = address(sel)
        var v = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v)
    }

    static func availableRates(_ id: AudioObjectID) -> [Double] {
        let ranges = array(id, kAudioDevicePropertyAvailableNominalSampleRates, zero: AudioValueRange())
        var out = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { out.insert(r.mMinimum); continue }
            for c in standardRates where c >= r.mMinimum && c <= r.mMaximum { out.insert(c) }
        }
        return out.sorted()
    }

    @discardableResult
    static func setRate(_ id: AudioObjectID, _ rate: Double) -> OSStatus {
        write(id, kAudioDevicePropertyNominalSampleRate, value: Float64(rate))
    }
}

// MARK: - Property listeners

/// Registers HAL property listeners and forwards every callback to `SoundEngine`. No polling anywhere.
/// All mutation happens on `SoundHAL.queue`.
final class SoundListeners: @unchecked Sendable {
    static let shared = SoundListeners()
    private let callbackQueue = DispatchQueue(label: "com.macmaster.sound.listeners")
    private var systemInstalled = false
    private var perDevice: [AudioObjectID: [AudioObjectPropertyAddress]] = [:]

    /// One block for every registration (removal needs the same block).
    private let block: AudioObjectPropertyListenerBlock = { _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { SoundEngine.shared.scheduleRefresh() } }
    }

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]

    private static func deviceAddresses() -> [AudioObjectPropertyAddress] {
        var out: [AudioObjectPropertyAddress] = []
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            out.append(SoundHAL.address(SoundHAL.virtualMainVolume, scope))
            for el in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                out.append(SoundHAL.address(kAudioDevicePropertyVolumeScalar, scope, el))
                out.append(SoundHAL.address(kAudioDevicePropertyMute, scope, el))
            }
            out.append(SoundHAL.address(kAudioDevicePropertyDataSource, scope))
        }
        out.append(SoundHAL.address(kAudioDevicePropertyNominalSampleRate))
        return out
    }

    /// Install system-wide listeners (idempotent). Call from any thread.
    func installSystem() {
        SoundHAL.queue.async { [self] in
            guard !systemInstalled else { return }
            systemInstalled = true
            for sel in Self.systemSelectors {
                var a = SoundHAL.address(sel)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, callbackQueue, block)
            }
        }
    }

    /// Listen for volume, mute, data source and rate changes on exactly these devices.
    func watch(devices ids: Set<AudioObjectID>) {
        SoundHAL.queue.async { [self] in
            guard systemInstalled else { return }
            for (id, addrs) in perDevice where !ids.contains(id) {
                for var a in addrs { AudioObjectRemovePropertyListenerBlock(id, &a, callbackQueue, block) }
                perDevice[id] = nil
            }
            for id in ids where perDevice[id] == nil && id != 0 {
                var added: [AudioObjectPropertyAddress] = []
                for var a in Self.deviceAddresses() {
                    if AudioObjectAddPropertyListenerBlock(id, &a, callbackQueue, block) == noErr { added.append(a) }
                }
                perDevice[id] = added
            }
        }
    }

    /// Remove everything.
    func removeAll() {
        SoundHAL.queue.async { [self] in
            for (id, addrs) in perDevice {
                for var a in addrs { AudioObjectRemovePropertyListenerBlock(id, &a, callbackQueue, block) }
            }
            perDevice = [:]
            if systemInstalled {
                for sel in Self.systemSelectors {
                    var a = SoundHAL.address(sel)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, callbackQueue, block)
                }
                systemInstalled = false
            }
        }
    }
}

/// Coalesces rapid slider writes: only the newest value per device/scope is sent, one at a time.
final class SoundVolumeWriter: @unchecked Sendable {
    static let shared = SoundVolumeWriter()
    private struct Key: Hashable { var id: AudioObjectID; var input: Bool }
    private let lock = NSLock()
    private var pending: [Key: Float] = [:]
    private var running = false

    func set(_ id: AudioObjectID, _ scope: SoundScope, _ value: Float) {
        lock.lock()
        pending[Key(id: id, input: scope == .input)] = value
        let start = !running
        running = true
        lock.unlock()
        guard start else { return }
        SoundHAL.queue.async { [self] in
            while true {
                lock.lock()
                guard let (k, v) = pending.first else { running = false; lock.unlock(); return }
                pending[k] = nil
                lock.unlock()
                SoundHAL.setVolume(k.id, k.input ? .input : .output, v)
            }
        }
    }
}
