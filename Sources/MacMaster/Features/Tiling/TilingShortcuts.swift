import AppKit
import Carbon.HIToolbox
import Observation

// MARK: - Shortcut value

struct TilingShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    var modifiers: UInt32

    static let ctrlOpt = UInt32(controlKey | optionKey)
    static let ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)
    static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 36: "↩", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]
}

// MARK: - Store

@MainActor @Observable
final class TilingShortcutStore {
    static let shared = TilingShortcutStore()

    private struct Saved: Codable {
        var overrides: [String: TilingShortcut] = [:]
        var cleared: [String] = []
    }

    private(set) var overrides: [String: TilingShortcut]
    private(set) var cleared: Set<String>
    /// Layouts whose hotkey could not be registered (already taken by another app).
    var conflicts: Set<String> = []
    @ObservationIgnored var onChange: (() -> Void)?

    /// Layouts shown in the shortcut list, in display order.
    static let listed: [TilingLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .maximize, .almostMaximize, .center, .restore,
        .previousDisplay, .nextDisplay, .shrink, .grow,
    ]

    private init() {
        var saved = Saved()
        if let data = UserDefaults.standard.data(forKey: TilingSettings.Key.shortcuts),
           let s = try? JSONDecoder().decode(Saved.self, from: data) { saved = s }
        overrides = saved.overrides
        cleared = Set(saved.cleared)
    }

    static func defaultShortcut(for l: TilingLayout) -> TilingShortcut? {
        let co = TilingShortcut.ctrlOpt
        switch l {
        case .leftHalf: return .init(keyCode: 123, modifiers: co)
        case .rightHalf: return .init(keyCode: 124, modifiers: co)
        case .topHalf: return .init(keyCode: 126, modifiers: co)
        case .bottomHalf: return .init(keyCode: 125, modifiers: co)
        case .topLeft: return .init(keyCode: 32, modifiers: co)
        case .topRight: return .init(keyCode: 34, modifiers: co)
        case .bottomLeft: return .init(keyCode: 38, modifiers: co)
        case .bottomRight: return .init(keyCode: 40, modifiers: co)
        case .leftThird: return .init(keyCode: 2, modifiers: co)
        case .centerThird: return .init(keyCode: 3, modifiers: co)
        case .rightThird: return .init(keyCode: 5, modifiers: co)
        case .leftTwoThirds: return .init(keyCode: 14, modifiers: co)
        case .rightTwoThirds: return .init(keyCode: 17, modifiers: co)
        case .maximize: return .init(keyCode: 36, modifiers: co)
        case .almostMaximize: return .init(keyCode: 36, modifiers: TilingShortcut.ctrlOptShift)
        case .center: return .init(keyCode: 8, modifiers: co)
        case .restore: return .init(keyCode: 51, modifiers: co)
        case .previousDisplay: return .init(keyCode: 123, modifiers: TilingShortcut.ctrlOptCmd)
        case .nextDisplay: return .init(keyCode: 124, modifiers: TilingShortcut.ctrlOptCmd)
        case .shrink: return .init(keyCode: 27, modifiers: co)
        case .grow: return .init(keyCode: 24, modifiers: co)
        }
    }

    func shortcut(for l: TilingLayout) -> TilingShortcut? {
        if cleared.contains(l.rawValue) { return nil }
        return overrides[l.rawValue] ?? Self.defaultShortcut(for: l)
    }

    var isCustomized: Bool { !overrides.isEmpty || !cleared.isEmpty }

    func set(_ s: TilingShortcut, for l: TilingLayout) {
        // A key combo can only drive one action.
        for other in Self.listed where other != l && shortcut(for: other) == s { clear(other, notify: false) }
        overrides[l.rawValue] = s
        cleared.remove(l.rawValue)
        commit()
    }

    func clear(_ l: TilingLayout, notify: Bool = true) {
        overrides[l.rawValue] = nil
        cleared.insert(l.rawValue)
        if notify { commit() }
    }

    func reset() {
        overrides = [:]
        cleared = []
        commit()
    }

    private func commit() {
        let saved = Saved(overrides: overrides, cleared: Array(cleared))
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: TilingSettings.Key.shortcuts) }
        onChange?()
    }
}

// MARK: - Carbon hotkeys

private let tilingHotkeySignature: OSType = 0x544C_4E47 // 'TLNG'

private let tilingHotkeyHandler: EventHandlerUPP = { _, event, _ in
    var hk = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    // Only consume our own hot keys so other features' Carbon hot keys keep working.
    guard st == noErr, hk.signature == tilingHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hk.id
    DispatchQueue.main.async { MainActor.assumeIsolated { TilingHotkeys.shared.fire(id) } }
    return noErr
}

/// Global hotkeys through Carbon `RegisterEventHotKey` (no permission needed).
@MainActor
final class TilingHotkeys {
    static let shared = TilingHotkeys()

    private var refs: [EventHotKeyRef] = []
    private var idMap: [UInt32: TilingLayout] = [:]
    private var handlerRef: EventHandlerRef?
    private(set) var paused = false

    func register() {
        unregister()
        let store = TilingShortcutStore.shared
        store.conflicts = []
        guard TilingSettings.enabled, TilingSettings.hotkeysEnabled, !paused else { return }
        installHandler()
        for (i, layout) in TilingShortcutStore.listed.enumerated() {
            guard let sc = store.shortcut(for: layout) else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: tilingHotkeySignature, id: id)
            let st = RegisterEventHotKey(sc.keyCode, sc.modifiers, hid, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs.append(ref)
                idMap[id] = layout
            } else {
                store.conflicts.insert(layout.rawValue)
            }
        }
    }

    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        idMap = [:]
    }

    /// Suspend while a recorder is capturing keys (hotkeys would otherwise swallow them).
    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        if p { unregister() } else { register() }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let layout = idMap[id] else { return }
        TilingEngine.shared.apply(layout)
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), tilingHotkeyHandler, 1, &spec, nil, &handlerRef)
    }
}
