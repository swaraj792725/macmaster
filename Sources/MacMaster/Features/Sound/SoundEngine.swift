import Foundation
import CoreAudio
import AppKit
import os

// MARK: - Settings

/// UserDefaults keys and their defaults. `@AppStorage` in the views uses the same keys and default values.
enum SoundSettings {
    static let autoSwitchKey = "mm.sound.autoSwitch"          // false
    static let neverBTInputKey = "mm.sound.neverBTInput"      // true (only matters while auto-switch is on)
    static let unplugProtectKey = "mm.sound.unplugProtect"    // true
    static let unplugActionKey = "mm.sound.unplugAction"      // "mute" | "volume"
    static let unplugVolumeKey = "mm.sound.unplugVolume"      // 25 (percent)
    static let rememberVolumeKey = "mm.sound.rememberVolume"  // false
    static let menuBarKey = "mm.sound.menuBar"                // false
    static let mutedIndicatorKey = "mm.sound.mutedIndicator"  // true
    static let hotKeyKey = "mm.sound.micHotKey"               // nil
    static let micMutedKey = "mm.sound.micMuted"
    static let micSavedKey = "mm.sound.micSaved"
    static let priorityOutKey = "mm.sound.priority.out"
    static let priorityInKey = "mm.sound.priority.in"
    static let knownKey = "mm.sound.known"
    static let volumesKey = "mm.sound.volumes"

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static var autoSwitch: Bool { bool(autoSwitchKey, false) }
    static var neverBTInput: Bool { bool(neverBTInputKey, true) }
    static var unplugProtect: Bool { bool(unplugProtectKey, true) }
    static var unplugAction: String { UserDefaults.standard.string(forKey: unplugActionKey) ?? "mute" }
    static var unplugVolume: Int { UserDefaults.standard.object(forKey: unplugVolumeKey) as? Int ?? 25 }
    static var rememberVolume: Bool { bool(rememberVolumeKey, false) }
    static var menuBar: Bool { bool(menuBarKey, false) }
    static var mutedIndicator: Bool { bool(mutedIndicatorKey, true) }
}

/// What we remember about a device so it can stay in the priority list while unplugged.
struct SoundKnownDevice: Codable, Hashable, Sendable {
    var name: String
    var transport: String
    var hasOutput: Bool
    var hasInput: Bool
    var isAirPods: Bool = false
    var jack: Bool = false
}

/// One row of a priority list: a connected device or a remembered, disconnected one.
struct SoundPriorityEntry: Identifiable, Hashable {
    var uid: String
    var name: String
    var transport: SoundTransport
    var connected: Bool
    var symbol: String
    var id: String { uid }
}

// MARK: - Engine

/// CoreAudio-backed model for the Sound page, menu bar item and automations.
///
/// All HAL reads and writes happen on `SoundHAL.queue`; results hop back to the main actor. Property listeners
/// (device list, defaults, volume, mute, data source, sample rate) drive refreshes, so nothing polls.
@MainActor @Observable
final class SoundEngine {
    static let shared = SoundEngine()

    // MARK: Observable state
    private(set) var devices: [SoundDevice] = []
    private(set) var defaultOutputID: AudioObjectID = 0
    private(set) var defaultInputID: AudioObjectID = 0
    private(set) var defaultSystemOutputID: AudioObjectID = 0
    private(set) var loaded = false
    var micMuted = UserDefaults.standard.bool(forKey: SoundSettings.micMutedKey)
    private(set) var priorityOut: [String] = UserDefaults.standard.stringArray(forKey: SoundSettings.priorityOutKey) ?? []
    private(set) var priorityIn: [String] = UserDefaults.standard.stringArray(forKey: SoundSettings.priorityInKey) ?? []
    private(set) var known: [String: SoundKnownDevice] = SoundEngine.loadKnown()
    /// Short-lived info line ("Switched output to AirPods").
    var notice: String?
    /// Last failure, shown inline.
    var errorText: String?
    /// Set when the default microphone can't be muted from software.
    var micMuteProblem: String?

    // MARK: Private state
    @ObservationIgnored let log = Logger(subsystem: "com.macmaster.app", category: "sound")
    @ObservationIgnored var observers: Set<String> = []
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var holdVolumeUntil = Date.distantPast
    @ObservationIgnored private var suppressSaveUntil = Date.distantPast
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored var enforceTask: Task<Void, Never>?
    @ObservationIgnored var micFailed: Set<String> = []
    @ObservationIgnored var started = false

