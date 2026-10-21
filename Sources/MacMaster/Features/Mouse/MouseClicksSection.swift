import SwiftUI

/// "Clicks" group on the Mouse page: click debounce for mice that register one click twice.
struct MouseClicksSection: View {
    private typealias K = WindowExtrasSettings.Key
    @AppStorage(K.debounce) private var debounce = false
    @AppStorage(K.debounceMs) private var ms = WindowExtrasSettings.defaultDebounceMs
    @AppStorage(K.debounceRight) private var includeRight = false

    private let engine = WindowExtrasEngine.shared

    var body: some View {
        GroupedSection("Clicks", symbol: "cursorarrow.click.2",
                       footer: "A real double-click leaves at least 80 ms between releasing the button and pressing it again, so 60 ms is safe for normal use. Raise it only if the mouse still double-clicks; a very high value can swallow fast genuine double-clicks.") {
            if debounce { WindowExtrasPermissionRow(reason: "Click filtering listens to mouse buttons through Accessibility.") }
            SettingsRow(title: "Fix double-clicks", subtitle: "Ignore a button press that follows a release too quickly, like a worn mouse that clicks twice",
                        symbol: "cursorarrow.click.badge.clock", colors: Theme.Palette.orange) {
                Toggle("", isOn: $debounce).labelsHidden().toggleStyle(.switch)
            }
            if debounce {
                SettingsRow(title: "Ignore presses within", subtitle: "Time after releasing a button",
                            symbol: "timer", colors: Theme.Palette.gray) {
                    HStack(spacing: 8) {
                        Slider(value: $ms.snapped(5), in: WindowExtrasSettings.debounceRange).frame(width: 150)
                        Text("\(Int(ms)) ms")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                }
                SettingsRow(title: "Also filter the right button", symbol: "cursorarrow.click", colors: Theme.Palette.gray) {
                    Toggle("", isOn: $includeRight).labelsHidden().toggleStyle(.switch)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let n = engine.blockedClicks
                    SettingsRow(title: "Blocked \(n) chattering click\(n == 1 ? "" : "s")",
                                subtitle: "Counted since you turned this on",
                                symbol: "shield.lefthalf.filled", colors: Theme.Palette.green) {
                        Button("Reset") { engine.resetBlockedClicks() }
                            .buttonStyle(.mmSecondary).disabled(n == 0)
                    }
                }
            }
        }
        .searchAnchor("mouse.clicks")
    }
}

/// Shown inside a section while Accessibility is missing, with a Grant button.
struct WindowExtrasPermissionRow: View {
    let reason: String

    var body: some View {
        if !PermissionWatcher.shared.isGranted(.accessibility) {
            SettingsRow(title: "Accessibility needed", subtitle: reason,
                        symbol: "lock.shield.fill", colors: Theme.Palette.orange) {
                Button("Grant") { Permissions.request(.accessibility) }
                    .buttonStyle(.mmPrimary)
            }
        }
    }
}
