import SwiftUI
import AppKit

/// Records one key combination with a local key monitor (our own recorder; nothing is logged).
@MainActor
final class KeyboardRecorderModel: ObservableObject {
    @Published var recording = false
    @Published var live = ""
    private var monitor: Any?

    func start(requireModifier: Bool, onCapture: @escaping (KeyboardCombo) -> Void) {
        stop()
        recording = true
        live = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let mods = KeyboardMods.carbon(from: event.modifierFlags)
            if event.type == .flagsChanged {
                self.live = KeyboardMods.glyphs(mods)
                return nil
            }
            if event.keyCode == 53, mods == 0 { self.stop(); return nil } // Esc cancels
            let code = Int(event.keyCode)
            if requireModifier, mods == 0, !KeyboardKeyNames.isFunctionKey(code) { NSSound.beep(); return nil }
            var label = KeyboardKeyNames.label(for: code)
            if label.isEmpty { label = (event.charactersIgnoringModifiers ?? "?").uppercased() }
            onCapture(KeyboardCombo(keyCode: UInt32(event.keyCode), modifiers: mods, label: label))
            self.stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        live = ""
    }
}

/// Click-to-record field showing the current combo (hyper combos render as "✦ K").
struct KeyboardRecorderField: View {
    @Binding var combo: KeyboardCombo?
    var requireModifier = true
    var minWidth: CGFloat = 150
    @StateObject private var recorder = KeyboardRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if recorder.recording { recorder.stop() }
                else { recorder.start(requireModifier: requireModifier) { combo = $0 } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: recorder.recording ? "keyboard.badge.ellipsis" : "keyboard")
                    Text(label).monospacedDigit().lineLimit(1)
                }
                .frame(minWidth: minWidth)
            }
            .buttonStyle(.mmSecondary(tint: recorder.recording ? .accentColor : .primary))
            if combo != nil {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear shortcut")
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.recording { return recorder.live.isEmpty ? "Press keys… (Esc cancels)" : recorder.live }
        return combo?.display ?? "Record Shortcut"
    }
}
