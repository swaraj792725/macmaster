import Foundation

/// Turns a raw transcript into the text that gets typed: spoken commands, spacing, trailing space.
enum DictationText {
    struct Options {
        var voiceCommands = true
        /// When the recognizer adds punctuation itself, spoken "period" and friends are left alone.
        var recognizerPunctuates = true
        var trailingSpace = true
    }

    static func process(_ raw: String, _ o: Options) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        if o.voiceCommands {
            t = replace(t, [("new paragraph", "\n\n"), ("new line", "\n"), ("newline", "\n")])
            if !o.recognizerPunctuates {
                t = replace(t, [("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
                                ("full stop", "."), ("period", "."), ("comma", ","), ("semicolon", ";"), ("colon", ":")])
            }
            t = tidy(t, capitalize: !o.recognizerPunctuates)
        }
        if o.trailingSpace, let last = t.last, !last.isNewline { t += " " }
        return t
    }

    /// Replaces whole spoken words, case-insensitively, swallowing the space before the replacement.
    private static func replace(_ text: String, _ pairs: [(String, String)]) -> String {
        var t = text
        for (spoken, symbol) in pairs {
            let pattern = "\\s*(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: spoken) + "(?![\\p{L}\\p{N}])[.,]?"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: symbol))
        }
        return t
    }

    /// Removes the space the replacements leave behind and capitalizes after sentence ends.
    private static func tidy(_ text: String, capitalize: Bool) -> String {
        var t = text
        // "hello \n world" -> "hello\nworld"
        t = t.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        // A symbol glued to the next word needs a space: "hello,world" -> "hello, world"
        t = t.replacingOccurrences(of: "([,;:?!])(?=[\\p{L}\\p{N}])", with: "$1 ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[a-z0-9])\\.(?=[A-Za-z])", with: ". ", options: .regularExpression)
        if capitalize { t = capitalizeSentences(t) }
        return t
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var out = ""
        var atStart = true
        for ch in text {
            if atStart, ch.isLetter {
                out += ch.uppercased()
                atStart = false
            } else {
                out.append(ch)
                if ch == "." || ch == "?" || ch == "!" || ch == "\n" { atStart = true }
                else if !ch.isWhitespace { atStart = false }
            }
        }
        return out
    }
}
