import SwiftUI
import AppKit
import Observation

// MARK: - Rules

enum WiFiRuleTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case join, leave
    var id: String { rawValue }
    var title: String { self == .join ? "When I join" : "When I leave" }
}

enum WiFiRuleAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcut, keepAwakeOn, keepAwakeOff, mute, unmute, openApp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcut: "Run Shortcut"
        case .keepAwakeOn: "Turn Keep Awake on"
        case .keepAwakeOff: "Turn Keep Awake off"
        case .mute: "Mute sound"
        case .unmute: "Unmute sound"
        case .openApp: "Open app"
        }
    }
    var symbol: String {
        switch self {
        case .shortcut: "square.stack.3d.up"
        case .keepAwakeOn, .keepAwakeOff: "cup.and.saucer"
        case .mute: "speaker.slash"
        case .unmute: "speaker.wave.2"
        case .openApp: "app.badge"
        }
    }
    var needsArgument: Bool { self == .shortcut || self == .openApp }
    var argumentLabel: String { self == .shortcut ? "Shortcut name" : "App name or path" }
}

/// "When I join <network> / leave Wi-Fi, do <action>." An empty `ssid` matches any network.
struct WiFiRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    var trigger: WiFiRuleTrigger = .join
    var ssid = ""
    var action: WiFiRuleAction = .shortcut
    var argument = ""

    var summary: String {
        let when: String
        switch trigger {
        case .join: when = ssid.isEmpty ? "Join any network" : "Join \(ssid)"
        case .leave: when = ssid.isEmpty ? "Leave Wi-Fi" : "Leave \(ssid)"
        }
        let what = action.needsArgument && !argument.isEmpty ? "\(action.title): \(argument)" : action.title
        return "\(when)  \u{2192}  \(what)"
    }
    var isComplete: Bool { !action.needsArgument || !argument.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Engine

/// Stores rules in UserDefaults and fires them when the SSID changes. Costs nothing while no rule is enabled:
/// `WiFiModel` only keeps its timer and link events alive for it when at least one rule exists.
@Observable
@MainActor
final class WiFiAutomations {
    static let shared = WiFiAutomations()
    private static let key = "wifi.automations"

    private(set) var rules: [WiFiRule] = []
    private(set) var lastRun: String?

    @ObservationIgnored private var lastSSID: String?          // nil = not on Wi-Fi
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var settle: Task<Void, Never>?

    var hasActiveRules: Bool { rules.contains { $0.enabled && $0.isComplete } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([WiFiRule].self, from: data) { rules = list }
    }

    func add(_ r: WiFiRule) { rules.append(r); save() }
    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; save() }
    func update(_ r: WiFiRule) {
        guard let i = rules.firstIndex(where: { $0.id == r.id }), rules[i] != r else { return }
        rules[i] = r; save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: Self.key) }
        WiFiModel.shared.reconfigure()
    }

    /// Called by the model after every link read. Waits a moment so roaming or a brief drop doesn't fire rules.
    func linkChanged(powerOn: Bool, connected: Bool, ssid: String?) {
        let now: String? = (powerOn && connected) ? (ssid ?? "") : nil
        if !primed { primed = true; lastSSID = now; return }
        guard now != lastSSID else { settle?.cancel(); return }
        guard hasActiveRules else { lastSSID = now; return }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let current: String? = {
                let l = WiFiModel.shared.link
                return (l.powerOn && l.isConnected) ? (l.ssid ?? "") : nil
            }()
            guard current != self.lastSSID else { return }
            let old = self.lastSSID
            self.lastSSID = current
            self.fire(from: old, to: current)
        }
    }

    private func fire(from old: String?, to new: String?) {
        for r in rules where r.enabled && r.isComplete {
            switch r.trigger {
            case .join:
                // Needs the network name; with Location off the SSID is empty so only "any network" rules can match.
                guard let new else { continue }
                if r.ssid.isEmpty || r.ssid == new { run(r) }
            case .leave:
                guard let old else { continue }
                // "Leave X" fires when X is no longer the connection; "Leave Wi-Fi" only on a full disconnect.
                if r.ssid.isEmpty ? new == nil : (r.ssid == old && r.ssid != new) { run(r) }
            }
        }
    }

    func run(_ r: WiFiRule) {
        lastRun = "\(r.summary) · \(Date.now.formatted(date: .omitted, time: .shortened))"
        let arg = r.argument.trimmingCharacters(in: .whitespaces)
        switch r.action {
        case .shortcut:
            Task.detached(priority: .utility) { _ = Shell.run("/usr/bin/shortcuts", ["run", arg], timeout: 120) }
        case .keepAwakeOn: ToolsKeepAwake.shared.begin(.indefinite)
        case .keepAwakeOff: ToolsKeepAwake.shared.stop()
        case .mute: MenuBarSystem.setMuted(true)
        case .unmute: MenuBarSystem.setMuted(false)
        case .openApp: Self.open(arg)
        }
    }

    private static func open(_ nameOrPath: String) {
        let ws = NSWorkspace.shared
        let url: URL?
        if nameOrPath.hasPrefix("/") || nameOrPath.hasPrefix("~") {
            url = URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath)
        } else {
            url = ws.urlForApplication(withBundleIdentifier: nameOrPath)
                ?? ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities"]
                    .map { URL(fileURLWithPath: "\($0)/\(nameOrPath).app") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let url { ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
    }
}

// MARK: - Editor card

struct WiFiAutomationsCard: View {
    @State private var auto = WiFiAutomations.shared
    @State private var adding = false
    @State private var draft = WiFiRule()
    private let model = WiFiModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Color.accentColor)
                Text("Network automations").font(.headline)
                Spacer()
                if !adding {
                    Button { draft = WiFiRule(ssid: model.link.ssid ?? ""); adding = true } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                    .buttonStyle(.mmSecondary)
                }
            }
            Text("Run something when you join or leave a network. Checked a few seconds after the change.")
                .font(.caption).foregroundStyle(.secondary)

            if auto.rules.isEmpty, !adding {
                Text("No rules yet. Example: when I join \u{201C}Office\u{201D}, run the Shortcut \u{201C}Focus\u{201D}.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(auto.rules) { r in ruleRow(r) }
            if adding { editor }
            if let last = auto.lastRun {
                Text("Last run: \(last)").font(.caption2).foregroundStyle(.tertiary)
            }
            if !model.locationGranted {
                Label("Rules for a named network need Location access, because macOS hides the network name without it.",
                      systemImage: "location.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private func ruleRow(_ r: WiFiRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.action.symbol).frame(width: 20).foregroundStyle(r.enabled ? Color.accentColor : .secondary)
            Text(r.summary).font(.callout).lineLimit(2).foregroundStyle(r.enabled ? .primary : .secondary)
            Spacer(minLength: 6)
            Button { auto.run(r) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.mmGhost).help("Run now").disabled(!r.isComplete)
            Toggle("", isOn: Binding(get: { r.enabled }, set: { var c = r; c.enabled = $0; auto.update(c) }))
                .toggleStyle(.mmSwitch).labelsHidden()
            Button { auto.remove(r.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.mmGhost).help("Delete")
        }
        .padding(.vertical, 2)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $draft.trigger) {
                    ForEach(WiFiRuleTrigger.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                TextField(draft.trigger == .join ? "Network name (empty = any)" : "Network name (empty = any disconnect)",
                          text: $draft.ssid)
                    .textFieldStyle(.roundedBorder)
                if let s = model.link.ssid, s != draft.ssid {
                    Button("Use \(s)") { draft.ssid = s }.buttonStyle(.mmGhost)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $draft.action) {
                    ForEach(WiFiRuleAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                if draft.action.needsArgument {
                    TextField(draft.action.argumentLabel, text: $draft.argument).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }.buttonStyle(.mmGhost)
                Button("Save") { auto.add(draft); adding = false }
                    .buttonStyle(.mmPrimary).disabled(!draft.isComplete)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
