import Foundation
import AppKit
import Observation
import os

// MARK: - Model

struct NoteItem: Identifiable, Equatable {
    /// File name without ".md".
    let id: String
    var text: String
    var created: Date
    var modified: Date
    var pinned: Bool

    /// First meaningful line, without markdown markers.
    var title: String {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let f = line.first, f == "#" || f == ">" { line.removeFirst() }
            line = ChecklistText.stripMarker(line.trimmingCharacters(in: .whitespaces))
            if !line.isEmpty { return String(line.prefix(60)) }
        }
        return "New note"
    }

    /// First line after the title, for list previews.
    var snippet: String {
        var seenTitle = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = ChecklistText.stripMarker(raw.trimmingCharacters(in: .whitespaces))
            if line.isEmpty { continue }
            if !seenTitle { seenTitle = true; continue }
            return String(line.prefix(80))
        }
        return ""
    }

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    var charCount: Int { text.count }
}

// MARK: - Checklist helpers

enum ChecklistText {

    /// Removes a leading "- [ ] ", "- [x] " or bullet.
    static func stripMarker(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        for p in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "• "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return t
    }

    /// Checklist parse: (indent, isChecked, rest).
    static func parse(_ line: String) -> (indent: String, checked: Bool, rest: String)? {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let body = line.dropFirst(indent.count)
        if body.hasPrefix("- [ ] ") { return (indent, false, String(body.dropFirst(6))) }
        if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") { return (indent, true, String(body.dropFirst(6))) }
        if body == "- [ ]" { return (indent, false, "") }
        if body == "- [x]" || body == "- [X]" { return (indent, true, "") }
        return nil
    }

    /// "- [ ]" <-> "- [x]". A plain or bullet line becomes an unchecked item.
    static func toggled(_ line: String) -> String {
        if let p = parse(line) { return p.indent + (p.checked ? "- [ ] " : "- [x] ") + p.rest }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        var body = String(line.dropFirst(indent.count))
        for b in ["- ", "* ", "• "] where body.hasPrefix(b) { body.removeFirst(b.count); break }
        return indent + "- [ ] " + body
    }

    /// Prefix for the line after pressing Return on `line`, or nil if it isn't a list line.
    /// `empty` is true when the item has no text yet (Return then ends the list).
    static func continuation(of line: String) -> (prefix: String, empty: Bool)? {
        if let p = parse(line) { return (p.indent + "- [ ] ", p.rest.trimmingCharacters(in: .whitespaces).isEmpty) }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let body = line.dropFirst(indent.count)
        for b in ["- ", "* "] where body.hasPrefix(b) {
            return (indent + b, body.dropFirst(b.count).trimmingCharacters(in: .whitespaces).isEmpty)
        }
        return nil
    }
}

// MARK: - Preferences

enum NotesPrefs {
    static let hotkey = "mm.notes.hotkey"
    static let monospaced = "mm.notes.mono"
    static let fontSize = "mm.notes.fontSize"
    static let current = "mm.notes.current"
    static let pinned = "mm.notes.pinned"
}

// MARK: - Engine

/// Single source of truth for notes. Each note is a plain markdown file in
/// ~/Library/Application Support/MacMaster/Notes. The tool and the floating panel both edit through here.
@MainActor @Observable
final class NotesEngine {
    static let shared = NotesEngine()
    private static let log = Logger(subsystem: "com.macmaster.app", category: "notes")
    static let hotKeyName = "notes.floating"

    private(set) var notes: [NoteItem] = []
    private(set) var currentID: String?
    private(set) var loaded = false
    private(set) var lastError: String?
    private(set) var lastSaved: Date?

    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var diskStamp: [String: Date] = [:]

