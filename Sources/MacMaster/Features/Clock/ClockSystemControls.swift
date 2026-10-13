import SwiftUI
import AppKit

/// System time operations. Anything that changes the system goes through the system's own admin prompt.
enum ClockSystem {
    enum Outcome: Sendable { case ok, cancelled, failed(String) }

    /// "Set time automatically", read from the timed preferences if that file is readable without admin. nil = unknown.
    static func autoTimeEnabled() -> Bool? {
        guard let data = FileManager.default.contents(atPath: "/Library/Preferences/com.apple.timed.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = plist["TMAutomaticTimeEnabled"] as? Bool else { return nil }
        return v
    }

    private static func outcome(_ r: Shell.Result) -> Outcome {
        if r.ok { return .ok }
        if r.status == -128 || r.stderr.localizedCaseInsensitiveContains("cancel") { return .cancelled }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(msg.isEmpty ? "The command failed." : msg)
    }

    /// Sets the system time zone after validating the identifier against the known list.
    static func setTimeZone(_ id: String) async -> Outcome {
        guard TimeZone.knownTimeZoneIdentifiers.contains(id) else { return .failed("Unknown time zone.") }
        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/usr/sbin/systemsetup", ["-settimezone", id],
                             prompt: "MacMaster wants to change the time zone to \(id).")
        }.value
        let o = outcome(r)
        if case .ok = o { await MainActor.run { NSTimeZone.resetSystemTimeZone(); ClockMenuBar.shared.settingsChanged() } }
        return o
    }

    /// One-shot sync against Apple's time server.
    static func syncNow() async -> Outcome {
        let r = await Task.detached(priority: .userInitiated) {
            Shell.runAsAdmin("/usr/bin/sntp", ["-sS", "time.apple.com"], prompt: "MacMaster wants to sync the clock with time.apple.com.")
        }.value
        let o = outcome(r)
        if case .ok = o { await MainActor.run { ClockMenuBar.shared.settingsChanged() } }
        return o
    }

    static func openDateTimeSettings() { open("com.apple.Date-Time-Settings.extension") }
    static func openControlCenterSettings() { open("com.apple.ControlCenter-Settings.extension") }

    private static func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// Popover tab: shows the system zone and offers to change it or sync the clock.
struct ClockSystemTab: View {
    @State private var pickedZone: String?
    @State private var query = ""
    @State private var busy = false
    @State private var message: String?
    @State private var changing = false

    private var zone: TimeZone { .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                info
                if changing { changer } else {
                    actionButton("Change system time zone\u{2026}", "globe") { changing = true }
                }
                actionButton("Sync time now", "arrow.triangle.2.circlepath") { run { await ClockSystem.syncNow() } }
                actionButton("Open Date & Time Settings", "gearshape") { ClockSystem.openDateTimeSettings() }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Changing the system time zone or syncing the clock asks for your administrator password through macOS. MacMaster never sees it.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Time zone", zone.identifier)
            row("Offset", ClockZones.offsetString(zone, at: Date()) + (zone.isDaylightSavingTime() ? " (DST)" : ""))
            if let auto = ClockSystem.autoTimeEnabled() { row("Set time automatically", auto ? "On" : "Off") }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).fontWeight(.medium) }.font(.callout)
    }

    private var changer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose the new system time zone").font(.callout.weight(.semibold))
            ClockZoneSearchList(selected: pickedZone, height: 170) { pickedZone = $0 }
            HStack {
                Button("Cancel") { changing = false; pickedZone = nil }.buttonStyle(.mmGhost)
                Spacer()
                Button(pickedZone.map { "Set to \($0)" } ?? "Pick a zone") {
                    guard let id = pickedZone else { return }
                    changing = false
                    run { await ClockSystem.setTimeZone(id) }
                }
                .buttonStyle(.mmPrimary).disabled(pickedZone == nil || busy)
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: symbol).frame(width: 20); Text(title); Spacer() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.mmSecondary).disabled(busy)
    }

    private func run(_ op: @escaping () async -> ClockSystem.Outcome) {
        busy = true; message = nil
        Task {
            let o = await op()
            busy = false
            switch o {
            case .ok: message = "Done."
            case .cancelled: message = "Cancelled."
            case .failed(let m): message = m
            }
        }
    }
}
