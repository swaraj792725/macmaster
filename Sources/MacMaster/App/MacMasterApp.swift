import SwiftUI
import ServiceManagement

@main
struct MacMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MacMaster", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateChecker.shared.check(userInitiated: true) }
                    WhatsNewWindow.show()
                }
                Button("What's New in MacMaster") { WhatsNewWindow.show() }
            }
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, s in
                    let button = Button(s.title) { NotificationCenter.default.post(name: .openSection, object: s.rawValue) }
                    if index < 9 {
                        button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else if index == 9 {
                        button.keyboardShortcut("0", modifiers: .command)
                    } else {
                        button
                    }
                }
            }
        }

        Settings {
            TabView {
                AppSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                MenuBarSettingsView()
                    .frame(width: 500, height: 520)
                    .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hideDock = UserDefaults.standard.bool(forKey: "mm.app.hideDockIcon")
        NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
        if !Onboarding.isNeeded { Notifier.requestAuthorization() }
        Services.startAll()
        if !Services.isSnapshotRun { MainStatusItem.shared.update() }
        DebugSnapshot.runIfRequested()
        if !Services.isSnapshotRun { Onboarding.showIfNeeded() }
        NotificationCenter.default.addObserver(forName: Onboarding.preferencesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainStatusItem.shared.update() }
        }
        MenuBarManagerDiagnostics.runIfRequested()
        if ProcessInfo.processInfo.environment["MM_CLOSE_WINDOW"] != nil { // dev: measure background idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.windows.filter { $0.frame.width > 600 }.forEach { $0.close() } }
        }
    }

    /// Reopen the main window when the Dock icon is clicked with no windows open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    /// Undo temporary system state (hidden menu bar icons, key remaps, closed-lid awake).
    func applicationWillTerminate(_ notification: Notification) {
        MenuBarManager.shared.stop()
        KeyboardEngine.shared.stop()
        PowerScheduler.shared.stop()
    }

    /// Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Starts every background service. Each service checks its own enable flag.
@MainActor
enum Services {
    /// Snapshot runs are a second copy of the app: skip anything that grabs global input or the menu bar.
    static var isSnapshotRun: Bool { ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] != nil }

    static func startAll() {
        SystemMonitor.shared.start()
        BatteryMonitor.shared.start()
        HealthMonitor.shared.start()
        MenuBarHooks.quickOptimize = { await OptimizerEngine.shared.quickOptimize() }
        MenuBarHooks.freeMemory = { await OptimizerEngine.shared.freeMemory() }
        if isSnapshotRun { return }
        FrontAppTracker.start()
        CleanerScheduler.shared.start()
        StatsMenuBarController.shared.start()
        MouseEngine.shared.start()
        WindowPreviewController.shared.start()
        ToolsClipboard.shared.start()
        ToolsClipboardMenuBar.shared.update()
        UninstallerDeletionWatcher.shared.start()
        DropShelf.shared.start()
        WiFiMenuBar.shared.update()
        AppleItemRedirect.shared.update()
        ClockMenuBar.shared.update()
        DropShelfMenuBar.shared.update()
        ToolsKeepAwake.shared.start()
        OptimizerEngine.shared.start()
        MenuBarManager.shared.start()
        TilingEngine.shared.start()
        PowerScheduler.shared.start()
        KeyboardEngine.shared.start()
        UpdateChecker.shared.start()
        WhatsNewWindow.showIfUpdated()
    }
}

struct AppSettingsView: View {
    @AppStorage("mm.app.hideDockIcon") private var hideDockIcon = false
    @AppStorage("mm.app.showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var monitor = SystemMonitor.shared
    @State private var loginError: String?
    @State private var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                settingRow("Launch at login", "power", Theme.Palette.green) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                settingRow("Hide Dock icon", "dock.rectangle", Theme.Palette.gray) {
                    Toggle("", isOn: $hideDockIcon).labelsHidden().toggleStyle(.switch)
                }
                .onChange(of: hideDockIcon) { _, hide in NSApp.setActivationPolicy(hide ? .accessory : .regular) }
                settingRow("Show menu bar icon", "menubar.rectangle", Theme.Palette.blue) {
                    Toggle("", isOn: $showMenuBarIcon).labelsHidden().toggleStyle(.switch)
                }
                .onChange(of: showMenuBarIcon) { _, _ in MainStatusItem.shared.update() }
            } header: { Text("General") } footer: {
                Text("Hide the Dock icon to run MacMaster from the menu bar only.")
            }
            Section {
                settingRow("Check for updates automatically", "arrow.triangle.2.circlepath", Theme.Palette.green) {
                    Toggle("", isOn: Binding(get: { updates.autoCheck }, set: { updates.autoCheck = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                HStack(spacing: 10) {
                    IconTile(symbol: "shippingbox", colors: Theme.Palette.blue, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Version \(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))")
                        if let d = updates.lastCheck {
                            Text("Last checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    UpdateStatusControl(compact: true)
                }
                Button("What's New…") { WhatsNewWindow.show() }
            } header: { Text("Updates") } footer: {
                Text("Looks for new releases on GitHub once a day. Nothing is installed without you.")
            }
            Section("Monitoring") {
                settingRow("Sample interval", "timer", Theme.Palette.indigo) {
                    Picker("", selection: Binding(get: { monitor.interval }, set: { monitor.interval = $0 })) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("5 seconds").tag(5.0)
                    }
                    .labelsHidden().frame(width: 120)
                }
            }
            Section("Permissions") {
                ForEach(Permission.allCases) { p in
                    PermissionRow(permission: p)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
    }

    private func settingRow<T: View>(_ title: String, _ symbol: String, _ colors: [Color],
                                     @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, colors: colors, size: 24)
            Text(title)
            Spacer()
            trailing()
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @State private var granted = false
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: granted ? "checkmark.shield.fill" : "lock.shield.fill",
                     colors: granted ? Theme.Palette.green : Theme.Palette.orange, size: 24)
            Text(permission.title)
            Spacer()
            if granted {
                StatusPill(text: "Granted", color: .green)
            } else {
                Button("Grant") { Permissions.request(permission) }.buttonStyle(.mmSecondary)
            }
        }
        .onAppear { granted = Permissions.isGranted(permission) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            granted = Permissions.isGranted(permission)
        }
    }
}
