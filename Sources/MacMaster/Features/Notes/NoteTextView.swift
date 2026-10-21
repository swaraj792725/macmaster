import SwiftUI
import AppKit

/// NSTextView that knows about checklists: Cmd+Return toggles "- [ ]" / "- [x]" on the current line,
/// Return continues a list.
final class ChecklistTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, mods.contains(.command) { toggleChecklistLine(); return }
        if isReturn, mods.isDisjoint(with: [.command, .option, .control, .shift]), continueList() { return }
        super.keyDown(with: event)
    }

    /// The floating note doesn't activate MacMaster, so the menu bar (and its Edit shortcuts) belongs to another app.
    /// Handle the basic editing shortcuts here in that case.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !NSApp.isActive, event.type == .keyDown, window?.isKeyWindow == true else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), mods.isDisjoint(with: [.option, .control]) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        case "z": if mods.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func currentLineRange() -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    private func toggleChecklistLine() {
        let ns = string as NSString
        let full = currentLineRange()
        var content = ns.substring(with: full)
        var newline = ""
        if content.hasSuffix("\n") { content.removeLast(); newline = "\n" }
        let replaced = ChecklistText.toggled(content)
        guard replaced != content else { return }
        let caret = selectedRange().location
        let delta = (replaced as NSString).length - (content as NSString).length
        let range = NSRange(location: full.location, length: (content as NSString).length)
        if shouldChangeText(in: range, replacementString: replaced) {
            replaceCharacters(in: range, with: replaced)
            didChangeText()
            _ = newline
            setSelectedRange(NSRange(location: max(full.location, caret + delta), length: 0))
        }
    }

    /// Returns true when Return was handled.
    private func continueList() -> Bool {
        guard selectedRange().length == 0 else { return false }
        let ns = string as NSString
        let full = currentLineRange()
        var line = ns.substring(with: full)
        if line.hasSuffix("\n") { line.removeLast() }
        // Only continue when the caret is at the end of the line.
        guard selectedRange().location >= full.location + (line as NSString).length,
              let cont = ChecklistText.continuation(of: line) else { return false }
        if cont.empty {
            // Return on an empty item ends the list.
            let range = NSRange(location: full.location, length: (line as NSString).length)
            if shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
            }
            return true
        }
        insertText("\n" + cont.prefix, replacementRange: selectedRange())
        return true
    }
}

/// Plain-text markdown editor. Binds to a string; skips writing back identical text so the caret never jumps.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var monospaced: Bool
    var fontSize: CGFloat
    var focusOnAppear = true
    /// Changes when the edited note changes, so the view resets undo history and focuses.
    var documentID: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let tv = ChecklistTextView(frame: .zero)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        scroll.documentView = tv
        apply(font: tv)
        tv.string = text
        context.coordinator.documentID = documentID
        if focusOnAppear {
            DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            tv.string = text
            tv.undoManager?.removeAllActions()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scrollToBeginningOfDocument(nil)
            if focusOnAppear { DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) } }
        } else if tv.string != text, !context.coordinator.editing {
            // Changed from outside (another window, file refresh).
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        }
        if tv.font?.pointSize != fontSize || (tv.font?.isFixedPitch ?? false) != monospaced { apply(font: tv) }
    }

    private func apply(font tv: NSTextView) {
        let f: NSFont = monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        tv.font = f
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.typingAttributes = [.font: f, .foregroundColor: NSColor.labelColor]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: NSTextView?
        var documentID = ""
        var editing = false

        init(_ parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            editing = true
            parent.text = tv.string
            editing = false
        }
    }
}
