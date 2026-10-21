import AppKit
import Carbon.HIToolbox
import SwiftUI

private let globalHotKeySignature: OSType = 0x4D4D474B // "MMGK"

private let globalHotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr, hk.signature == globalHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hk.id, pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKeys.shared.fire(id, pressed: pressed) } }
    return noErr
}

/// Named global hot keys shared by every feature (Carbon `RegisterEventHotKey`, no permission needed).
/// Register under a stable name such as "capture.ocr"; registering the same name again replaces it.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private struct Entry { var ref: EventHotKeyRef; var id: UInt32; var combo: KeyboardCombo
        var press: () -> Void; var release: (() -> Void)? }
    private var entries: [String: Entry] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Registers `combo` under `name`. `release` (optional) fires when the keys are let go, for push-to-talk.
    /// Returns false when macOS or another app already owns the combo. Pass nil to just unregister.
    @discardableResult
    func register(_ name: String, combo: KeyboardCombo?, press: @escaping () -> Void, release: (() -> Void)? = nil) -> Bool {
        unregister(name)
        guard let combo else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = nextID; nextID += 1
        let st = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: globalHotKeySignature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else { return false }
        entries[name] = Entry(ref: ref, id: id, combo: combo, press: press, release: release)
        return true
    }

    /// Registers the combo saved under `defaultsKey` (see `HotKeyField`).
    @discardableResult
    func register(_ name: String, defaultsKey: String, press: @escaping () -> Void, release: (() -> Void)? = nil) -> Bool {
        register(name, combo: StoredHotKey.load(defaultsKey), press: press, release: release)
    }

    func unregister(_ name: String) {
        if let e = entries.removeValue(forKey: name) { UnregisterEventHotKey(e.ref) }
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }

    private func installHandler() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), globalHotKeyHandler, 2, &specs, nil, &handler)
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        guard let e = entries.values.first(where: { $0.id == id }) else { return }
        if pressed { e.press() } else { e.release?() }
    }
}

/// A `KeyboardCombo` saved as JSON in UserDefaults.
enum StoredHotKey {
    static func load(_ key: String) -> KeyboardCombo? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyboardCombo.self, from: $0) }
    }
    static func save(_ combo: KeyboardCombo?, _ key: String) {
        if let combo, let d = try? JSONEncoder().encode(combo) { UserDefaults.standard.set(d, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// Click-to-record shortcut saved under `defaultsKey`. `onChange` runs after each change (re-register there).
struct HotKeyField: View {
    let defaultsKey: String
    var requireModifier = true
    var onChange: (KeyboardCombo?) -> Void = { _ in }
    @State private var combo: KeyboardCombo?

    var body: some View {
        KeyboardRecorderField(combo: Binding(get: { combo }, set: { new in
            combo = new
            StoredHotKey.save(new, defaultsKey)
            onChange(new)
        }), requireModifier: requireModifier)
        .onAppear { combo = StoredHotKey.load(defaultsKey) }
    }
}
