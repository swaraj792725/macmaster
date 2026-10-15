import SwiftUI
import AppKit
import Observation

// MARK: - Definitions

enum OptimizerTweakValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String)

    var defaultsArgs: [String] {
        switch self {
        case .bool(let b): ["-bool", b ? "true" : "false"]
        case .int(let i): ["-int", String(i)]
        case .double(let d): ["-float", String(d)]
        case .string(let s): ["-string", s]
        }
    }

    func matches(_ other: OptimizerTweakValue?) -> Bool {
        guard let other else { return false }
        switch (self, other) {
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return abs(a - b) < 0.0005
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return abs(Double(a) - b) < 0.0005
        default: return false
        }
    }
}

struct OptimizerTweakSetting {
    var domain: String          // bundle id or "NSGlobalDomain"
    var key: String
    var value: OptimizerTweakValue
}

enum OptimizerTweakRestart: String {
    case none, dock, finder, logout
    var note: String? {
        switch self {
        case .none: nil
        case .dock: "Restarts the Dock"
        case .finder: "Restarts Finder"
        case .logout: "Takes effect after you log out"
        }
    }
}

struct OptimizerTweak: Identifiable {
    let id: String
    var title: String
    var detail: String
    var symbol: String
    var colors: [Color]
    var settings: [OptimizerTweakSetting]
    var restart: OptimizerTweakRestart
    /// Writing needs the user to have granted extra access (Accessibility / Full Disk Access).
    var needsAccessibilityAccess = false
}

private struct OptimizerStoredSetting: Codable {
    var domain: String
    var key: String
    var original: OptimizerTweakValue?
}

enum OptimizerTweakCatalog {
    static let all: [OptimizerTweak] = [
        OptimizerTweak(
            id: "dock.launchanim", title: "Hide Dock launch bounce",
            detail: "Stops icons bouncing in the Dock while an app opens.",
            symbol: "dock.rectangle", colors: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)],
            settings: [.init(domain: "com.apple.dock", key: "launchanim", value: .bool(false))], restart: .dock),
        OptimizerTweak(
            id: "dock.mineffect", title: "Fast minimize effect",
            detail: "Uses the quick Scale effect instead of Genie when minimizing windows.",
            symbol: "arrow.down.right.and.arrow.up.left", colors: [Color(hex: 0x38BDF8), Color(hex: 0x6366F1)],
            settings: [.init(domain: "com.apple.dock", key: "mineffect", value: .string("scale"))], restart: .dock),
        OptimizerTweak(
            id: "dock.autohide", title: "Instant Dock auto-hide",
            detail: "Removes the delay and shortens the slide when the Dock auto-hides. Only visible if Dock auto-hide is on.",
            symbol: "rectangle.bottomhalf.inset.filled", colors: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)],
            settings: [.init(domain: "com.apple.dock", key: "autohide-delay", value: .double(0)),
                       .init(domain: "com.apple.dock", key: "autohide-time-modifier", value: .double(0.25))],
            restart: .dock),
        OptimizerTweak(
            id: "dock.expose", title: "Faster Mission Control",
            detail: "Shortens the Mission Control animation.",
            symbol: "rectangle.3.group", colors: [Color(hex: 0x34D399), Color(hex: 0x059669)],
            settings: [.init(domain: "com.apple.dock", key: "expose-animation-duration", value: .double(0.1))],
            restart: .dock),
        OptimizerTweak(
            id: "global.windowanim", title: "Disable window open/close animations",
            detail: "Windows appear and disappear instantly in most apps. Applies to apps launched afterwards.",
            symbol: "macwindow", colors: [Color(hex: 0xFBBF24), Color(hex: 0xF97316)],
            settings: [.init(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", value: .bool(false))],
            restart: .none),
        OptimizerTweak(
            id: "global.resize", title: "Instant window resize",
            detail: "Removes the resize animation in Cocoa windows.",
            symbol: "arrow.up.left.and.arrow.down.right", colors: [Color(hex: 0xF472B6), Color(hex: 0xDB2777)],
            settings: [.init(domain: "NSGlobalDomain", key: "NSWindowResizeTime", value: .double(0.001))],
            restart: .none),
        OptimizerTweak(
            id: "global.quicklook", title: "Instant Quick Look",
            detail: "Opens Quick Look previews without the zoom animation.",
            symbol: "eye", colors: [Color(hex: 0x94A3B8), Color(hex: 0x475569)],
            settings: [.init(domain: "NSGlobalDomain", key: "QLPanelAnimationDuration", value: .double(0))],
            restart: .none),
        OptimizerTweak(
            id: "finder.anim", title: "Disable Finder animations",
            detail: "Turns off Finder's window, Get Info and Quick Look animations.",
            symbol: "folder", colors: [Color(hex: 0x60A5FA), Color(hex: 0x6366F1)],
            settings: [.init(domain: "com.apple.finder", key: "DisableAllAnimations", value: .bool(true))],
            restart: .finder),
        OptimizerTweak(
            id: "global.keyrepeat", title: "Faster key repeat",
            detail: "Shorter delay before a held key repeats and a faster repeat rate. Applies after you log out and back in.",
            symbol: "keyboard", colors: [Color(hex: 0x34D399), Color(hex: 0x0EA5E9)],
            settings: [.init(domain: "NSGlobalDomain", key: "KeyRepeat", value: .int(2)),
                       .init(domain: "NSGlobalDomain", key: "InitialKeyRepeat", value: .int(15))],
            restart: .logout),
        OptimizerTweak(
            id: "ua.reducemotion", title: "Reduce motion",
            detail: "Replaces sliding and zooming transitions with fades system-wide. May need Accessibility access to change.",
            symbol: "figure.walk.motion", colors: [Color(hex: 0xFB923C), Color(hex: 0xEF4444)],
            settings: [.init(domain: "com.apple.universalaccess", key: "reduceMotion", value: .bool(true))],
            restart: .none, needsAccessibilityAccess: true),
        OptimizerTweak(
            id: "ua.reducetransparency", title: "Reduce transparency",
            detail: "Makes menus, sidebars and windows opaque. Lowers GPU work on older Macs. May need Accessibility access to change.",
            symbol: "square.on.square.dashed", colors: [Color(hex: 0xA78BFA), Color(hex: 0x6366F1)],
            settings: [.init(domain: "com.apple.universalaccess", key: "reduceTransparency", value: .bool(true))],
            restart: .none, needsAccessibilityAccess: true),
    ]
}

