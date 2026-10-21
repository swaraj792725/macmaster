import SwiftUI
import AppKit

/// Borderless-feeling note window that floats above everything (including full-screen apps).
final class FloatingNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating note window. The window only exists while it is open; closing releases the view tree.
@MainActor
final class NotesFloatingController: NSObject, NSWindowDelegate {
    static let shared = NotesFloatingController()
    private static let frameKey = "mm.notes.floatFrame"
    private var panel: FloatingNotePanel?

    private override init() { super.init() }

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Hot key / button: open when closed, focus when open but behind, close when focused.
    func toggle() {
        if let p = panel, p.isVisible {
            if p.isKeyWindow { close() } else { p.makeKeyAndOrderFront(nil) }
        } else {
            show()
        }
    }

    func show() {
        guard !Services.isSnapshotRun else { return }
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        NotesEngine.shared.ensureLoaded()
        if NotesEngine.shared.current == nil { NotesEngine.shared.newNote() }

        let p = FloatingNotePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.title = "Note"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.minSize = NSSize(width: 240, height: 180)
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: FloatingNoteView())
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        restoreFrame(p)
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    // MARK: Frame memory

    private func restoreFrame(_ p: NSPanel) {
        if let s = UserDefaults.standard.string(forKey: Self.frameKey) {
            let r = NSRectFromString(s)
            if r.width >= 240, r.height >= 180, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                p.setFrame(r, display: false)
                return
            }
        }
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 24, y: f.maxY - p.frame.height - 24))
        }
    }

    private func saveFrame() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        NotesEngine.shared.flush()
        guard let p = panel else { return }
        panel = nil
        p.delegate = nil
        // Drop the SwiftUI tree once the close has finished.
        DispatchQueue.main.async { p.contentView = nil }
    }
}

// MARK: - Content

private struct FloatingNoteView: View {
    private let engine = NotesEngine.shared
    @AppStorage(NotesPrefs.monospaced) private var mono = false
    @AppStorage(NotesPrefs.fontSize) private var fontSize = 14.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let note = engine.current {
                NoteTextView(text: Binding(
                    get: { engine.note(note.id)?.text ?? "" },
                    set: { engine.setText(note.id, $0) }),
                    monospaced: mono, fontSize: fontSize, documentID: note.id)
                    .padding(.horizontal, 4)
                footer(note)
            } else {
                Spacer()
            }
        }
        .padding(.top, 22)   // room for the transparent title bar
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(engine.sorted()) { n in
                    Button { engine.select(n.id) } label: {
                        Text((n.pinned ? "📌 " : "") + n.title)
                    }
                }
            } label: {
                Text(engine.current?.title ?? "Notes").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            if let n = engine.current {
                Button { engine.togglePin(n.id) } label: { Image(systemName: n.pinned ? "pin.fill" : "pin") }
                    .help(n.pinned ? "Unpin" : "Pin")
            }
            Button { engine.newNote() } label: { Image(systemName: "square.and.pencil") }
                .help("New note")
            Button { mono.toggle() } label: { Image(systemName: mono ? "textformat" : "chevron.left.forwardslash.chevron.right") }
                .help(mono ? "Use regular font" : "Use monospaced font")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func footer(_ n: NoteItem) -> some View {
        HStack(spacing: 8) {
            Text("\(n.wordCount) words · \(n.charCount) chars")
            Spacer(minLength: 0)
            if let e = engine.lastError { Text(e).foregroundStyle(.red).lineLimit(1) }
            Button { engine.copy(n.id) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy note")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
