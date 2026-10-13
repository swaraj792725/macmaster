import AppKit
import Foundation

/// Experimental, reversible attempt to hide Apple's own Control Center menu bar items.
/// It only edits the `NSStatusItem Visible*` keys of com.apple.controlcenter (the same ones System Settings > Menu Bar
/// uses on older macOS) and restarts ControlCenter. Original values are saved so Restore puts them back exactly.
/// On recent macOS the system may ignore these keys; the result is always re-checked through Accessibility and reported.
@Observable @MainActor
final class AppleItemHider {
    static let shared = AppleItemHider()

    struct Module: Identifiable, Hashable {
        let id: String            // suffix used in the preference keys
        let title: String
        let symbol: String
    }

    /// The Control Center menu bar icon itself. macOS 26 names it BentoBox-0; older builds used BentoBox.
    static let mainKeys = ["BentoBox", "BentoBox-0"]

    static let modules: [Module] = [
        Module(id: "WiFi", title: "Wi-Fi", symbol: "wifi"),
        Module(id: "Bluetooth", title: "Bluetooth", symbol: "wave.3.right"),
        Module(id: "Sound", title: "Sound", symbol: "speaker.wave.2.fill"),
        Module(id: "Battery", title: "Battery", symbol: "battery.100"),
        Module(id: "FocusModes", title: "Focus", symbol: "moon.fill"),
        Module(id: "NowPlaying", title: "Now Playing", symbol: "play.circle.fill"),
        Module(id: "Display", title: "Display", symbol: "sun.max.fill"),
        Module(id: "ScreenMirroring", title: "Screen Mirroring", symbol: "rectangle.on.rectangle"),
        Module(id: "AirDrop", title: "AirDrop", symbol: "dot.radiowaves.up.forward"),
    ]

    struct Report: Equatable {
        enum Kind { case success, warning, info }
        let kind: Kind
        let text: String
    }

    private static let domain = "com.apple.controlcenter"
    private static let backupKey = "mm.controlcenter.hideBackup"
    private static let sep = "\u{1F}"

    private(set) var busy = false
    private(set) var report: Report?
    /// Module ids (and "main") whose VisibleCC key is currently false.
    private(set) var hidden: Set<String> = []
    private(set) var hasBackup = false
    @ObservationIgnored private var confirmedModules = false

    private init() { refreshState() }

    // MARK: State

    private static func keys(_ suffix: String) -> [String] {
        ["NSStatusItem Visible \(suffix)", "NSStatusItem VisibleCC \(suffix)"]
    }

