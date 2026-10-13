import SwiftUI

enum KeyboardTab: String, CaseIterable, Identifiable {
    case hyper, shortcuts, corners, extras
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hyper: "Hyper Key"
        case .shortcuts: "App Shortcuts"
        case .corners: "Hot Corners"
        case .extras: "Extras"
        }
    }
}

/// Root screen: Keyboard & Shortcuts.
struct KeyboardView: View {
    @State private var tab: KeyboardTab = .hyper
    private let engine = KeyboardEngine.shared

    var body: some View {
        Page {
            PageHeader(title: "Keyboard & Shortcuts",
                       subtitle: "Hyper key, app shortcuts, hot corners and extras",
                       symbol: "keyboard.fill", colors: Theme.Palette.indigo) {
                Picker("Section", selection: $tab) {
                    ForEach(KeyboardTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420)
            }
            Group {
                switch tab {
                case .hyper: KeyboardHyperTab()
                case .shortcuts: KeyboardShortcutsTab()
                case .corners: KeyboardCornersTab()
                case .extras: KeyboardExtrasTab()
                }
            }
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: tab)
        .searchTab($tab)
        .onAppear { engine.start() }
    }
}

// MARK: - Shared bits

struct KeyboardKeyCap: View {
    let text: String
    var wide = false

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .frame(width: wide ? 96 : 46, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardFill)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct KeyboardToggleHeader: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    var pill: (String, Color)? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, colors: colors, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let pill { StatusPill(text: pill.0, color: pill.1) }
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .card()
    }
}

// MARK: - Hyper Key tab

struct KeyboardHyperTab: View {
    @AppStorage(KeyboardPrefs.hyperEnabled) private var enabled = false
    @AppStorage(KeyboardPrefs.hyperKey) private var keyRaw = KeyboardHyperKey.caps.rawValue
    @AppStorage(KeyboardPrefs.hyperTapEscape) private var tapEscape = true
    @State private var testCombo: KeyboardCombo?
    private let engine = KeyboardEngine.shared

    private var key: KeyboardHyperKey { KeyboardHyperKey(rawValue: keyRaw) ?? .caps }

    private var pill: (String, Color) {
        if !enabled { return ("Off", .secondary) }
        if !engine.accessibilityGranted { return ("Needs Accessibility", Color(hex: 0xFF9F0A)) }
        return engine.tapRunning ? ("Active", Color(hex: 0x30D158)) : ("Starting…", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PermissionBanner(permission: .accessibility,
                             reason: "The Hyper key needs an event tap to turn Caps Lock into ⌃⌥⇧⌘ for other keys.")

            KeyboardToggleHeader(symbol: "capslock.fill", colors: Theme.Palette.indigo, title: "Hyper Key",
                                 detail: "Turn a rarely used key into ⌃⌥⇧⌘ pressed together. Tap it alone for Escape.",
                                 pill: pill, isOn: $enabled)

            HStack(spacing: 10) {
                Spacer()
                KeyboardKeyCap(text: "⌃"); KeyboardKeyCap(text: "⌥"); KeyboardKeyCap(text: "⇧"); KeyboardKeyCap(text: "⌘")
                Image(systemName: "equal").foregroundStyle(.secondary).padding(.horizontal, 4)
                KeyboardKeyCap(text: key.title, wide: true)
                Spacer()
            }
            .padding(.vertical, 6)

            GroupedSection("Options",
                           footer: key == .caps
                           ? "Caps Lock is remapped to F18 with hidutil and your previous key mapping is restored when you turn this off or quit MacMaster."
                           : "Right ⌘ / ⌥ stay as normal modifiers but also add the other three while held, so they act as Hyper for other keys.") {
                SettingsRow(title: "Hyper key", subtitle: "Which key becomes Hyper", symbol: "keyboard",
                            colors: Theme.Palette.indigo) {
                    Picker("Hyper key", selection: $keyRaw) {
                        ForEach(KeyboardHyperKey.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                if key == .caps {
                    SettingsRow(title: "Tap alone sends Escape", subtitle: "A quick press with no other key acts as Esc",
                                symbol: "escape", colors: Theme.Palette.orange) {
                        Toggle("Tap alone sends Escape", isOn: $tapEscape).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            GroupedSection("Try it", footer: "Click the field, then press Hyper plus any key. Hyper combinations show as ✦.") {
                SettingsRow(title: "Test your Hyper key", symbol: "checkmark.circle.fill", colors: Theme.Palette.green) {
                    KeyboardRecorderField(combo: $testCombo, requireModifier: false)
                }
            }
        }
    }
}
