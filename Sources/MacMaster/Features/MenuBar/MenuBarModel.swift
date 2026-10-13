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

    /// Slider-bound values (0...1). Not overwritten by refreshes while the user is adjusting.
    var brightness: Double = 0.5
    var volume: Double = 0.5
    private var lastSliderEdit = Date.distantPast

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var prefsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPrefsSignature = MenuBarPrefs.signature()
    @ObservationIgnored private var holdingProcesses = false
    @ObservationIgnored private let tools = ToolsQuickActionsModel()
    @ObservationIgnored private let sliderQueue = DispatchQueue(label: "macmaster.menubar.sliders", qos: .userInitiated)

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

    var hasWifi: Bool { snapshot.wifi != nil }
    var hasBluetooth: Bool { snapshot.bluetooth != nil || MenuBarSystem.bluetoothNeedsPermission }
    var hasMute: Bool { snapshot.muted != nil }
    var hasBrightness: Bool { snapshot.brightness != nil }
    var hasVolume: Bool { snapshot.volume != nil }

    func isTileVisible(_ t: MenuBarTile) -> Bool {
        _ = prefsRevision
        guard MenuBarPrefs.isOn(t.key) else { return false }
        switch t {
        case .wifi: return hasWifi
        case .bluetooth: return hasBluetooth
        case .mute: return hasMute
        default: return true
        }
    }

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

    var tileColumns: Int { _ = prefsRevision; return MenuBarPrefs.tileColumns }

    func isOn(_ t: MenuBarTile) -> Bool {
        switch t {
        case .keepAwake: ToolsKeepAwake.shared.isActive || ToolsKeepAwake.shared.isArmed
        case .darkMode: snapshot.darkMode
        case .wifi: snapshot.wifi ?? false
        case .bluetooth: snapshot.bluetooth ?? false
        case .hideDesktop: snapshot.hideDesktop
        case .hiddenFiles: snapshot.hiddenFiles
        case .lowPower: snapshot.lowPower
        case .mute: snapshot.muted ?? false
        case .smoothScroll: smoothScrollOn
        case .windowSwitcher: windowSwitcherOn
        }
    }

    func subtitle(_ t: MenuBarTile) -> String {
        switch t {
        case .keepAwake:
            let k = ToolsKeepAwake.shared
            if k.isActive, let r = k.remaining { return ToolsKeepAwake.countdown(r) }
            return k.isActive ? "On" : (k.isArmed ? "Armed" : "Off")
        case .darkMode: return snapshot.darkMode ? "Dark" : "Light"
        case .wifi: return snapshot.wifi == true ? "On" : "Off"
        case .bluetooth: return snapshot.bluetooth == nil ? "Allow access" : snapshot.bluetooth == true ? "On" : "Off"
        case .mute: return snapshot.muted == true ? "Muted" : "Sound on"
        default: return isOn(t) ? "On" : "Off"
        }
    }

    // MARK: Lifecycle

    func appeared() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    func disappeared() {
        pollTask?.cancel(); pollTask = nil
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
        if Date().timeIntervalSince(lastSliderEdit) > 1.2 {
            if let b = s.brightness { brightness = Double(b) }
            if let v = s.volume { volume = Double(v) }
        }
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
        case .keepAwake:
            ToolsKeepAwake.shared.toggle()
        case .smoothScroll:
            let s = MouseSettings.shared
            var c = s.config
            if !s.enabled { s.enabled = true; c.smoothEnabled = true } else { c.smoothEnabled.toggle() }
            s.config = c
            smoothScrollOn = s.enabled && c.smoothEnabled
        case .windowSwitcher:
            WindowPreviewSettings.shared.switcherEnabled.toggle()
            windowSwitcherOn = WindowPreviewSettings.shared.switcherEnabled
        case .darkMode:
            snapshot.darkMode.toggle()
            perform("darkMode", settle: true) { MenuBarSystem.toggleDarkMode() }
        case .wifi:
            let target = !(snapshot.wifi ?? false)
            snapshot.wifi = target
            perform("wifi", settle: true) { MenuBarSystem.setWifi(target) }
        case .bluetooth:
            if snapshot.bluetooth == nil {
                MenuBarSystem.requestBluetoothPermission()
                return
            }
            let target = !(snapshot.bluetooth ?? false)
            snapshot.bluetooth = target
            perform("bluetooth", settle: true) { MenuBarSystem.setBluetooth(target) }
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
        case .lowPower:
            let target = !snapshot.lowPower
            confirm = MenuBarConfirm(
                title: target ? "Turn on Low Power Mode?" : "Turn off Low Power Mode?",
                message: "This needs your administrator password.",
                button: target ? "Turn On" : "Turn Off") { [weak self] in
                    self?.snapshot.lowPower = target
                    self?.perform("lowPower", success: target ? "Low Power Mode on" : "Low Power Mode off", settle: true) {
                        let r = await ToolsAdmin.run("/usr/bin/pmset", ["-a", "lowpowermode", target ? "1" : "0"],
                                                     prompt: "MacMaster needs administrator access to change Low Power Mode.")
                        if r.status == 0 { return nil }
                        return ToolsAdmin.isCancelled(r) ? "Cancelled" : "Could not change Low Power Mode"
                    }
                }
        case .mute:
            let target = !(snapshot.muted ?? false)
            snapshot.muted = target
            perform("mute") { MenuBarSystem.setMuted(target); return nil }
        }
    }

    // MARK: Sliders

    func setBrightness(_ v: Double) {
        brightness = v
        lastSliderEdit = Date()
        let f = Float(v)
        sliderQueue.async { MenuBarSystem.setBrightness(f) }
    }

    func setVolume(_ v: Double) {
        volume = v
        lastSliderEdit = Date()
        if v > 0, snapshot.muted == true { snapshot.muted = false }
        let f = Float(v)
        sliderQueue.async { MenuBarSystem.setVolume(f) }
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
