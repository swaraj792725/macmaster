import Foundation

extension AppSearchIndex {
    /// Clipboard upgrades (plain-text paste, link cleaning, auto-clear), added to the global search.
    static let clipboardExtrasEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Clipboard History", "Paste as plain text", "clipboard strip formatting shortcut hotkey rich text", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Quick paste panel", "clipboard popup history shortcut hotkey search cursor", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Clean tracking from copied links", "utm fbclid gclid tracking params url privacy clipboard", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Skip passwords and secrets", "clipboard concealed password manager 1password bitwarden privacy", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Ignored apps", "clipboard exclude password manager keychain privacy", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Clear a copied secret", "clipboard auto clear wipe timer password", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Clear history when the screen locks", "clipboard lock privacy", tab: "clipboard"),
        SearchEntry(.tools, crumb: "Clipboard History", "Remove old items", "clipboard expire days cleanup history size", tab: "clipboard"),
    ]
}