    private static func read(_ key: String) -> Bool? {
        let v = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? NSNumber)?.boolValue
    }

    func refreshState() {
        var h = Set<String>()
        if Self.mainKeys.contains(where: { Self.read("NSStatusItem VisibleCC \($0)") == false }) { h.insert("main") }
        for m in Self.modules where Self.read("NSStatusItem VisibleCC \(m.id)") == false { h.insert(m.id) }
        hidden = h
        hasBackup = !(UserDefaults.standard.dictionary(forKey: Self.backupKey) ?? [:]).isEmpty
    }

    // MARK: Hide the Control Center icon

    /// Asks first, then writes the keys, restarts ControlCenter and checks whether the icon is really gone.
    func tryHideControlCenter() {
        guard !busy else { return }
        guard confirm(title: "Try hiding Apple's Control Center icon?",
                      text: "MacMaster will set the Control Center menu bar preferences to hidden and restart Control Center (and, if needed, the menu bar agent once). The menu bar may flicker for a moment. macOS might ignore this on your version; MacMaster will check and tell you. You can undo it with Restore.",
                      button: "Try It") else { return }
        Task { await hideMain() }
    }

    private func hideMain() async {
        busy = true; report = nil
        defer { busy = false; refreshState() }
        var failed: String?
        for suffix in Self.mainKeys {
            for key in Self.keys(suffix) { if let e = setBool(key, false) { failed = e } }
        }
        if let failed { report = Report(kind: .warning, text: "Couldn't write the preference: \(failed)"); return }
        await restartControlCenter()
        var state = await verifyControlCenterIcon()
        if state == .visible {
            // On macOS 26+ the icon is drawn by MenuBarAgent, which caches its layout. One restart of it is harmless (launchd respawns it).
            await restartAgent("MenuBarAgent")
            state = await verifyControlCenterIcon()
        }
        switch state {
        case .hidden:
            report = Report(kind: .success, text: "Apple's Control Center icon is hidden. Use Restore to bring it back.")
        case .visible:
            report = Report(kind: .warning, text: "macOS kept the icon visible, so it ignores these preferences on this version. Use \"Redirect clicks\" above instead: clicking Apple's icon opens MacMaster's Control Center. You can press Restore to clean up.")
        case .unknown:
            report = Report(kind: .info, text: "Preferences written and Control Center restarted, but I couldn't verify the result. Grant Accessibility access to check, or look at your menu bar.")
        }
    }

    // MARK: Other Apple modules

    func isHidden(_ module: Module) -> Bool { hidden.contains(module.id) }

    func setModuleHidden(_ module: Module, _ hide: Bool) {
        guard !busy else { return }
        if !confirmedModules {
            guard confirm(title: "Change Apple's menu bar items?",
                          text: "MacMaster edits the Control Center menu bar preferences and restarts Control Center. It is reversible: each item can be shown again here, or all at once with Restore all.",
                          button: "Continue") else { return }
            confirmedModules = true
        }
        Task {
            busy = true; report = nil
            defer { busy = false; refreshState() }
            var failed: String?
            for key in Self.keys(module.id) {
                if hide { if let e = setBool(key, false) { failed = e } }
                else if let e = restoreKey(key) { failed = e }
            }
            if let failed { report = Report(kind: .warning, text: "Couldn't change \(module.title): \(failed)"); return }
            await restartControlCenter()
            report = Report(kind: .info, text: hide
                ? "\(module.title) set to hidden. If it is still showing, macOS ignores this on your version; try System Settings > Control Center instead."
                : "\(module.title) set back to its original state.")
        }
    }

    // MARK: Restore

    /// Puts every key MacMaster changed back to its saved original (or deletes it if it didn't exist), then restarts Control Center.
    func restoreAll() {
        guard !busy else { return }
        Task {
            busy = true; report = nil
            defer { busy = false; refreshState() }
            var keys = Set((UserDefaults.standard.dictionary(forKey: Self.backupKey) ?? [:]).keys)
            // Keys written outside MacMaster's backup are cleared too, so macOS falls back to its default (shown).
            for suffix in Self.mainKeys + Self.modules.map(\.id) {
                for k in Self.keys(suffix) where Self.read(k) == false { keys.insert(k) }
            }
            var failed: String?
            for k in keys { if let e = restoreKey(k) { failed = e } }
            UserDefaults.standard.removeObject(forKey: Self.backupKey)
            if let failed { report = Report(kind: .warning, text: "Restore hit an error: \(failed)"); return }
            await restartControlCenter()
            report = Report(kind: .success, text: "Restored. Apple's menu bar items are back to how they were.")
        }
    }

    // MARK: Preferences (through /usr/bin/defaults, exactly what a user would type)

    private func backup(_ key: String) {
        var b = UserDefaults.standard.dictionary(forKey: Self.backupKey) as? [String: String] ?? [:]
        guard b[key] == nil else { return }   // keep the true original across repeated hides
        switch Self.read(key) {
        case .some(let v): b[key] = v ? "1" : "0"
        case .none: b[key] = "absent"
        }
        UserDefaults.standard.set(b, forKey: Self.backupKey)
    }

    private func setBool(_ key: String, _ value: Bool) -> String? {
        backup(key)
        let r = Shell.run("/usr/bin/defaults", ["write", Self.domain, key, "-bool", value ? "true" : "false"], timeout: 10)
        return r.ok ? nil : (r.stderr.isEmpty ? "defaults exited \(r.status)" : r.stderr)
    }

    private func restoreKey(_ key: String) -> String? {
        var b = UserDefaults.standard.dictionary(forKey: Self.backupKey) as? [String: String] ?? [:]
        let saved = b.removeValue(forKey: key)
        UserDefaults.standard.set(b, forKey: Self.backupKey)
        let r: Shell.Result
        switch saved {
        case "1", "0":
            r = Shell.run("/usr/bin/defaults", ["write", Self.domain, key, "-bool", saved == "1" ? "true" : "false"], timeout: 10)
        default:
            r = Shell.run("/usr/bin/defaults", ["delete", Self.domain, key], timeout: 10)
            // Deleting a key that isn't there is fine.
            if !r.ok, r.stderr.contains("does not exist") { return nil }
        }
        return r.ok ? nil : (r.stderr.isEmpty ? "defaults exited \(r.status)" : r.stderr)
    }

    // MARK: Restart + verify

    private func restartControlCenter() async {
        _ = await Shell.runAsync("/usr/bin/killall", ["ControlCenter"], timeout: 5)
        try? await Task.sleep(for: .seconds(2))
    }

    private func restartAgent(_ name: String) async {
        _ = await Shell.runAsync("/usr/bin/killall", [name], timeout: 5)
        try? await Task.sleep(for: .seconds(2.5))
    }

    private enum IconState { case hidden, visible, unknown }

    /// Polls Accessibility for a few seconds. Visible as soon as the icon shows up; hidden only if other items showed up without it.
    private func verifyControlCenterIcon() async -> IconState {
        guard Permissions.isGranted(.accessibility) else { return .unknown }
        var sawOthers = false
        for _ in 0..<3 {
            let found = await Task.detached(priority: .userInitiated) { AppleMenuScanner.scan(timeout: 0.5) }.value
            if found[AppleMenuItem.controlCenter] != nil { return .visible }
            if !found.isEmpty { sawOthers = true }
            try? await Task.sleep(for: .seconds(1))
        }
        return sawOthers ? .hidden : .unknown
    }

    // MARK: Helpers

    private func confirm(title: String, text: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func openMenuBarSettings() {
        ControlCenterSystem.openSettings("com.apple.ControlCenter-Settings.extension")
    }
}
