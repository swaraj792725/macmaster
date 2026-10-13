import SwiftUI
import AppKit

/// Records one key combination using a local key-down monitor.
@MainActor
final class MouseShortcutRecorderModel: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func start(_ onCapture: @escaping (MouseShortcut) -> Void) {
        stop()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc cancels
                self.stop()
                return nil
            }
            let flags = UInt64(event.modifierFlags.rawValue) & MouseShortcut.modifierMask
            let shortcut = MouseShortcut(keyCode: event.keyCode, flags: flags, label: Self.label(for: event))
            onCapture(shortcut)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    private static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

struct MouseShortcutField: View {
    @Binding var shortcut: MouseShortcut?
    @StateObject private var recorder = MouseShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if recorder.recording { recorder.stop() } else { recorder.start { shortcut = $0 } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: recorder.recording ? "keyboard.badge.ellipsis" : "keyboard")
                    Text(recorder.recording ? "Press keys… (Esc to cancel)" : (shortcut?.display ?? "Click to record"))
                        .monospacedDigit()
                }
                .frame(minWidth: 170)
            }
            .buttonStyle(.bordered)
            .tint(recorder.recording ? .accentColor : nil)
            if shortcut != nil {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .onDisappear { recorder.stop() }
    }
}

/// Action picker with the extra inputs some actions need (shortcut recorder, app chooser, URL field).
struct MouseActionEditor: View {
    let title: String
    @Binding var action: MouseAction
    var allowed: [MouseActionKind] = MouseActionKind.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: $action.kind) {
                    ForEach(allowed) { k in
                        Label(k.title, systemImage: k.symbol).tag(k)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
            }
            switch action.kind {
            case .shortcut:
                HStack { Spacer().frame(width: 110); MouseShortcutField(shortcut: $action.shortcut) }
            case .openApp:
                HStack {
                    Spacer().frame(width: 110)
                    Text(action.summary).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") { chooseApp() }
                }
            case .openURL:
                HStack {
                    Spacer().frame(width: 110)
                    TextField("https://example.com", text: $action.target)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
            default:
                EmptyView()
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { action.target = url.path }
    }
}