// MARK: - Model

@Observable
@MainActor
final class OptimizerTweakModel {
    private(set) var enabled: Set<String> = []
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var isRestoring = false
    private(set) var hasOriginals = false

    @ObservationIgnored private var originals: [String: [OptimizerStoredSetting]] =
        Store.load([String: [OptimizerStoredSetting]].self, from: "optimizer-tweak-originals.json") ?? [:]

    init() { refresh() }

    var enabledCount: Int { enabled.count }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }

    func refresh() {
        var on = Set<String>()
        for t in OptimizerTweakCatalog.all where Self.isActive(t) { on.insert(t.id) }
        enabled = on
        hasOriginals = !originals.isEmpty
    }

    private static func isActive(_ t: OptimizerTweak) -> Bool {
        if t.needsAccessibilityAccess {
            switch t.id {
            case "ua.reducemotion": return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            case "ua.reducetransparency": return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            default: break
            }
        }
        return t.settings.allSatisfy { $0.value.matches(readValue(domain: $0.domain, key: $0.key)) }
    }

    // MARK: Reading

    nonisolated static func readValue(domain: String, key: String) -> OptimizerTweakValue? {
        let app: CFString = domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
        CFPreferencesAppSynchronize(app)
        guard let raw = CFPreferencesCopyAppValue(key as CFString, app) else { return nil }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((raw as! CFBoolean))) }
        if let n = raw as? NSNumber {
            return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
        }
        if let s = raw as? String { return .string(s) }
        return nil
    }

    // MARK: Writing

    func set(_ id: String, on: Bool) async {
        guard let tweak = OptimizerTweakCatalog.all.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id); errors[id] = nil
        defer { busy.remove(id); refresh() }

        if on {
            if originals[id] == nil {
                originals[id] = tweak.settings.map {
                    OptimizerStoredSetting(domain: $0.domain, key: $0.key, original: Self.readValue(domain: $0.domain, key: $0.key))
                }
                persist()
            }
            var failure: String?
            for s in tweak.settings {
                let r = await Shell.runAsync("/usr/bin/defaults", ["write", s.domain, s.key] + s.value.defaultsArgs, timeout: 15)
                if !r.ok { failure = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines); break }
            }
            if let failure {
                errors[id] = tweak.needsAccessibilityAccess
                    ? "macOS blocked this change. Allow MacMaster in Accessibility settings, then try again."
                    : (failure.isEmpty ? "Couldn't write the setting." : failure)
                // roll back anything written before the failure
                await restoreSettings(for: id)
                return
            }
            if tweak.needsAccessibilityAccess {
                // The write can succeed without the system honouring it; verify through the real state.
                try? await Task.sleep(for: .milliseconds(400))
                if !Self.isActive(tweak) {
                    errors[id] = "Saved, but macOS hasn't applied it yet. It may need Accessibility access or a re-login."
                }
            }
            await restart(tweak.restart)
        } else {
            await restoreSettings(for: id)
            await restart(tweak.restart)
        }
    }

    /// Puts every tweak back to the value it had before MacMaster changed it.
    func restoreAll() async {
        guard !isRestoring else { return }
        isRestoring = true; errors = [:]
        defer { isRestoring = false; refresh() }
        var restarts = Set<OptimizerTweakRestart>()
        // Only tweaks MacMaster changed; a hand-set value has no original and must not be deleted.
        for t in OptimizerTweakCatalog.all where originals[t.id] != nil && !busy.contains(t.id) {
            await restoreSettings(for: t.id)
            restarts.insert(t.restart)
        }
        for r in restarts { await restart(r) }
    }

    private func restoreSettings(for id: String) async {
        guard let tweak = OptimizerTweakCatalog.all.first(where: { $0.id == id }) else { return }
        let stored = originals[id] ?? tweak.settings.map { OptimizerStoredSetting(domain: $0.domain, key: $0.key, original: nil) }
        for s in stored {
            if let v = s.original {
                _ = await Shell.runAsync("/usr/bin/defaults", ["write", s.domain, s.key] + v.defaultsArgs, timeout: 15)
            } else {
                _ = await Shell.runAsync("/usr/bin/defaults", ["delete", s.domain, s.key], timeout: 15)
            }
        }
        originals[id] = nil
        persist()
    }

    private func restart(_ kind: OptimizerTweakRestart) async {
        switch kind {
        case .dock: _ = await Shell.runAsync("/usr/bin/killall", ["Dock"], timeout: 10)
        case .finder: _ = await Shell.runAsync("/usr/bin/killall", ["Finder"], timeout: 10)
        case .none, .logout: break
        }
    }

    private func persist() {
        Store.save(originals, to: "optimizer-tweak-originals.json")
        hasOriginals = !originals.isEmpty
    }

    static func openAccessibilitySettings() {
        let candidates = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.universalaccess"]
        for c in candidates { if let u = URL(string: c), NSWorkspace.shared.open(u) { return } }
    }
}
