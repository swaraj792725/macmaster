import SwiftUI

struct KeyboardExtrasTab: View {
    @AppStorage(KeyboardPrefs.snippetsEnabled) private var snippetsOn = false
    @AppStorage(KeyboardPrefs.visualizerEnabled) private var vizOn = false
    @AppStorage(KeyboardPrefs.cmdQGuard) private var cmdQ = false
    @AppStorage(KeyboardPrefs.cleaningDuration) private var cleaningSeconds = 60
    @State private var editing: KeyboardSnippet?
    @State private var editingIsNew = false
    @State private var cleaningFailed = false
    private let store = KeyboardStore.shared
    private let engine = KeyboardEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PermissionBanner(permission: .accessibility,
                             reason: "Cleaning mode, text expansion, the key visualizer and the ⌘Q guard all use an event tap.")
            cleaningCard.searchAnchor("kbd.cleaning")
            snippetsSection.searchAnchor("kbd.snippets")
            GroupedSection("Presentation & safety",
                           footer: "The visualizer shows keys only on screen; nothing is stored. It stays off while a password field has focus.") {
                SettingsRow(title: "Key press visualizer", subtitle: "Show pressed keys in a glass pill at the bottom of the screen",
                            symbol: "keyboard.badge.eye", colors: Theme.Palette.teal) {
                    HStack(spacing: 10) {
                        Button("Preview") { engine.previewVisualizer() }.buttonStyle(.mmSecondary)
                        Toggle("Key press visualizer", isOn: $vizOn).labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingsRow(title: "Hold ⌘Q to quit", subtitle: "A single tap only shows “Hold ⌘Q to quit”; hold for 0.6 s to really quit",
                            symbol: "power", colors: Theme.Palette.red) {
                    Toggle("Hold ⌘Q to quit", isOn: $cmdQ).labelsHidden().toggleStyle(.switch)
                }
            }
            .searchAnchor("kbd.viz")
        }
        .sheet(item: $editing) { s in
            KeyboardSnippetEditor(draft: s, isNew: editingIsNew) { saved in
                if let i = store.snippets.firstIndex(where: { $0.id == saved.id }) { store.snippets[i] = saved }
                else { store.snippets.append(saved) }
            }
        }
        .alert("Couldn't start cleaning mode", isPresented: $cleaningFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Grant Accessibility access to MacMaster first, then try again.")
        }
    }

    // MARK: Cleaning

    private var cleaningCard: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "sparkles", colors: Theme.Palette.mint, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleaning Mode").font(.headline)
                Text("Locks the keyboard, mouse and trackpad so you can wipe them. Ends after the timer, or hold ⌘⌥⌃ for 3 seconds.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("Duration", selection: $cleaningSeconds) {
                Text("30 s").tag(30); Text("60 s").tag(60); Text("2 min").tag(120); Text("3 min").tag(180)
                Divider()
                Text("Until ⌘⌥⌃ held").tag(0)
            }
            .labelsHidden().fixedSize()
            if engine.cleaningActive {
                StatusPill(text: "Active", color: Color(hex: 0x30D158))
            } else {
                Button("Start") {
                    if !engine.startCleaning(seconds: cleaningSeconds) { cleaningFailed = true }
                }
                .buttonStyle(.mmPrimary)
            }
        }
        .card()
    }

    // MARK: Snippets

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            KeyboardToggleHeader(symbol: "text.append", colors: Theme.Palette.blue, title: "Text Expansion",
                                 detail: "Type a trigger such as ;sig and it is replaced by your text. Supports {date}, {time} and {clipboard}.",
                                 pill: snippetsOn ? ("On", Color(hex: 0x30D158)) : ("Off", .secondary), isOn: $snippetsOn)

            if store.snippets.isEmpty {
                GroupedSection {
                    SettingsRow(title: "No snippets yet", subtitle: "Add one, then switch Text Expansion on.") {
                        Button("Add Snippet") { newSnippet() }.buttonStyle(.mmPrimary)
                    }
                }
            } else {
                GroupedSection("Snippets",
                               footer: "Only the last ~32 typed characters are kept in memory to detect triggers; nothing is logged or saved. Disabled in secure input (password fields). Your clipboard is restored after each expansion.") {
                    ForEach(store.snippets) { s in
                        HStack(spacing: 12) {
                            Text(s.trigger).font(.system(.callout, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(s.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Toggle("Enabled", isOn: enabledBinding(s.id)).labelsHidden().toggleStyle(.switch)
                            Button { editingIsNew = false; editing = s } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            Button { store.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 28)
                    }
                    HStack {
                        Button { newSnippet() } label: { Label("Add Snippet", systemImage: "plus") }.buttonStyle(.mmGhost)
                        Spacer()
                    }
                }
            }
        }
    }

    private func newSnippet() {
        editingIsNew = true
        editing = KeyboardSnippet(trigger: ";", text: "")
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.snippets.first { $0.id == id }?.enabled ?? false },
                set: { v in if let i = store.snippets.firstIndex(where: { $0.id == id }) { store.snippets[i].enabled = v } })
    }
}

struct KeyboardSnippetEditor: View {
    @State var draft: KeyboardSnippet
    let isNew: Bool
    let onSave: (KeyboardSnippet) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool { draft.trigger.count >= 2 && !draft.text.isEmpty && !draft.trigger.contains(" ") }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.title3.weight(.semibold))
            GroupedSection(footer: "Triggers need at least 2 characters and no spaces. Starting with ; or / avoids accidental expansion.") {
                SettingsRow(title: "Trigger") {
                    TextField(";sig", text: $draft.trigger)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 200)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Expands to").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: $draft.text)
                    .font(.body)
                    .frame(height: 140)
                    .padding(6)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.mmSecondary)
                Button("Save") { onSave(draft); dismiss() }.buttonStyle(.mmPrimary).disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
