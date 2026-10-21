import AppKit
import SwiftUI

/// "Window behavior" group on the Windows page: Dock click minimize, quit on last window, green button.
struct WindowBehaviorSection: View {
    private typealias K = WindowExtrasSettings.Key
    @AppStorage(K.dockMinimize) private var dockMinimize = false
    @AppStorage(K.quitOnLastClose) private var quitOnClose = false
    @AppStorage(K.greenMaximize) private var greenMaximize = false
    @State private var userExcluded = WindowExtrasSettings.userExcluded

    var body: some View {
        GroupedSection("Window behavior", symbol: "macwindow",
                       footer: "Hold ⌥ while clicking the green button to enter full screen. Quit on last window uses a normal Quit, so apps still ask about unsaved changes.") {
            if dockMinimize || quitOnClose || greenMaximize {
                WindowExtrasPermissionRow(reason: "These options watch clicks and read windows through Accessibility.")
            }
            SettingsRow(title: "Click Dock icon to minimize",
                        subtitle: "Clicking the Dock icon of the app you are already in minimizes its windows. Click again to bring them back.",
                        symbol: "dock.rectangle", colors: Theme.Palette.blue) {
                Toggle("", isOn: $dockMinimize).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Quit app when its last window closes",
                        subtitle: "Closing the last window with the red button or ⌘W quits the app, like on Windows",
                        symbol: "xmark.app", colors: Theme.Palette.red) {
                Toggle("", isOn: $quitOnClose).labelsHidden().toggleStyle(.switch)
            }
            if quitOnClose { exclusions }
            SettingsRow(title: "Green button maximizes",
                        subtitle: "Fill the screen instead of entering full screen. Click again to restore the old size.",
                        symbol: "arrow.up.left.and.arrow.down.right", colors: Theme.Palette.green) {
                Toggle("", isOn: $greenMaximize).labelsHidden().toggleStyle(.switch)
            }
        }
        .searchAnchor("windows.behavior")
    }

    // MARK: Keep-open list

    @ViewBuilder private var exclusions: some View {
        SettingsRow(title: "Keep these apps open", subtitle: "Apps that run without windows (menu bar apps) are never quit",
                    symbol: "lock.fill", colors: Theme.Palette.gray) {
            addMenu
        }
        ForEach(WindowExtrasSettings.builtInExcluded, id: \.self) { id in
            ExcludedAppRow(bundleID: id, locked: true) {}
        }
        ForEach(userExcluded, id: \.self) { id in
            ExcludedAppRow(bundleID: id, locked: false) {
                userExcluded.removeAll { $0 == id }
                WindowExtrasSettings.userExcluded = userExcluded
            }
        }
    }

    private var addMenu: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && !WindowExtrasSettings.excluded.contains($0.bundleIdentifier ?? "")
            }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            ForEach(running, id: \.processIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "App") { add(app.bundleIdentifier) }
            }
            if !running.isEmpty { Divider() }
            Button("Choose app…") { choose() }
        } label: {
            Label("Add app", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.mmSecondary)
        .fixedSize()
    }

    private func add(_ id: String?) {
        guard let id, !WindowExtrasSettings.excluded.contains(id) else { return }
        userExcluded.append(id)
        WindowExtrasSettings.userExcluded = userExcluded
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Keep open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(Bundle(url: url)?.bundleIdentifier)
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    let locked: Bool
    let remove: () -> Void

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if locked {
                Image(systemName: "lock.fill").foregroundStyle(.tertiary).help("Always kept open")
            } else {
                Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Remove from the list")
            }
        }
        .padding(.leading, 40)
    }

    private var name: String {
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
