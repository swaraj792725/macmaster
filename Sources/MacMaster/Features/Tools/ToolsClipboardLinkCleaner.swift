import Foundation

/// Strips tracking parameters from copied links. Pure and Foundation-only so it is easy to test.
/// Never touches text that is not a single http(s) URL; keeps the fragment and every other parameter as-is.
enum ToolsClipboardLinkCleaner {
    /// Parameter names removed everywhere (compared lowercased).
    private static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "igsh", "ref_src", "ref_url", "_hsenc", "_hsmi", "yclid", "ysclid", "spm", "vero_id",
        "vero_conv", "wickedid", "ttclid", "twclid", "s_cid", "_ga", "_gl", "mkt_tok", "rb_clickid",
        "oly_enc_id", "oly_anon_id", "_openstat", "sr_share", "trk", "trkemail", "li_fat_id",
        "pk_campaign", "pk_kwd", "piwik_campaign", "piwik_kwd", "epik",
    ]
    /// Parameter name prefixes removed everywhere.
    private static let prefixes = ["utm_", "oly_", "hsa_", "mtm_", "matomo_"]
    /// `si` is a share-tracking id on these sites only (it is a real parameter elsewhere).
    private static let siHosts = ["youtube.com", "youtu.be", "spotify.com", "spotify.link"]

    /// Returns the cleaned URL string, or nil when `text` is not a single web link or nothing needed removing.
    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count < 8_000, t.hasPrefix("http://") || t.hasPrefix("https://"),
              t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let comps = URLComponents(string: t),
              let host = comps.host?.lowercased(), !host.isEmpty else { return nil }

        // Work on the original text (URLComponents would re-encode characters like [ ]).
        let hash = t.firstIndex(of: "#") ?? t.endIndex
        let fragment = t[hash...]
        let beforeFragment = t[..<hash]
        guard let q = beforeFragment.firstIndex(of: "?") else { return nil }
        let rawQuery = String(beforeFragment[beforeFragment.index(after: q)...])
        guard !rawQuery.isEmpty else { return nil }

        let isSIHost = siHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        var removed = 0
        let kept = rawQuery.split(separator: "&", omittingEmptySubsequences: false).filter { part in
            let nameRaw = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let name = (nameRaw.removingPercentEncoding ?? nameRaw).lowercased()
            let drop = exact.contains(name) || prefixes.contains { name.hasPrefix($0) } || (name == "si" && isSIHost)
            if drop { removed += 1 }
            return !drop
        }
        guard removed > 0 else { return nil }
        let newQuery = kept.filter { !$0.isEmpty }.joined(separator: "&")
        let out = String(beforeFragment[..<q]) + (newQuery.isEmpty ? "" : "?" + newQuery) + fragment
        guard out != t else { return nil }
        return out
    }
}
