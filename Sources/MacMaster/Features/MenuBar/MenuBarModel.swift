import SwiftUI
import AppKit
import Observation

struct MenuBarToast: Equatable {
    var text: String
    var isError: Bool
}

struct MenuBarConfirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var run: () -> Void
}

/// State + actions behind the Control Center popover. System calls run off the main thread.
@Observable
@MainActor
final class MenuBarModel {
    static let shared = MenuBarModel()

    private(set) var snapshot = MenuBarSnapshot()
    private(set) var smoothScrollOn = false
    private(set) var windowSwitcherOn = false
    private(set) var busy: Set<String> = []
    private(set) var toast: MenuBarToast?
    private(set) var prefsRevision = 0
    var confirm: MenuBarConfirm?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var prefsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPrefsSignature = MenuBarPrefs.signature()
    @ObservationIgnored private var holdingProcesses = false
    @ObservationIgnored private let tools = ToolsQuickActionsModel()

    private init() {
        prefsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = MenuBarPrefs.signature()
                if s != self.lastPrefsSignature { self.lastPrefsSignature = s; self.prefsRevision += 1 }
            }
        }
    }

    // MARK: Availability

    func isActionVisible(_ a: MenuBarQuickAction) -> Bool {
        _ = prefsRevision
        guard MenuBarPrefs.isOn(a.key) else { return false }
        switch a {
        case .optimize: return MenuBarHooks.quickOptimize != nil
        case .freeRAM: return MenuBarHooks.freeMemory != nil
        default: return true
        }
    }

    func isSectionVisible(_ s: MenuBarSection) -> Bool {
        _ = prefsRevision
        return MenuBarPrefs.isOn(s.key)
    }

    func isOn(_ t: MenuBarTile) -> Bool {
        switch t {
        case .hideDesktop: snapshot.hideDesktop
        case .hiddenFiles: snapshot.hiddenFiles
        case .smoothScroll: smoothScrollOn
        case .windowSwitcher: windowSwitcherOn
        }
    }

    func subtitle(_ t: MenuBarTile) -> String { isOn(t) ? "On" : "Off" }

    // MARK: Lifecycle

    /// One refresh per open; nothing polls while the dropdown is closed or open.
    func appeared() { refresh() }

    func disappeared() {
        releaseProcesses()
        confirm = nil
    }

    func acquireProcesses() {
        guard !holdingProcesses else { return }
        holdingProcesses = true
        SystemMonitor.shared.requestProcesses()
    }

    func releaseProcesses() {
        guard holdingProcesses else { return }
        holdingProcesses = false
        SystemMonitor.shared.releaseProcesses()
    }

    func refresh() {
        SystemMonitor.shared.start()
        Task {
            let s = await Task.detached(priority: .utility) { MenuBarSystem.snapshot() }.value
            apply(s)
        }
    }

    private func apply(_ s: MenuBarSnapshot) {
        snapshot = s
        smoothScrollOn = MouseSettings.shared.enabled && MouseSettings.shared.config.smoothEnabled
        windowSwitcherOn = WindowPreviewSettings.shared.switcherEnabled
    }

    // MARK: Toast

    func showToast(_ text: String, error: Bool = false) {
        toastTask?.cancel()
        withAnimation(.smooth) { toast = MenuBarToast(text: text, isError: error) }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: error ? 5_000_000_000 : 3_000_000_000)
            if !Task.isCancelled { withAnimation(.smooth) { toast = nil } }
        }
    }

    /// Runs `work` off the main actor; nil result means success.
    private func perform(_ id: String, success: String? = nil, settle: Bool = false,
                         _ work: @escaping @Sendable () async -> String?) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            let err = await work()
            busy.remove(id)
            if let err { showToast(err, error: true) } else if let success { showToast(success) }
            if settle { try? await Task.sleep(nanoseconds: 500_000_000) }
            refresh()
        }
    }

    // MARK: Tiles

    func toggle(_ tile: MenuBarTile) {
        switch tile {
        case .smoothScroll:
            let s = MouseSettings.shared
            var c = s.config
            if !s.enabled { s.enabled = true; c.smoothEnabled = true } else { c.smoothEnabled.toggle() }
            s.config = c
            smoothScrollOn = s.enabled && c.smoothEnabled
        case .windowSwitcher:
            WindowPreviewSettings.shared.switcherEnabled.toggle()
            windowSwitcherOn = WindowPreviewSettings.shared.switcherEnabled
        case .hideDesktop:
            let target = !snapshot.hideDesktop
            snapshot.hideDesktop = target
            perform("hideDesktop", success: target ? "Desktop icons hidden" : "Desktop icons shown") {
                MenuBarSystem.setDesktopIconsHidden(target)
            }
        case .hiddenFiles:
            guard let a = tools.actions.first(where: { $0.id == "hidden" }) else { return }
            snapshot.hiddenFiles.toggle()
            perform("hiddenFiles") {
                let r = await a.run()
                return r.ok ? nil : r.message
            }
        }
    }

    // MARK: Quick actions

    func run(_ action: MenuBarQuickAction) {
        switch action {
        case .optimize:
            guard let hook = MenuBarHooks.quickOptimize else { return }
            perform("optimize") { [weak self] in
                let msg = await hook()
                await self?.showToast(msg)
                return nil
            }
        case .freeRAM:
            guard let hook = MenuBarHooks.freeMemory else { return }
            perform("freeRAM") { [weak self] in
                let msg = await hook()
                await self?.showToast(msg)
                return nil
            }
        case .flushDNS:
            guard let a = tools.actions.first(where: { $0.id == "flushDNS" }) else { return }
            confirm = MenuBarConfirm(title: "Flush DNS cache?", message: "This needs your administrator password.", button: "Flush") { [weak self] in
                self?.perform("flushDNS") { [weak self] in
                    let r = await a.run()
                    await self?.showToast(r.message, error: !r.ok)
                    return nil
                }
            }
        case .openTrash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
            MainStatusItem.shared.close()
        case .eject:
            guard let a = tools.actions.first(where: { $0.id == "eject" }) else { return }
            confirm = MenuBarConfirm(title: "Eject all external disks?", message: "Save open files first.", button: "Eject") { [weak self] in
                self?.perform("eject") { [weak self] in
                    let r = await a.run()
                    await self?.showToast(r.message, error: !r.ok)
                    return nil
                }
            }
        case .lock:
            MainStatusItem.shared.close()
            perform("lock") { MenuBarSystem.lockScreen() ? nil : "Could not lock the screen" }
        case .sleepDisplays:
            MainStatusItem.shared.close()
            perform("sleepDisplays") { MenuBarSystem.sleepDisplays() ? nil : "Could not sleep displays" }
        case .screenSaver:
            MainStatusItem.shared.close()
            perform("screenSaver") { MenuBarSystem.startScreenSaver() ? nil : "Could not start the screen saver" }
        case .screenshot:
            MainStatusItem.shared.close()
            perform("screenshot") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return MenuBarSystem.openScreenshotTools() ? nil : "Could not open Screenshot"
            }
        }
    }

    // MARK: Processes

    /// Quits a regular user app (graceful terminate).
    func quitApp(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return }
        if app.terminate() { showToast("Asked \(app.localizedName ?? "app") to quit") }
        else { showToast("Could not quit \(app.localizedName ?? "app")", error: true) }
    }

    func canQuit(pid: pid_t) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activationPolicy == .regular
    }
}