    private init() {}

    // MARK: Derived

    var outputs: [SoundDevice] { devices.filter(\.isOutput) }
    var inputs: [SoundDevice] { devices.filter(\.isInput) }
    var defaultOutput: SoundDevice? { devices.first { $0.id == defaultOutputID && $0.isOutput } }
    var defaultInput: SoundDevice? { devices.first { $0.id == defaultInputID && $0.isInput } }
    var defaultSystemOutput: SoundDevice? { devices.first { $0.id == defaultSystemOutputID && $0.isOutput } }

    // MARK: Lifecycle

    /// Runs once at launch. Installs listeners and the hot key only when a feature needs them.
    func start() {
        guard !started else { return }
        started = true
        registerHotKey()
        SoundMenuBar.shared.update()
        SoundMuteIndicator.shared.sync(muted: micMuted, animated: false)
        updateListeners()
    }

    /// A setting changed on the page; re-evaluate what must run.
    func settingsChanged() {
        SoundMenuBar.shared.update()
        SoundMuteIndicator.shared.sync(muted: micMuted, animated: false)
        updateListeners()
    }

    /// The page (or any UI) wants live updates while visible.
    func setObserving(_ reason: String, _ on: Bool) {
        if on { observers.insert(reason) } else { observers.remove(reason) }
        updateListeners()
    }

    private var automationNeeded: Bool {
        SoundSettings.autoSwitch || SoundSettings.unplugProtect || SoundSettings.rememberVolume
            || SoundSettings.menuBar || micMuted || StoredHotKey.load(SoundSettings.hotKeyKey) != nil
    }

    private func updateListeners() {
        if !observers.isEmpty || automationNeeded {
            SoundListeners.shared.installSystem()
            if !loaded { refreshNow() } else { scheduleRefresh() }
        } else {
            SoundListeners.shared.removeAll()
        }
    }

    func registerHotKey() {
        guard !Services.isSnapshotRun else { return }
        GlobalHotKeys.shared.register("sound.micMute", defaultsKey: SoundSettings.hotKeyKey) {
            SoundEngine.shared.toggleMicMute()
        }
        updateListeners()
    }

    // MARK: Refresh

