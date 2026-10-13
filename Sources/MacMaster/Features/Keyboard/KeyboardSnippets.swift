import AppKit

/// Deletes the typed trigger and pastes the expansion via the pasteboard, then restores the clipboard.
@MainActor
enum KeyboardSnippetExpander {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func expand(text raw: String, backspaces: Int) {
        let pb = NSPasteboard.general
        let text = resolve(raw, pasteboard: pb)

        // Snapshot the current clipboard (every item, every type).
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType) // ask clipboard managers to ignore this entry
        pb.writeObjects([item])
        let ours = pb.changeCount

        for _ in 0..<max(0, backspaces) { KeyboardKeyPoster.tap(51) }
        KeyboardKeyPoster.tap(9, flags: .maskCommand) // ⌘V

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let pb = NSPasteboard.general
            guard pb.changeCount == ours else { return } // user copied something meanwhile: leave it
            pb.clearContents()
            guard !saved.isEmpty else { return }
            let items: [NSPasteboardItem] = saved.map { pairs in
                let i = NSPasteboardItem()
                for (t, d) in pairs { i.setData(d, forType: t) }
                return i
            }
            pb.writeObjects(items)
        }
    }

    /// Supports {date}, {time}, {datetime} and {clipboard}.
    private static func resolve(_ s: String, pasteboard: NSPasteboard) -> String {
        guard s.contains("{") else { return s }
        var out = s
        let now = Date()
        if out.contains("{date}") { out = out.replacingOccurrences(of: "{date}", with: now.formatted(date: .abbreviated, time: .omitted)) }
        if out.contains("{time}") { out = out.replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened)) }
        if out.contains("{datetime}") { out = out.replacingOccurrences(of: "{datetime}", with: now.formatted(date: .abbreviated, time: .shortened)) }
        if out.contains("{clipboard}") {
            out = out.replacingOccurrences(of: "{clipboard}", with: pasteboard.string(forType: .string) ?? "")
        }
        return out
    }
}
