import SwiftUI
import AppKit

/// Notes tool: sidebar of notes, editor (or rendered checklist preview), and the floating-note controls.
struct ToolsNotesView: View {
    private let engine = NotesEngine.shared
    @State private var query = ""
    @State private var preview = false
    @State private var confirmDelete: String?
    @AppStorage(NotesPrefs.monospaced) private var mono = false
    @AppStorage(NotesPrefs.fontSize) private var fontSize = 14.0

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            editorArea
        }
        .onAppear { engine.ensureLoaded() }
        .onDisappear { engine.flush(); engine.pruneEmpty(except: nil) }
        .alert("Move this note to the Trash?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) { if let id = confirmDelete { engine.delete(id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("You can get it back from the Trash.") }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { engine.newNote(); preview = false } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.mmSecondary).help("New note")
            }
            .padding(10)
            let list = engine.sorted(matching: query)
            if list.isEmpty {
                Spacer()
                Text(query.isEmpty ? "No notes yet" : "No matches").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(list) { n in
                            NoteRow(note: n, selected: n.id == engine.currentID)
                                .onTapGesture { engine.select(n.id) }
                                .contextMenu {
                                    Button(n.pinned ? "Unpin" : "Pin") { engine.togglePin(n.id) }
                                    Button("Copy") { engine.copy(n.id) }
                                    Button("Export…") { engine.export(n.id) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { confirmDelete = n.id }
                                }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
            }
            Divider()
            floatingBar
        }
    }

    private var floatingBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Floating note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { NotesFloatingController.shared.toggle() } label: {
                    Label("Open floating", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.mmSecondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Shortcut").font(.caption).foregroundStyle(.secondary).fixedSize()
                HotKeyField(defaultsKey: NotesPrefs.hotkey) { _ in engine.registerHotKey() }
            }
            Text("Stays on top of every app and Space. The shortcut shows and hides it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: Editor

    @ViewBuilder
    private var editorArea: some View {
        if let note = engine.current {
            VStack(spacing: 0) {
                toolbar(note)
                Divider()
                Group {
                    if preview {
                        NotePreview(note: note)
                    } else {
                        NoteTextView(text: Binding(
                            get: { engine.note(note.id)?.text ?? "" },
                            set: { engine.setText(note.id, $0) }),
                            monospaced: mono, fontSize: fontSize, documentID: note.id)
                            .padding(.horizontal, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar(note)
            }
        } else {
            EmptyStateView(symbol: ToolsTool.notes.symbol, title: "No note selected", message: "Create a note to start writing.")
        }
    }

    private func toolbar(_ note: NoteItem) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $preview) {
                Text("Edit").tag(false)
                Text("Checklist view").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Spacer(minLength: 8)
            if !preview {
                Picker("", selection: $mono) {
                    Text("Aa").tag(false)
                    Text("Mono").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 100)
                .help("Regular or monospaced font")
                Stepper("", value: $fontSize, in: 10...28, step: 1).labelsHidden().help("Font size")
            }
            Button { engine.togglePin(note.id) } label: { Image(systemName: note.pinned ? "pin.fill" : "pin") }
                .help(note.pinned ? "Unpin" : "Pin to the top")
            Button { engine.copy(note.id); ToolsToastCenter.shared.show("Note copied") } label: { Image(systemName: "doc.on.doc") }
                .help("Copy note text")
            Button { engine.export(note.id) } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export as .md")
            Button { confirmDelete = note.id } label: { Image(systemName: "trash") }
                .help("Move to Trash")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func statusBar(_ note: NoteItem) -> some View {
        HStack(spacing: 10) {
            Text("\(note.wordCount) words · \(note.charCount) characters")
            Spacer(minLength: 0)
            if let e = engine.lastError {
                Text(e).foregroundStyle(.red).lineLimit(1)
            } else if !preview {
                Text("Cmd+Return toggles a checklist item").foregroundStyle(.tertiary)
            }
            Button("Show folder") { engine.revealFolder() }.buttonStyle(.borderless)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - Row

private struct NoteRow: View {
    let note: NoteItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.modified, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Text(note.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : (hover ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Rendered checklist view

private struct NotePreview: View {
    let note: NoteItem
    private let engine = NotesEngine.shared

    var body: some View {
        let lines = note.text.components(separatedBy: "\n")
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    row(i, line)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ i: Int, _ line: String) -> some View {
        if let c = ChecklistText.parse(line) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { engine.toggleLine(note.id, index: i) } label: {
                    Image(systemName: c.checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(c.checked ? Color.green : Color.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                inline(c.rest)
                    .strikethrough(c.checked)
                    .foregroundStyle(c.checked ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(c.indent.count) * 6)
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Color.clear.frame(height: 6)
        } else if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            inline(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
                .font(.system(size: max(14, 24 - CGFloat(level) * 3), weight: .bold))
                .padding(.top, 4)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }
}
