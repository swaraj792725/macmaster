import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Registers one global hot key with Carbon `RegisterEventHotKey` (no permission needed).
@MainActor
final class MenuBarManagerHotKeyCenter {
    static let shared = MenuBarManagerHotKeyCenter()

    nonisolated private static let signature: OSType = 0x4D4D424D // 'MMBM'
    nonisolated private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onFire: (() -> Void)?

    /// Install (or replace) the hot key. Pass nil to unregister.
    @discardableResult
    func register(_ key: MenuBarManagerHotKey?) -> Bool {
        unregister()
        guard let key else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            // Only consume our own hot key so other features' Carbon hot keys keep working.
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == MenuBarManagerHotKeyCenter.signature,
                  hk.id == MenuBarManagerHotKeyCenter.hotKeyID else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in MenuBarManagerHotKeyCenter.shared.onFire?() }
            return noErr
        }, 1, &spec, nil, &ref)
        if status == noErr { handlerRef = ref }
    }
}

// MARK: - Recorder

/// Records one key combination using a local key-down monitor (swallows keys while recording).
@MainActor
@Observable
final class MenuBarManagerRecorder {
    var isRecording = false
    var hint = ""
    private var monitor: Any?
    private var onCapture: ((MenuBarManagerHotKey) -> Void)?

    func start(onCapture: @escaping (MenuBarManagerHotKey) -> Void) {
        stop()
        self.onCapture = onCapture
        isRecording = true
        hint = "Press a shortcut with ⌃ ⌥ or ⌘"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        isRecording = false
        onCapture = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { stop(); return true } // Esc cancels
        let mods = MenuBarManagerHotKey.carbonModifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let strong = mods & (MenuBarManagerHotKey.cmd | MenuBarManagerHotKey.control | MenuBarManagerHotKey.option)
        guard strong != 0 else {
            hint = "Include ⌃, ⌥ or ⌘"
            return true
        }
        let cb = onCapture
        stop()
        cb?(MenuBarManagerHotKey(keyCode: UInt32(event.keyCode), modifiers: mods))
        return true
    }

}

/// Small shortcut recorder control.
struct MenuBarManagerHotKeyField: View {
    @Binding var hotKey: MenuBarManagerHotKey
    @State private var recorder = MenuBarManagerRecorder()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if recorder.isRecording { recorder.stop() }
                else { recorder.start { hotKey = $0 } }
            } label: {
                Text(recorder.isRecording ? recorder.hint : hotKey.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 118)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(recorder.isRecording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recorder.isRecording ? Color.accentColor : Theme.hairline,
                                          lineWidth: recorder.isRecording ? 1.5 : 1))
            }
            .buttonStyle(.plain)
            .animation(.smooth(duration: 0.15), value: recorder.isRecording)
            if hotKey != .default {
                Button("Reset") { hotKey = .default }.buttonStyle(.mmGhost)
            }
        }
        .onDisappear { recorder.stop() }
    }
}
