import AppKit
import Carbon.HIToolbox

private let keyboardHotkeySignature: OSType = 0x4D4D4B48 // "MMKH"

private let keyboardHotkeyHandler: EventHandlerUPP = { _, event, _ in
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    if status == noErr, hk.signature == keyboardHotkeySignature {
        let id = hk.id
        DispatchQueue.main.async { MainActor.assumeIsolated { KeyboardHotkeys.shared.fire(id) } }
    }
    return noErr
}

/// Global hotkeys through Carbon `RegisterEventHotKey` (no Accessibility needed).
@MainActor
final class KeyboardHotkeys {
    static let shared = KeyboardHotkeys()

    private var refs: [EventHotKeyRef] = []
    private var idMap: [UInt32: UUID] = [:]
    private var handler: EventHandlerRef?
    private var registered: [KeyboardAppShortcut] = []

    /// Shortcuts whose combo could not be registered (already taken by the system or another app).
    private(set) var failures: Set<UUID> = []

    func sync(_ shortcuts: [KeyboardAppShortcut]) {
        let active = shortcuts.filter { $0.enabled && $0.combo != nil }
        if active == registered, handler != nil || active.isEmpty { return }
        unregisterAll()
        registered = active
        guard !active.isEmpty else { return }
        installHandler()
        var next: UInt32 = 1
        var seen: [KeyboardCombo: UUID] = [:]
        for s in active {
            guard let combo = s.combo else { continue }
            if seen[combo] != nil { failures.insert(s.id); continue } // duplicate of an earlier shortcut
            seen[combo] = s.id
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: keyboardHotkeySignature, id: next)
            let st = RegisterEventHotKey(combo.keyCode, combo.modifiers, hid, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs.append(ref)
                idMap[next] = s.id
                next += 1
            } else {
                failures.insert(s.id)
            }
        }
    }

    func stop() {
        unregisterAll()
        registered = []
    }

    private func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        idMap = [:]
        failures = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), keyboardHotkeyHandler, 1, &spec, nil, &handler)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let uuid = idMap[id], let s = KeyboardStore.shared.shortcuts.first(where: { $0.id == uuid }) else { return }
        KeyboardSystemActions.perform(s)
    }
}