    /// Called (via the main queue) by every HAL listener; coalesces bursts into one read.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MainActor.assumeIsolated {
                self.refreshPending = false
                self.refreshNow()
            }
        }
    }

    func refreshNow() {
        if inFlight { dirty = true; return }
        inFlight = true
        SoundHAL.queue.async {
            let snap = SoundHAL.snapshot()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(snap) } }
        }
    }

    private func apply(_ snap: SoundSnapshot) {
        inFlight = false
        defer { if dirty { dirty = false; scheduleRefresh() } }

        let first = !loaded
        let oldDevices = devices
        let oldOut = defaultOutput, oldIn = defaultInput

        var new = snap.devices
        // Don't let a stale read yank a slider the user is dragging.
        if Date() < holdVolumeUntil {
            for i in new.indices {
                if let o = oldDevices.first(where: { $0.id == new[i].id }) {
                    new[i].outVolume = o.outVolume; new[i].outMuted = o.outMuted
                    new[i].inVolume = o.inVolume; new[i].inMuted = o.inMuted
                }
            }
        }
        if new != devices { devices = new }
        if defaultOutputID != snap.defaultOutput { defaultOutputID = snap.defaultOutput }
        if defaultInputID != snap.defaultInput { defaultInputID = snap.defaultInput }
        if defaultSystemOutputID != snap.defaultSystemOutput { defaultSystemOutputID = snap.defaultSystemOutput }
        loaded = true

        SoundListeners.shared.watch(devices: [snap.defaultOutput, snap.defaultInput].filter { $0 != 0 }.reduce(into: Set()) { $0.insert($1) })
        recordKnown(new)

        let newOut = defaultOutput, newIn = defaultInput
        if first {
            reconcileMic()
            return
        }

        // Output changes: unplug protection, per-device volume.
        var protectFired = false
        if SoundSettings.unplugProtect, let o = oldOut, o.isPrivateOutput, let n = newOut, n.isBuiltInSpeakers {
            let gone = !new.contains { $0.uid == o.uid && $0.isOutput }
            let jackUnplugged = o.uid == n.uid
            if gone || jackUnplugged {
                protectFired = true
                protectOutput(n, from: o)
            }
        }
        let oldKey = oldOut.map(Self.volumeKey), newKey = newOut.map(Self.volumeKey)
        if oldKey != newKey, let n = newOut {
            suppressSaveUntil = Date().addingTimeInterval(1.2)
            if !protectFired { restoreVolume(for: n) }
        } else if SoundSettings.rememberVolume, Date() > suppressSaveUntil, let n = newOut, let v = n.outVolume {
            saveVolume(v, for: n)
        }
        if oldIn?.id != newIn?.id { SoundLevelMeter.shared.restartIfRunning() }

        reconcileMic()

        // Auto-switch only reacts to devices coming or going, never to the user's own choice.
        if SoundSettings.autoSwitch {
            let outChanged = Set(oldDevices.filter(\.isOutput).map(\.uid)) != Set(new.filter(\.isOutput).map(\.uid))
            let inChanged = Set(oldDevices.filter(\.isInput).map(\.uid)) != Set(new.filter(\.isInput).map(\.uid))
            if outChanged || inChanged { scheduleEnforce(output: outChanged, input: inChanged) }
        }
    }

    // MARK: Volume memory

    static func volumeKey(_ d: SoundDevice) -> String { d.uid + (d.onHeadphoneJack ? "#jack" : "") }

    private func restoreVolume(for d: SoundDevice) {
        guard SoundSettings.rememberVolume, d.outVolumeSettable,
              let dict = UserDefaults.standard.dictionary(forKey: SoundSettings.volumesKey) as? [String: Double],
              let v = dict[Self.volumeKey(d)] else { return }
        SoundVolumeWriter.shared.set(d.id, .output, Float(v))
        holdVolumeUntil = Date().addingTimeInterval(0.6)
        updateLocal(d.id) { $0.outVolume = Float(v) }
    }

    private func saveVolume(_ v: Float, for d: SoundDevice) {
        var dict = UserDefaults.standard.dictionary(forKey: SoundSettings.volumesKey) as? [String: Double] ?? [:]
        let key = Self.volumeKey(d)
        guard abs((dict[key] ?? -1) - Double(v)) > 0.004 else { return }
        dict[key] = Double(v)
        UserDefaults.standard.set(dict, forKey: SoundSettings.volumesKey)
    }

    // MARK: Unplug protection

    private func protectOutput(_ n: SoundDevice, from old: SoundDevice) {
        let action = SoundSettings.unplugAction
        let target = Float(SoundSettings.unplugVolume) / 100
        let id = n.id
        let muteSupported = n.outMuteSettable
        let volumeSupported = n.outVolumeSettable
        holdVolumeUntil = Date().addingTimeInterval(0.6)
        var did = ""
        if action == "volume", volumeSupported {
            SoundVolumeWriter.shared.set(id, .output, target)
            updateLocal(id) { $0.outVolume = target }
            did = "Volume set to \(SoundSettings.unplugVolume)%"
        } else if muteSupported {
            SoundHAL.queue.async { SoundHAL.setMute(id, .output, true) }
            updateLocal(id) { $0.outMuted = true }
            did = "Output muted"
        } else if volumeSupported {
            SoundVolumeWriter.shared.set(id, .output, 0)
            updateLocal(id) { $0.outVolume = 0 }
            did = "Volume set to 0%"
        } else {
            return
        }
        let from = old.displayName
        showNotice("\(from) disconnected. \(did) so the speakers don't blast.")
        Notifier.post(title: "\(from) disconnected", body: "\(did). Raise the volume when you're ready.", id: "mm.sound.unplug", sound: false)
    }

    // MARK: Actions (called from views)

    func selectOutput(_ d: SoundDevice) {
        guard d.id != defaultOutputID else { return }
        let followSystem = defaultSystemOutputID == defaultOutputID
        defaultOutputID = d.id
        if followSystem { defaultSystemOutputID = d.id }
        setDefault(kAudioHardwarePropertyDefaultOutputDevice, d, alsoSystem: followSystem)
    }

    func selectInput(_ d: SoundDevice) {
        guard d.id != defaultInputID else { return }
        defaultInputID = d.id
        setDefault(kAudioHardwarePropertyDefaultInputDevice, d, alsoSystem: false)
    }

    func selectSystemOutput(_ d: SoundDevice) {
        guard d.id != defaultSystemOutputID else { return }
        defaultSystemOutputID = d.id
        setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, d, alsoSystem: false)
    }

    private func setDefault(_ sel: AudioObjectPropertySelector, _ d: SoundDevice, alsoSystem: Bool) {
        let id = d.id, name = d.displayName
        SoundHAL.queue.async {
            var st = SoundHAL.setDefault(sel, id)
            if st == noErr, alsoSystem { SoundHAL.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, id) }
            if st != noErr { st = st == 0 ? kAudioHardwareUnspecifiedError : st }
            let failed = st != noErr
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failed {
                        self.errorText = "Couldn't switch to \(name). It may be disconnected or busy."
                        self.log.error("setDefault failed \(st)")
                    } else {
                        self.errorText = nil
                    }
                    self.refreshNow()
                }
            }
        }
    }

    func setOutputVolume(_ d: SoundDevice, _ v: Float) {
        holdVolumeUntil = Date().addingTimeInterval(0.5)
        let wasMuted = d.outMuted == true
        updateLocal(d.id) { $0.outVolume = v; if wasMuted && v > 0 { $0.outMuted = false } }
        SoundVolumeWriter.shared.set(d.id, .output, v)
        if wasMuted && v > 0 { let id = d.id; SoundHAL.queue.async { SoundHAL.setMute(id, .output, false) } }
        if SoundSettings.rememberVolume { saveVolume(v, for: d) }
    }

    func toggleOutputMute(_ d: SoundDevice) {
        let target = !(d.outMuted ?? false)
        let id = d.id
        updateLocal(id) { $0.outMuted = target }
        holdVolumeUntil = Date().addingTimeInterval(0.5)
        SoundHAL.queue.async {
            let st = SoundHAL.setMute(id, .output, target)
            if st != noErr {   // no mute switch: emulate with volume
                if target { SoundHAL.setVolume(id, .output, 0) }
            }
        }
        if d.outMuteSettable == false, target { updateLocal(id) { $0.outVolume = 0 } }
    }

    func setInputVolume(_ d: SoundDevice, _ v: Float) {
        holdVolumeUntil = Date().addingTimeInterval(0.5)
        updateLocal(d.id) { $0.inVolume = v }
        SoundVolumeWriter.shared.set(d.id, .input, v)
    }

    func setRate(_ d: SoundDevice, _ rate: Double) {
        let id = d.id, name = d.displayName
        updateLocal(id) { $0.rate = rate }
        SoundHAL.queue.async {
            let st = SoundHAL.setRate(id, rate)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if st != noErr { self.errorText = "\(name) didn't accept that sample rate." }
                    self.refreshNow()
                }
            }
        }
    }

    func updateLocal(_ id: AudioObjectID, _ change: (inout SoundDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        var d = devices[i]
        change(&d)
        devices[i] = d
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { self.notice = nil }
        }
    }

    // MARK: Known devices & priority

    private static func loadKnown() -> [String: SoundKnownDevice] {
        guard let d = UserDefaults.standard.data(forKey: SoundSettings.knownKey),
              let m = try? JSONDecoder().decode([String: SoundKnownDevice].self, from: d) else { return [:] }
        return m
    }

    private func recordKnown(_ list: [SoundDevice]) {
        var k = known, out = priorityOut, inn = priorityIn
        var changed = false
        // External devices go ahead of built-in ones the first time they are seen.
        for d in list.sorted(by: { ($0.transport == .builtIn ? 1 : 0) < ($1.transport == .builtIn ? 1 : 0) }) {
            let info = SoundKnownDevice(name: d.name, transport: d.transport.rawValue, hasOutput: d.isOutput || (k[d.uid]?.hasOutput ?? false),
                                        hasInput: d.isInput || (k[d.uid]?.hasInput ?? false), isAirPods: d.isAirPods)
            if k[d.uid] != info { k[d.uid] = info; changed = true }
            if d.isOutput, !out.contains(d.uid) { insertNew(d.uid, into: &out, builtIn: d.transport == .builtIn, known: k); changed = true }
            if d.isInput, !inn.contains(d.uid) { insertNew(d.uid, into: &inn, builtIn: d.transport == .builtIn, known: k); changed = true }
        }
        guard changed else { return }
        known = k; priorityOut = out; priorityIn = inn
        savePriority()
    }

    private func insertNew(_ uid: String, into list: inout [String], builtIn: Bool, known: [String: SoundKnownDevice]) {
        if builtIn { list.append(uid); return }
        let firstBuiltIn = list.firstIndex { known[$0]?.transport == SoundTransport.builtIn.rawValue }
        list.insert(uid, at: firstBuiltIn ?? list.endIndex)
    }

    private func savePriority() {
        let d = UserDefaults.standard
        d.set(priorityOut, forKey: SoundSettings.priorityOutKey)
        d.set(priorityIn, forKey: SoundSettings.priorityInKey)
        if let data = try? JSONEncoder().encode(known) { d.set(data, forKey: SoundSettings.knownKey) }
    }

    func priorityEntries(_ scope: SoundScope) -> [SoundPriorityEntry] {
        (scope == .output ? priorityOut : priorityIn).compactMap { uid in
            let live = devices.first { $0.uid == uid && (scope == .output ? $0.isOutput : $0.isInput) }
            if let live {
                return SoundPriorityEntry(uid: uid, name: live.name, transport: live.transport, connected: true, symbol: live.symbol(for: scope))
            }
            guard let k = known[uid] else { return nil }
            let t = SoundTransport(rawValue: k.transport) ?? .other
            var ghost = SoundDevice(id: 0, uid: uid, name: k.name, transport: t)
            ghost.outChannels = 1; ghost.inChannels = 1
            return SoundPriorityEntry(uid: uid, name: k.name, transport: t, connected: false, symbol: ghost.symbol(for: scope))
        }
    }

    /// Put `uid` where `target` is now (drag and drop).
    func movePriority(_ scope: SoundScope, uid: String, to target: String) {
        var list = scope == .output ? priorityOut : priorityIn
        guard uid != target, let from = list.firstIndex(of: uid), let to = list.firstIndex(of: target) else { return }
        list.remove(at: from)
        list.insert(uid, at: to)
        setPriority(scope, list)
    }

    func nudgePriority(_ scope: SoundScope, uid: String, by delta: Int) {
        var list = scope == .output ? priorityOut : priorityIn
        guard let i = list.firstIndex(of: uid) else { return }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        setPriority(scope, list)
    }

    func forget(_ scope: SoundScope, uid: String) {
        guard !devices.contains(where: { $0.uid == uid }) else { return }
        var list = scope == .output ? priorityOut : priorityIn
        list.removeAll { $0 == uid }
        setPriority(scope, list)
        if !priorityOut.contains(uid), !priorityIn.contains(uid) { known[uid] = nil; savePriority() }
    }

    private func setPriority(_ scope: SoundScope, _ list: [String]) {
        if scope == .output { priorityOut = list } else { priorityIn = list }
        savePriority()
    }

    // MARK: Auto-switch

    private func scheduleEnforce(output: Bool, input: Bool) {
        enforceTask?.cancel()
        enforceTask = Task { @MainActor in
            // macOS often makes its own switch a moment after a device appears; wait, then enforce twice.
            for delay in [0.7, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                self.enforcePriority(output: output, input: input)
            }
        }
    }

    func enforcePriority(output: Bool, input: Bool) {
        guard SoundSettings.autoSwitch, loaded else { return }
        if output, let best = bestDevice(.output), best.id != defaultOutputID {
            let name = best.displayName
            selectOutput(best)
            showNotice("Switched output to \(name) (priority).")
        }
        if input, let best = bestDevice(.input), best.id != defaultInputID {
            let name = best.displayName
            selectInput(best)
            showNotice("Switched input to \(name) (priority).")
        }
    }

    /// Highest-priority connected device, or nil when none qualifies.
    func bestDevice(_ scope: SoundScope) -> SoundDevice? {
        let order = scope == .output ? priorityOut : priorityIn
        let skipBT = scope == .input && SoundSettings.neverBTInput
        for uid in order {
            guard let d = devices.first(where: { $0.uid == uid }) else { continue }
            if scope == .output ? !d.isOutput : !d.isInput { continue }
            if skipBT, d.transport == .bluetooth { continue }
            return d
        }
        return nil
    }
}
