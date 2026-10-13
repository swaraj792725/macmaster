import SwiftUI
import AppKit

/// Apple's Control Center and Clock: left alone by default. MacMaster's dropdown lives on its own menu bar icon;
/// optionally a click on Apple's icon can open MacMaster's dropdown or Clock instead.
struct ControlCenterView: View {
    @State private var settings = ControlCenterSettings.shared
    @State private var redirect = AppleItemRedirect.shared

    var body: some View {
        Page {
            PageHeader(title: "Control Center & Clock",
                       subtitle: "Apple's Control Center keeps working as usual. MacMaster's own icon opens its dropdown with your toggles, display and sound.",
                       symbol: "switch.2", colors: Theme.Palette.indigo)
            if settings.redirectControlCenter || settings.redirectClock {
                PermissionBanner(permission: .accessibility,
                                 reason: "Click redirect needs Accessibility to find Apple's icons and catch the click.")
            }
            redirectSection
            menuBarSection
        }
        .onAppear { redirect.update() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if redirect.status == .needsAccessibility { redirect.update() }
        }
    }

    private var redirectSection: some View {
        GroupedSection("Apple's icons (optional)", symbol: "cursorarrow.click.2",
                       footer: "Apple's icon stays in the menu bar; with a switch on, clicking it opens MacMaster instead. Hold Shift, Option, Command or Control while clicking to reach Apple's original.") {
            SettingsRow(title: "Apple's Control Center opens MacMaster's dropdown",
                        subtitle: foundLine(redirect.foundControlCenter, enabled: settings.redirectControlCenter),
                        symbol: "switch.2", colors: Theme.Palette.indigo) {
                Toggle("", isOn: $settings.redirectControlCenter).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Apple's clock opens MacMaster's Clock",
                        subtitle: foundLine(redirect.foundClock, enabled: settings.redirectClock),
                        symbol: "clock.fill", colors: Theme.Palette.orange) {
                Toggle("", isOn: $settings.redirectClock).toggleStyle(.switch).labelsHidden()
            }
            if settings.redirectControlCenter || settings.redirectClock {
                SettingsRow(title: "Status", subtitle: statusDetail, symbol: statusSymbol, colors: statusColors) {
                    HStack(spacing: 8) {
                        Text(statusLabel).font(.callout.weight(.semibold)).foregroundStyle(statusColor)
                        Button { redirect.update(); redirect.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.mmGhost).help("Check again")
                    }
                }
            }
        }
    }

    private var menuBarSection: some View {
        GroupedSection("Hide Apple's icons", symbol: "menubar.rectangle",
                       footer: "macOS doesn't let apps remove Apple's menu bar icons. Choose \"Don't Show in Menu Bar\" for an item in System Settings > Menu Bar.") {
            SettingsRow(title: "Open Menu Bar settings", subtitle: "Pick which Apple items appear in the menu bar.",
                        symbol: "gearshape.fill", colors: Theme.Palette.gray) {
                Button("Open") { settings.openMenuBarSettings() }.buttonStyle(.mmSecondary)
            }
        }
    }

    private var statusLabel: String {
        switch redirect.status {
        case .off: "Off"
        case .needsAccessibility: "Needs Accessibility"
        case .failed: "Can't listen"
        case .notFound: "Apple icon not found"
        case .active: "Active"
        }
    }

    private var statusDetail: String {
        switch redirect.status {
        case .off: "Off."
        case .needsAccessibility: "Grant Accessibility above so MacMaster can find Apple's icons and catch the click."
        case .failed: "Couldn't start the click listener. Check Accessibility (and Input Monitoring) access, then press check again."
        case .notFound: "Listening, but Apple's icon wasn't located in the menu bar yet."
        case .active: "Listening. Click Apple's icon to try it."
        }
    }

    private var statusColor: Color {
        switch redirect.status {
        case .active: .green
        case .off: .secondary
        case .needsAccessibility, .notFound: .orange
        case .failed: .red
        }
    }

    private var statusColors: [Color] {
        switch redirect.status {
        case .active: Theme.Palette.green
        case .off: Theme.Palette.gray
        case .needsAccessibility, .notFound: Theme.Palette.orange
        case .failed: Theme.Palette.red
        }
    }

    private var statusSymbol: String {
        switch redirect.status {
        case .active: "checkmark.circle.fill"
        case .off: "pause.circle.fill"
        case .needsAccessibility, .notFound, .failed: "exclamationmark.triangle.fill"
        }
    }

    private func foundLine(_ found: Bool, enabled: Bool) -> String {
        guard enabled else { return "Off. Clicking Apple's icon opens Apple's popover." }
        switch redirect.status {
        case .needsAccessibility: return "Waiting for Accessibility access."
        case .failed: return "Click listener not running."
        case .off: return "Off."
        default: return found ? "Apple's icon found in the menu bar." : "Apple's icon not found yet (rechecks every few seconds)."
        }
    }
}
