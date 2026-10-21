import Foundation
import AppKit

/// One wrapped line of the script with its exact position, so each line can be drawn on its own.
struct PromptLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let y: CGFloat
    let height: CGFloat
    let words: Int
    var center: CGFloat { y + height / 2 }
}

/// The script wrapped at a given width and font size using TextKit (same metrics the overlay draws with).
struct PromptLayout: Equatable {
    let stamp: Int
    let lines: [PromptLine]
    let totalHeight: CGFloat
    let width: CGFloat
    let fontSize: CGFloat

    private static var counter = 0
    static let empty = PromptLayout(stamp: 0, lines: [], totalHeight: 0, width: 0, fontSize: 0)

    /// Where the reading marker starts: the middle of the first line.
    var startOffset: CGFloat { lines.first?.center ?? 0 }
    /// Scrolling is done once the last line has passed the marker.
    var endOffset: CGFloat { totalHeight }

    static func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }

    static func make(text: String, fontSize: CGFloat, width: CGFloat) -> PromptLayout {
        counter += 1
        let stamp = counter
        let w = max(120, width)
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Very long scripts are cut so layout can't stall the main thread.
        let capped = clean.count > 120_000 ? String(clean.prefix(120_000)) : clean
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PromptLayout(stamp: stamp, lines: [], totalHeight: 0, width: w, fontSize: fontSize)
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.22
        style.alignment = .center
        let storage = NSTextStorage(string: capped, attributes: [.font: font(fontSize), .paragraphStyle: style])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: w, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let ns = capped as NSString
        var out: [PromptLine] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let s = ns.substring(with: chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = s.split(whereSeparator: { $0.isWhitespace }).count
            out.append(PromptLine(id: out.count, text: s, y: rect.minY, height: rect.height, words: words))
        }
        let total = out.last.map { $0.y + $0.height } ?? 0
        return PromptLayout(stamp: stamp, lines: out, totalHeight: total, width: w, fontSize: fontSize)
    }

    /// Index of the line containing `offset` (clamped).
    func index(at offset: CGFloat) -> Int {
        guard !lines.isEmpty else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].y <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// (line, fraction through the line), used to keep the place when the layout is rebuilt.
    func progress(at offset: CGFloat) -> (line: Int, fraction: CGFloat) {
        guard !lines.isEmpty else { return (0, 0) }
        let i = index(at: offset)
        let l = lines[i]
        return (i, max(0, min(1, (offset - l.y) / max(1, l.height))))
    }

    func offset(line: Int, fraction: CGFloat) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let l = lines[max(0, min(lines.count - 1, line))]
        return l.y + l.height * fraction
    }
}

/// Script text helpers.
enum PromptText {
    /// Strips common markdown so an imported .md reads like plain speech.
    static func stripMarkdown(_ s: String) -> String {
        var inFence = false
        var out: [String] = []
        for raw in s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { out.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "***" || t == "___" { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-*+]|\d+\.)\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*|_)(\S(?:.*?\S)?)\1"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: "`", with: "")
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