    private init() {}

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacMaster/Notes", isDirectory: true)
    }

    // MARK: Lifecycle

    /// Registers the floating-note hot key and the quit-time flush. Notes load lazily.
    func start() {
        guard !started else { return }
        started = true
        registerHotKey()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotesEngine.shared.flush() }
        }
    }

    func registerHotKey() {
        GlobalHotKeys.shared.register(Self.hotKeyName, defaultsKey: NotesPrefs.hotkey) {
            NotesFloatingController.shared.toggle()
        }
    }

    /// Reads the notes folder the first time it is needed; later calls pick up files changed outside MacMaster.
    func ensureLoaded() {
        if loaded { refreshFromDisk(); return }
        loaded = true
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { lastError = "Couldn't create the notes folder: \(error.localizedDescription)" }
        let pinned = Set(UserDefaults.standard.stringArray(forKey: NotesPrefs.pinned) ?? [])
        var result: [NoteItem] = []
        for url in markdownFiles() {
            if let n = read(url, pinned: pinned) { result.append(n) }
        }
        notes = result
        currentID = UserDefaults.standard.string(forKey: NotesPrefs.current)
        if currentID.flatMap({ id in notes.contains { $0.id == id } }) != true { currentID = sorted().first?.id }
        if notes.isEmpty { currentID = newNote() }
    }

    private func markdownFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }
    }

    private func read(_ url: URL, pinned: Set<String>) -> NoteItem? {
        let id = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 5_000_000 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let mod = v?.contentModificationDate ?? Date()
        diskStamp[id] = mod
        return NoteItem(id: id, text: text, created: v?.creationDate ?? mod, modified: mod, pinned: pinned.contains(id))
    }

    private func refreshFromDisk() {
        let pinned = Set(UserDefaults.standard.stringArray(forKey: NotesPrefs.pinned) ?? [])
        var seen = Set<String>()
        for url in markdownFiles() {
            let id = url.deletingPathExtension().lastPathComponent
            seen.insert(id)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let i = notes.firstIndex(where: { $0.id == id }) {
                if !dirty.contains(id), let mod, mod != diskStamp[id], let n = read(url, pinned: pinned) { notes[i] = n }
            } else if let n = read(url, pinned: pinned) {
                notes.append(n)
            }
        }
        notes.removeAll { !seen.contains($0.id) && !dirty.contains($0.id) && $0.id != currentID
            && FileManager.default.fileExists(atPath: fileURL($0.id).path) == false }
        if currentID.flatMap({ id in notes.contains { $0.id == id } }) != true { currentID = sorted().first?.id }
        if notes.isEmpty { currentID = newNote() }
    }

    // MARK: Queries

    func note(_ id: String?) -> NoteItem? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    var current: NoteItem? { note(currentID) }

    /// Pinned first, then most recently edited.
    func sorted(matching query: String = "") -> [NoteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = q.isEmpty ? notes : notes.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.modified > b.modified
        }
    }

    // MARK: Editing

    @discardableResult
    func newNote(text: String = "") -> String {
        loadIfNeeded()
        pruneEmpty(except: nil)
        let id = UUID().uuidString
        let now = Date()
        notes.append(NoteItem(id: id, text: text, created: now, modified: now, pinned: false))
        select(id)
        scheduleSave(id)
        return id
    }

    func select(_ id: String?) {
        guard id != currentID else { return }
        let previous = currentID
        currentID = id
        UserDefaults.standard.set(id, forKey: NotesPrefs.current)
        if let previous, let p = note(previous), p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !p.pinned {
            deleteFile(previous)
        }
    }

    func setText(_ id: String, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = Date()
        scheduleSave(id)
    }

    /// Toggles the checkbox on line `index` (rendered checklist mode).
    func toggleLine(_ id: String, index: Int) {
        guard let n = note(id) else { return }
        var lines = n.text.components(separatedBy: "\n")
        guard lines.indices.contains(index), ChecklistText.parse(lines[index]) != nil else { return }
        lines[index] = ChecklistText.toggled(lines[index])
        setText(id, lines.joined(separator: "\n"))
    }

    func togglePin(_ id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle()
        UserDefaults.standard.set(notes.filter(\.pinned).map(\.id), forKey: NotesPrefs.pinned)
    }

    func delete(_ id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        saveTasks[id]?.cancel(); saveTasks[id] = nil
        dirty.remove(id)
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { lastError = "Couldn't move the note to the Trash: \(error.localizedDescription)"; return }
        }
        notes.remove(at: i)
        UserDefaults.standard.set(notes.filter(\.pinned).map(\.id), forKey: NotesPrefs.pinned)
        if currentID == id {
            currentID = nil
            select(sorted().first?.id)
            if currentID == nil { newNote() }
        }
    }

    func copy(_ id: String) {
        guard let n = note(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.text, forType: .string)
    }

    func export(_ id: String) {
        guard let n = note(id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFileName(n.title) + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try n.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { lastError = "Couldn't export: \(error.localizedDescription)" }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func clearError() { lastError = nil }

    private static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Note" : cleaned
    }

    private func loadIfNeeded() { if !loaded { ensureLoaded() } }

    /// Removes notes that were created but never typed in.
    func pruneEmpty(except keep: String?) {
        for n in notes where n.id != keep && n.id != currentID && !n.pinned
            && n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteFile(n.id)
        }
    }

    // MARK: Saving

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".md") }

    private func scheduleSave(_ id: String) {
        dirty.insert(id)
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.write(id)
        }
    }

    private func write(_ id: String) {
        saveTasks[id] = nil
        guard dirty.contains(id), let n = note(id) else { return }
        // Don't leave empty files lying around.
        if n.text.isEmpty && !FileManager.default.fileExists(atPath: fileURL(id).path) { dirty.remove(id); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try n.text.write(to: fileURL(id), atomically: true, encoding: .utf8)
            diskStamp[id] = (try? fileURL(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            dirty.remove(id)
            lastSaved = Date()
            lastError = nil
        } catch {
            lastError = "Couldn't save the note: \(error.localizedDescription)"
            Self.log.error("save failed: \(error.localizedDescription)")
        }
    }

    /// Writes every pending change now (panel closed, app quitting).
    func flush() {
        for id in Array(dirty) { saveTasks[id]?.cancel(); write(id) }
    }

    private func deleteFile(_ id: String) {
        saveTasks[id]?.cancel(); saveTasks[id] = nil
        dirty.remove(id)
        try? FileManager.default.removeItem(at: fileURL(id))   // only ever empty notes
        notes.removeAll { $0.id == id }
    }
}

extension AppSearchIndex {
    /// Notes settings, added to the global search.
    static let notesEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Notes", "Notes scratchpad", "notes scratchpad markdown note autosave memo", tab: "notes"),
        SearchEntry(.tools, crumb: "Notes", "Floating note", "floating note panel always on top quick note hotkey shortcut", tab: "notes"),
        SearchEntry(.tools, crumb: "Notes", "Checklists in notes", "checklist todo checkbox task list", tab: "notes"),
        SearchEntry(.tools, crumb: "Notes", "Export or copy a note", "export copy markdown note save", tab: "notes"),
    ]
}
