import SwiftUI
import AppKit
import Observation

// MARK: - Model

@Observable
@MainActor
final class PowerPmsetModel {
    private(set) var original = PowerPmsetSnapshot()
    var edited = PowerPmsetSnapshot()
    private(set) var loading = false
    private(set) var busy = false
    private(set) var loaded = false
    var error: String?
    var notice: String?

    /// Scopes that `pmset -g custom` actually reported (desktops have no Battery section).
    var scopes: [PowerScope] { PowerScope.allCases.filter { !(original.values[$0] ?? [:]).isEmpty } }

    func load() async {
        loading = true
        defer { loading = false }
        let snap = await Task.detached(priority: .utility) { () -> PowerPmsetSnapshot in
            PowerParsers.parseCustom(Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 10).stdout)
        }.value
        original = snap; edited = snap; loaded = true
    }

    func changes(in scope: PowerScope) -> [(key: String, value: Int)] {
        let o = original.values[scope] ?? [:], e = edited.values[scope] ?? [:]
        return PowerPmsetKey.all.compactMap { def in
            guard let ov = o[def.key], let ev = e[def.key], ov != ev else { return nil }
            return (def.key, ev)
        }
    }

    var changeCount: Int { PowerScope.allCases.reduce(0) { $0 + changes(in: $1).count } }

    func value(_ key: String, _ scope: PowerScope) -> Int? { edited.values[scope]?[key] }
    func set(_ key: String, _ scope: PowerScope, _ v: Int) { edited.values[scope, default: [:]][key] = v }
    func isModified(_ key: String, _ scope: PowerScope) -> Bool {
        guard let o = original.values[scope]?[key], let e = edited.values[scope]?[key] else { return false }
        return o != e
    }
    func revert() { edited = original }

    /// All changes go out as one `pmset -b ... -c ...` call behind a single password prompt.
    func apply() async {
        var args: [String] = []
        for scope in PowerScope.allCases {
            let ch = changes(in: scope)
            guard !ch.isEmpty else { continue }
            args.append(scope.flag)
            for c in ch { args += [c.key, String(c.value)] }
        }
        guard !args.isEmpty else { return }
        await runAdmin(args, prompt: "MacMaster wants to change your power settings.", success: "Settings applied.")
    }

    func restoreDefaults() async {
        await runAdmin(["restoredefaults"], prompt: "MacMaster wants to restore the factory power settings.",
                       success: "Power settings restored to defaults.")
    }

    private func runAdmin(_ args: [String], prompt: String, success: String) async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/usr/bin/pmset", args, prompt: prompt)
        }.value
        if r.ok { notice = success }
        else if !r.stderr.lowercased().contains("cancel") { error = r.stderr.isEmpty ? "pmset failed." : r.stderr }
        await load()
    }
}

// MARK: - Tab

