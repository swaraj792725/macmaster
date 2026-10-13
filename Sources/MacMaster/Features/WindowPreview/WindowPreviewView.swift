import SwiftUI

struct WindowPreviewView: View {
    @ObservedObject private var settings = WindowPreviewSettings.shared
    @ObservedObject private var controller = WindowPreviewController.shared

    var body: some View {
        Page {
            PageHeader(title: "Window Previews",
                       subtitle: "A ⌘Tab switcher with live window previews, plus Dock hover thumbnails",
                       symbol: "macwindow.on.rectangle", colors: Theme.Palette.windows) {
                StatusPill(text: statusText, color: statusColor)
            }

            PermissionBanner(permission: .accessibility,
                             reason: "Needed to capture ⌘Tab, detect the Dock icon under the cursor, raise windows and read their titles.")
            PermissionBanner(permission: .screenRecording,
                             reason: "Needed for live window thumbnails. Without it the switcher shows large app icons with window titles.")

            WindowPreviewSwitcherMock(settings: settings)

            switcherSection.searchAnchor("windows.switcher")
            keysSection.searchAnchor("windows.keys")
            dockSection.searchAnchor("windows.dock")
        }
        .onAppear { WindowPreviewController.shared.start() }
    }

    private var statusText: String {
        if !controller.accessibilityGranted { return "Needs Accessibility" }
        if controller.dockRunning || controller.switcherRunning { return "Running" }
        return "Off"
    }

    private var statusColor: Color {
        if !controller.accessibilityGranted { return .orange }
        return controller.dockRunning || controller.switcherRunning ? .green : .gray
    }

    // MARK: Switcher

    private var switcherSection: some View {
        GroupedSection("Window switcher", symbol: "rectangle.on.rectangle.angled",
                       footer: "macOS only reports on-screen windows of the current Space. Windows on other Spaces are listed when macOS exposes them, but may show an icon instead of a live preview.") {
            SettingsRow(title: "Enable window switcher",
                        subtitle: "Hold the modifier and press Tab to cycle, release to jump to the window.",
                        symbol: "rectangle.on.rectangle.angled", colors: Theme.Palette.windows) {
                Toggle("", isOn: $settings.switcherEnabled).labelsHidden().toggleStyle(.switch)
            }
            if settings.switcherEnabled {
                SettingsRow(title: "Shortcut",
                            subtitle: settings.switcherShortcut == .commandTab
                                ? "Replaces the system ⌘Tab. ⌘⇧Tab goes backwards and ⌘` cycles the current app's windows."
                                : "⇧ reverses direction.") {
                    Picker("", selection: $settings.switcherShortcut) {
                        ForEach(WindowPreviewSwitcherShortcut.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 250)
                }
                SettingsRow(title: "Thumbnail size") {
                    Picker("", selection: $settings.switcherSize) {
                        ForEach(WindowPreviewThumbSize.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                toggleRow("Include minimized windows and hidden apps",
                          "Windows are found through Accessibility and shown dimmed.",
                          $settings.switcherIncludeHidden)
                toggleRow("Show apps without windows",
                          "Running apps that have no open window get an icon tile.",
                          $settings.switcherShowAppsWithoutWindows)
                toggleRow("Current Space only",
                          "Hide windows that live on other Spaces.",
                          $settings.switcherCurrentSpaceOnly)
                toggleRow("Prefetch thumbnails in the background",
                          "Keeps low-resolution previews ready so the switcher opens instantly. Pauses while you are idle.",
                          $settings.switcherPrefetch)
                toggleRow("Live-refresh the selected window",
                          "Updates the highlighted preview while the switcher is open.",
                          $settings.liveRefresh)
                if controller.accessibilityGranted && !controller.switcherRunning {
                    Label("The switcher hotkey couldn’t be installed. Try toggling it off and on.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
        }
    }

    private var keysSection: some View {
        GroupedSection("While the switcher is open", symbol: "keyboard") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(hints, id: \.0) { key, text in
                    HStack(spacing: 6) {
                        Text(key).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(text).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private let hints: [(String, String)] = [
        ("⇥ / ⇧⇥", "Next / previous"), ("← → ↑ ↓", "Move in grid"), ("Esc", "Cancel"),
        ("W", "Close window"), ("M", "Minimize"), ("Q", "Quit app"),
        ("H", "Hide app"), ("F", "Full screen"), ("Click", "Jump to window"),
    ]

    // MARK: Dock

    private var dockSection: some View {
        GroupedSection("Dock previews", symbol: "dock.rectangle",
                       footer: "Click a thumbnail to jump to it, middle-click to close.") {
            SettingsRow(title: "Show previews when hovering Dock icons", symbol: "dock.rectangle",
                        colors: Theme.Palette.blue) {
                Toggle("", isOn: $settings.dockPreviews).labelsHidden().toggleStyle(.switch)
            }
            if settings.dockPreviews {
                SettingsRow(title: "Hover delay") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.hoverDelay, in: 0.05...1.0).frame(width: 200)
                        Text(String(format: "%.2fs", settings.hoverDelay)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }
                }
                SettingsRow(title: "Thumbnail size") {
                    Picker("", selection: $settings.thumbSize) {
                        ForEach(WindowPreviewThumbSize.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                toggleRow("Show window titles", "", $settings.showTitles)
                toggleRow("Include minimized windows", "", $settings.showMinimized)
            }
        }
    }
}
