import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct KeyboardShortcutsTab: View {
    private let store = KeyboardStore.shared
    private let engine = KeyboardEngine.shared
    @State private var editing: KeyboardEditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(spacing: 12) {
                IconTile(symbol: "command.square.fill", colors: Theme.Palette.blue, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global shortcuts").font(.headline)
                    Text("Launch or focus an app, open folders and links, run commands. Press again to hide the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { pickApp() } label: { Label("Pick App…", systemImage: "app.badge") }
                    .buttonStyle(.mmPrimary)
                Menu {
                    ForEach(KeyboardShortcutKind.allCases.filter { $0 != .app }) { kind in
                        Button { editing = KeyboardEditTarget(shortcut: KeyboardAppShortcut(name: kind.title, kind: kind), isNew: true) } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .menuStyle(.button).fixedSize()
            }
            .card()

            if store.shortcuts.isEmpty {
                EmptyStateView(symbol: "command", title: "No shortcuts yet",
                               message: "Pick an app, record a key combination and it works from anywhere. Hyper combos like ✦ T are great for this.")
                    .card()
            } else {
                GroupedSection("Shortcuts",
                               footer: "Combos already used by macOS or another app can't be registered and show “In use”.") {
                    ForEach(store.shortcuts) { s in
                        KeyboardShortcutRow(shortcut: binding(for: s.id),
                                            conflict: engine.hotkeyFailures.contains(s.id),
                                            onEdit: { editing = KeyboardEditTarget(shortcut: s, isNew: false) },
                                            onDelete: { store.shortcuts.removeAll { $0.id == s.id } })
                    }
                }
            }

            Text("Shortcuts work without Accessibility. Cycling windows and some system actions need it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { target in
            KeyboardShortcutEditor(draft: target.shortcut, isNew: target.isNew) { saved in
                if let i = store.shortcuts.firstIndex(where: { $0.id == saved.id }) { store.shortcuts[i] = saved }
                else { store.shortcuts.append(saved) }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<KeyboardAppShortcut> {
        Binding(
            get: { store.shortcuts.first { $0.id == id } ?? KeyboardAppShortcut(name: "", kind: .app) },
            set: { new in if let i = store.shortcuts.firstIndex(where: { $0.id == id }) { store.shortcuts[i] = new } })
    }

    private func pickApp() {
        guard let path = KeyboardPickers.chooseApp() else { return }
        let name = KeyboardPickers.appName(path)
        var s = KeyboardAppShortcut(name: name, kind: .app, target: path)
        s.bundleID = KeyboardSystemActions.bundleID(ofAppAt: path)
        store.shortcuts.append(s)
    }
}

struct KeyboardEditTarget: Identifiable {
    let id = UUID()
    var shortcut: KeyboardAppShortcut
    var isNew: Bool
}

// MARK: - Pickers

enum KeyboardPickers {
    @MainActor
    static func chooseApp() -> String? {
        let p = NSOpenPanel()
        p.title = "Choose an App"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        return p.runModal() == .OK ? p.url?.path : nil
    }

    @MainActor
    static func chooseFolder() -> String? {
        let p = NSOpenPanel()
        p.title = "Choose a Folder"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url?.path : nil
    }

    static func appName(_ path: String) -> String {
        let b = Bundle(url: URL(fileURLWithPath: path))
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: - Row

private struct KeyboardShortcutRow: View {
    @Binding var shortcut: KeyboardAppShortcut
    let conflict: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(shortcut.name.isEmpty ? shortcut.kind.title : shortcut.name).font(.body)
                    if conflict { StatusPill(text: "In use", color: Color(hex: 0xFF9F0A)) }
                }
                Text(shortcut.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            KeyboardRecorderField(combo: $shortcut.combo, minWidth: 110)
            Toggle("Enabled", isOn: $shortcut.enabled).labelsHidden().toggleStyle(.switch)
            Menu {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder private var icon: some View {
        if shortcut.kind == .app, !shortcut.target.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile: shortcut.target))
                .resizable().frame(width: 28, height: 28)
        } else {
            IconTile(symbol: shortcut.kind.symbol, colors: shortcut.kind.colors, size: 28)
        }
    }
}

// MARK: - Editor sheet

struct KeyboardShortcutEditor: View {
    @State var draft: KeyboardAppShortcut
    let isNew: Bool
    let onSave: (KeyboardAppShortcut) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        draft.kind.needsTarget ? !draft.target.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(spacing: 12) {
                IconTile(symbol: draft.kind.symbol, colors: draft.kind.colors, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isNew ? "New Shortcut" : "Edit Shortcut").font(.title3.weight(.semibold))
                    Text(draft.kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupedSection {
                SettingsRow(title: "Name") {
                    TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                switch draft.kind {
                case .app:
                    SettingsRow(title: "App", subtitle: draft.target.isEmpty ? "Choose from /Applications" : draft.summary) {
                        Button("Pick App…") {
                            if let p = KeyboardPickers.chooseApp() {
                                draft.target = p
                                draft.bundleID = KeyboardSystemActions.bundleID(ofAppAt: p)
                                if draft.name.isEmpty || draft.name == KeyboardShortcutKind.app.title { draft.name = KeyboardPickers.appName(p) }
                            }
                        }
                    }
                    SettingsRow(title: "If the app is already frontmost") {
                        Picker("", selection: $draft.frontmost) {
                            ForEach(KeyboardFrontmostBehavior.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                case .folder:
                    SettingsRow(title: "Folder", subtitle: draft.target.isEmpty ? "Not set" : draft.summary) {
                        Button("Choose…") { if let p = KeyboardPickers.chooseFolder() { draft.target = p } }
                    }
                case .url:
                    SettingsRow(title: "URL") {
                        TextField("https://example.com", text: $draft.target).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                case .shell:
                    SettingsRow(title: "Command") {
                        TextField("open -a Calculator", text: $draft.target)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 260)
                    }
                default:
                    EmptyView()
                }
                SettingsRow(title: "Shortcut") {
                    KeyboardRecorderField(combo: $draft.combo, minWidth: 140)
                }
            }

            if draft.kind == .shell {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF9F0A))
                    Text("This command runs as you, with your full user permissions and no confirmation each time. Only add commands you trust and understand.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color(hex: 0xFF9F0A).opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.mmSecondary)
                Button("Save") { onSave(draft); dismiss() }.buttonStyle(.mmPrimary).disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