struct PowerSettingsTab: View {
    @State private var model = PowerPmsetModel()
    @State private var scope: PowerScope = .battery
    @State private var confirmRestore = false
    private let battery = BatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            header
            if !model.loaded && model.loading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading power settings…").foregroundStyle(.secondary) }.card()
            } else if model.scopes.isEmpty {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "No power settings found",
                               message: "pmset did not report any settings for this Mac.").card()
            } else {
                settingsList
                actionBar
            }
            if let n = model.notice { PowerCallout(symbol: "checkmark.circle.fill", title: n, message: "", color: Color(hex: 0x30D158)) }
            if let e = model.error { PowerCallout(symbol: "exclamationmark.triangle.fill", title: "Couldn't apply", message: e) }
            chargeLimit
        }
        .task { await model.load() }
        .onChange(of: model.scopes) { _, new in if !new.contains(scope), let f = new.first { scope = f } }
        .confirmationDialog("Restore factory power settings?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { Task { await model.restoreDefaults() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets every sleep, wake and power setting to the macOS default for both battery and power adapter. You'll be asked for your password.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "slider.horizontal.3", colors: Theme.Palette.gray, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Power settings").font(.headline)
                Text("The same values as the pmset command, with plain-language names. Only settings your Mac supports are shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.scopes.count > 1 {
                Picker("Power source", selection: $scope) {
                    ForEach(model.scopes) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
        }
        .card()
    }

    private var settingsList: some View {
        let active = model.scopes.contains(scope) ? scope : (model.scopes.first ?? .battery)
        let defs = PowerPmsetKey.all.filter { model.value($0.key, active) != nil }
        return GroupedSection(active.title, symbol: active.symbol,
                              footer: "Changes are applied together when you press Apply. Battery and Power Adapter settings are separate.") {
            ForEach(defs) { def in
                PowerPmsetRow(def: def, scope: active, model: model)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { Task { await model.apply() } } label: {
                Text(model.changeCount == 0 ? "Apply" : "Apply \(model.changeCount) Change\(model.changeCount == 1 ? "" : "s")")
            }
            .buttonStyle(.mmPrimary).disabled(model.changeCount == 0 || model.busy)
            Button("Revert") { model.revert() }.buttonStyle(.mmSecondary).disabled(model.changeCount == 0 || model.busy)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Restore Defaults…") { confirmRestore = true }
                .buttonStyle(.mmSecondary(tint: Color(hex: 0xFF3B30))).disabled(model.busy)
        }
    }

    // MARK: Charge limit

    private var chargeLimit: some View {
        let r = battery.reading
        let state: String = {
            guard r.isPresent else { return "No battery" }
            switch r.optimizedCharging {
            case .some(true): return "On"
            case .some(false): return "Off"
            case .none: return "Unknown"
            }
        }()
        return GroupedSection("Battery charge limit", symbol: "battery.100.bolt",
                              footer: "On Apple silicon the charge limit is enforced by the system's battery management. Setting a custom limit needs a privileged background helper, which MacMaster doesn't install. Optimized Battery Charging is the built-in way to reduce battery aging.") {
            SettingsRow(title: "Optimized Battery Charging",
                        subtitle: "Learns your routine and holds the battery at 80% until you need it.",
                        symbol: "bolt.badge.clock.fill", colors: Theme.Palette.green) {
                StatusPill(text: state, color: state == "On" ? Color(hex: 0x30D158) : .secondary)
            }
            if r.isPresent {
                SettingsRow(title: "Current charge", value: Fmt.percent(r.percent),
                            subtitle: r.isPluggedIn && !r.isCharging && !r.isFullyCharged ? "Charging is paused by the system." : nil,
                            symbol: "battery.75percent", colors: Theme.Palette.teal)
            }
            SettingsRow(title: "Change in System Settings",
                        subtitle: "Battery › Charging", symbol: "gearshape.fill", colors: Theme.Palette.gray) {
                Button("Open Battery Settings") { Self.openBatterySettings() }.buttonStyle(.mmSecondary)
            }
        }
    }

    private static func openBatterySettings() {
        for s in ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                  "x-apple.systempreferences:com.apple.preference.battery"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}

// MARK: - Row

private struct PowerPmsetRow: View {
    let def: PowerPmsetKey
    let scope: PowerScope
    let model: PowerPmsetModel

    var body: some View {
        let value = model.value(def.key, scope) ?? 0
        let modified = model.isModified(def.key, scope)
        SettingsRow(title: def.title, subtitle: def.detail, symbol: def.symbol, colors: def.colors) {
            HStack(spacing: 8) {
                if modified { Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Changed") }
                control(value)
            }
        }
    }

    @ViewBuilder
    private func control(_ value: Int) -> some View {
        let binding = Binding<Int>(get: { model.value(def.key, scope) ?? 0 }, set: { model.set(def.key, scope, $0) })
        switch def.control {
        case .toggle:
            Toggle("", isOn: Binding(get: { binding.wrappedValue != 0 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
                .labelsHidden().toggleStyle(.switch)
        case .minutes:
            let presets = Array(Set([0, 1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, value])).sorted()
            Picker(def.title, selection: binding) {
                ForEach(presets, id: \.self) { m in Text(Self.minutesLabel(m)).tag(m) }
            }
            .labelsHidden().fixedSize()
        case .picker(let options):
            let all = options.contains { $0.value == value } ? options : options + [(value, "\(value)")]
            Picker(def.title, selection: binding) {
                ForEach(all, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private static func minutesLabel(_ m: Int) -> String {
        if m == 0 { return "Never" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) hr" : "\(m) min"
    }
}
