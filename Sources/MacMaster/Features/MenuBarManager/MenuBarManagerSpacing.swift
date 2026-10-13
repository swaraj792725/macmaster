import AppKit

/// Menu bar item spacing / selection padding (`defaults -currentHost`, global domain).
enum MenuBarManagerSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    static let systemDefault = 16
    static let range = 0...20
    private static let defaultsTool = "/usr/bin/defaults"

    /// Current override, or nil when the system default is in effect.
    static func read(_ key: String) async -> Int? {
        let r = await Shell.runAsync(defaultsTool, ["-currentHost", "read", "-globalDomain", key], timeout: 5)
        guard r.ok else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func write(spacing: Int, padding: Int) async -> Bool {
        let s = min(max(spacing, range.lowerBound), range.upperBound)
        let p = min(max(padding, range.lowerBound), range.upperBound)
        let a = await Shell.runAsync(defaultsTool, ["-currentHost", "write", "-globalDomain", spacingKey, "-int", String(s)], timeout: 5)
        let b = await Shell.runAsync(defaultsTool, ["-currentHost", "write", "-globalDomain", paddingKey, "-int", String(p)], timeout: 5)
        return a.ok && b.ok
    }

    static func reset() async {
        _ = await Shell.runAsync(defaultsTool, ["-currentHost", "delete", "-globalDomain", spacingKey], timeout: 5)
        _ = await Shell.runAsync(defaultsTool, ["-currentHost", "delete", "-globalDomain", paddingKey], timeout: 5)
    }

    /// Restart the processes that draw the menu bar so the new spacing applies to system items.
    static func relaunchSystemUI() async {
        _ = await Shell.runAsync("/usr/bin/killall", ["SystemUIServer"], timeout: 5)
        _ = await Shell.runAsync("/usr/bin/killall", ["ControlCenter"], timeout: 5)
    }

    /// Confirm with the user, then relaunch. Returns true if it ran.
    @MainActor static func confirmAndRelaunch() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restart menu bar services?"
        alert.informativeText = "SystemUIServer and Control Center will quit and restart immediately. The menu bar flickers for a second and open menus close. Other apps pick up the new spacing the next time they launch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        await relaunchSystemUI()
        return true
    }
}
