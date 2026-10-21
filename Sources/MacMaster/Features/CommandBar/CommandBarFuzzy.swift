import Foundation

/// Command Bar match scoring. Higher is better, nil means "does not match".
/// Tiers (gaps are wide on purpose so the usage boost can reorder inside a tier but never jump one):
/// exact 1000 > prefix ~850 > word start ~650 > initials 560 > substring ~400 > subsequence ~250.
enum CommandBarFuzzy {
    /// Lowercased, diacritic-free form. Fold both sides once, then call `score`.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Both arguments must already be folded. Several space-separated tokens must each match.
    static func score(_ query: String, in text: String) -> Int? {
        guard !query.isEmpty, !text.isEmpty else { return nil }
        if text == query { return 1000 }
        if text.hasPrefix(query) { return 850 - min(text.count - query.count, 40) }
        let tokens = query.split(separator: " ").map(String.init)
        if tokens.count > 1 {
            guard tokens.count <= 5 else { return nil }
            var sum = 0
            for t in tokens {
                guard let s = single(t, in: text) else { return nil }
                sum += s
            }
            return sum / tokens.count - 10 * (tokens.count - 1)
        }
        return single(query, in: text)
    }

    private static func single(_ q: String, in t: String) -> Int? {
        guard !q.isEmpty else { return nil }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 850 - min(t.count - q.count, 40) }
        // Word start: "code" in "Visual Studio Code".
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for (i, w) in words.enumerated() where w.hasPrefix(q) {
            return 650 - min(i * 12, 60) - min(w.count - q.count, 20)
        }
        // Initials: "vsc" -> Visual Studio Code.
        if q.count >= 2, words.count >= 2 {
            let initials = String(words.compactMap(\.first))
            if initials.hasPrefix(q) { return 560 - min(initials.count - q.count, 20) }
        }
        if let r = t.range(of: q) {
            let pos = t.distance(from: t.startIndex, to: r.lowerBound)
            return 400 - min(pos, 80)
        }
        guard q.count >= 2 else { return nil }
        return subsequence(Array(q), Array(t))
    }

    /// Greedy in-order match with a bounded span so unrelated long titles do not match short queries.
    private static func subsequence(_ q: [Character], _ t: [Character]) -> Int? {
        var qi = 0, first = -1, last = -1, runs = 0, prev = -2
        for (ti, c) in t.enumerated() where qi < q.count && c == q[qi] {
            if first < 0 { first = ti }
            if ti != prev + 1 { runs += 1 }
            prev = ti; last = ti; qi += 1
        }
        guard qi == q.count, first >= 0 else { return nil }
        let span = last - first + 1
        guard span <= q.count * 3 + 2 else { return nil }
        return 260 - min((span - q.count) * 8, 120) - min(runs * 10, 60) - min(first, 20)
    }
}
