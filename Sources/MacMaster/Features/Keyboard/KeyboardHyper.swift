import Foundation

/// Remaps Caps Lock -> F18 with `hidutil` and restores the previous `UserKeyMapping`.
/// All work happens on one serial queue so apply/restore never interleave.
enum KeyboardHyperMapper {
    static let capsSrc: UInt64 = 0x700000039
    static let f18Dst: UInt64 = 0x70000006D

    struct Pair: Equatable { var src: UInt64; var dst: UInt64 }

    private static let queue = DispatchQueue(label: "MacMaster.KeyboardHyperMapper")
    private static let hidutil = "/usr/bin/hidutil"

    // MARK: Public

    static func apply() { queue.async { applySync() } }

    static func restore(wait: Bool) {
        if wait { queue.sync { restoreSync() } } else { queue.async { restoreSync() } }
    }

    /// True when a saved mapping exists, i.e. a previous run changed it and never restored.
    static var hasPendingRestore: Bool { UserDefaults.standard.string(forKey: KeyboardPrefs.hyperSavedMapping) != nil }

    // MARK: Implementation

    private static func applySync() {
        let current = readMapping()
        let already = current.contains(Pair(src: capsSrc, dst: f18Dst))
        let defaults = UserDefaults.standard
        if defaults.string(forKey: KeyboardPrefs.hyperSavedMapping) == nil {
            // Save what the user had so restore returns exactly that. If our own entry is already
            // there (previous run without a saved copy), drop it: the original Caps mapping is unknown.
            let original = already ? current.filter { $0.src != capsSrc } : current
            defaults.set(json(for: original), forKey: KeyboardPrefs.hyperSavedMapping)
        }
        if already { return }
        let list = current.filter { $0.src != capsSrc } + [Pair(src: capsSrc, dst: f18Dst)]
        _ = write(list)
    }

    private static func restoreSync() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: KeyboardPrefs.hyperSavedMapping) {
            if write(parse(json: saved)) { defaults.removeObject(forKey: KeyboardPrefs.hyperSavedMapping) }
            return
        }
        // Nothing saved: only strip our own entry if it is there.
        let current = readMapping()
        if current.contains(Pair(src: capsSrc, dst: f18Dst)) {
            _ = write(current.filter { $0.src != capsSrc })
        }
    }

    private static func readMapping() -> [Pair] {
        let r = Shell.run(hidutil, ["property", "--get", "UserKeyMapping"], timeout: 5)
        guard r.ok else { return [] }
        return parse(hidutilOutput: r.stdout)
    }

    @discardableResult
    private static func write(_ list: [Pair]) -> Bool {
        let r = Shell.run(hidutil, ["property", "--set", json(for: list, wrapped: true)], timeout: 5)
        return r.ok
    }

    // MARK: Parsing / encoding

    private static func json(for list: [Pair], wrapped: Bool = false) -> String {
        let items = list.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        let array = "[" + items.joined(separator: ",") + "]"
        return wrapped ? "{\"UserKeyMapping\":\(array)}" : array
    }

    private static func parse(json: String) -> [Pair] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let s = (d["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value,
                  let t = (d["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value else { return nil }
            return Pair(src: s, dst: t)
        }
    }

    /// `hidutil` prints an old-style plist ("(null)" when empty); numbers may be decimal or 0x-hex.
    private static func parse(hidutilOutput out: String) -> [Pair] {
        var result: [Pair] = []
        for chunk in out.components(separatedBy: "}") {
            guard let s = number(after: "HIDKeyboardModifierMappingSrc", in: chunk),
                  let d = number(after: "HIDKeyboardModifierMappingDst", in: chunk) else { continue }
            result.append(Pair(src: s, dst: d))
        }
        return result
    }

    private static func number(after key: String, in text: String) -> UInt64? {
        guard let r = text.range(of: key) else { return nil }
        let tail = text[r.upperBound...]
        var digits = ""
        var started = false
        for ch in tail {
            if !started {
                if ch == "=" || ch == ":" || ch == " " || ch == "\"" || ch == "\t" || ch == "\n" { continue }
                started = true
            }
            if ch.isHexDigit || ch == "x" || ch == "X" { digits.append(ch) } else { break }
        }
        if digits.lowercased().hasPrefix("0x") { return UInt64(digits.dropFirst(2), radix: 16) }
        return UInt64(digits)
    }
}
