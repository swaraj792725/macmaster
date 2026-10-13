import SwiftUI
import AppKit
import Observation

/// State + actions behind the popover tiles. Refreshed only when the popover opens.
@Observable
@MainActor
final class ControlCenterModel {
    static let shared = ControlCenterModel()

    private(set) var wifi: Bool?
    private(set) var bluetooth: Bool?
    private(set) var bluetoothNeedsPermission = false
    private(set) var darkMode = false
    private(set) var nightShift: Bool?
    private(set) var lowPower = false
    private(set) var brightness: Float?
    private(set) var keyboardBrightness: Float?
    private(set) var message: String?
    private(set) var loaded = false

    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?
    private init() {}

    // MARK: Lifecycle (popover open / close)

    func opened() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        brightness = ControlCenterBrightness.read()
        let settings = ControlCenterSettings.shared
        keyboardBrightness = ControlCenterKeyboardBrightness.read()
        if settings.isVisible(.nowPlaying) { ControlCenterNowPlaying.shared.startListening() }
        if settings.isVisible(.bluetoothDevices) { ControlCenterBluetoothDevices.shared.refresh() }
        bluetoothNeedsPermission = ControlCenterSystem.bluetoothNeedsPermission
        ControlCenterAudio.shared.refresh()
        ControlCenterAudio.shared.startListening()
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        reload()
    }

    func closed() {
        ControlCenterAudio.shared.stopListening()
        ControlCenterNowPlaying.shared.stopListening()
        if let o = powerObserver { NotificationCenter.default.removeObserver(o); powerObserver = nil }
        messageTask?.cancel(); message = nil
    }

    /// Reads Wi-Fi / Bluetooth / dark mode / Night Shift off the main thread.
    func reload() {
        Task.detached(priority: .userInitiated) {
            let s = ControlCenterSystem.queue.sync { ControlCenterSystem.snapshot() }
            await MainActor.run {
                let m = ControlCenterModel.shared
                m.wifi = s.wifi; m.bluetooth = s.bluetooth
                m.darkMode = s.darkMode; m.nightShift = s.nightShift
                m.bluetoothNeedsPermission = ControlCenterSystem.bluetoothNeedsPermission
                m.loaded = true
            }
        }
    }

    // MARK: Helpers

    func say(_ text: String?) {
        messageTask?.cancel()
        message = text
        guard text != nil else { return }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    /// Runs a blocking system call on the serial queue, then hands back an optional error message.
    private func background(_ work: @escaping @Sendable () -> String?, done: @escaping (String?) -> Void = { _ in }) {
        Task.detached(priority: .userInitiated) {
            let err = ControlCenterSystem.queue.sync(execute: work)
            await MainActor.run { done(err) }
        }
    }

    // MARK: Toggles (optimistic, reverted on failure)

    func toggleWifi() {
        guard let cur = wifi else { ControlCenterSystem.openSettings("com.apple.wifi-settings-extension"); return }
        wifi = !cur
        background({ ControlCenterSystem.setWifi(!cur) }) { [self] err in
            if let err { wifi = cur; say(err) }
        }
    }

    func toggleBluetooth() {
        if bluetoothNeedsPermission {
            ControlCenterBluetoothAsker.shared.onAnswer = { [weak self] in self?.reload() }
            ControlCenterBluetoothAsker.shared.request()
            return
        }
        guard let cur = bluetooth else {
            // No access or unavailable: let the user toggle it in System Settings instead.
            ControlCenterSystem.openSettings("com.apple.Bluetooth-Settings.extension")
            return
        }
        bluetooth = !cur
        background({ ControlCenterSystem.setBluetooth(!cur) }) { [self] err in
            if let err {
                bluetooth = cur; say(err)
                ControlCenterSystem.openSettings("com.apple.Bluetooth-Settings.extension")
            }
        }
    }

    func toggleDarkMode() {
        let cur = darkMode
        darkMode = !cur
        background({ ControlCenterSystem.toggleDarkMode() }) { [self] err in
            if let err { darkMode = cur; say(err) }
            else { Task { try? await Task.sleep(for: .milliseconds(700)); reload() } }
        }
    }

    func toggleNightShift() {
        guard let cur = nightShift else { return }
        nightShift = !cur
        background({ ControlCenterSystem.setNightShift(!cur) }) { [self] err in
            if let err { nightShift = cur; say(err) }
        }
    }

    func toggleLowPower() {
        let want = !lowPower
        say("macOS will ask for your password to change Low Power Mode.")
        background({ ControlCenterSystem.setLowPower(want) }) { [self] err in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            say(err)
        }
    }

    // MARK: Actions (close the popover first so it is not in the way)

    func lockScreen() {
        ControlCenterMenuBar.shared.close()
        background({ ControlCenterSystem.lockScreen(); return nil })
    }

    func screenshot() {
        ControlCenterMenuBar.shared.close()
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSWorkspace.shared.open(url) }
    }

    func airDrop() {
        ControlCenterMenuBar.shared.close()
        let path = "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.open(finder)
        }
    }

    func focus() {
        let name = ControlCenterSettings.shared.focusShortcut.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            ControlCenterSystem.openSettings("com.apple.Focus-Settings.extension")
            ControlCenterMenuBar.shared.close()
            return
        }
        background({ ControlCenterSystem.runShortcut(name) }) { [self] err in say(err) }
    }

    func toggleCleaning() {
        let engine = KeyboardEngine.shared
        if engine.cleaningActive { engine.stopCleaning(); return }
        ControlCenterMenuBar.shared.close()
        if !engine.startCleaning(seconds: 0) {
            ControlCenterSystem.openSettings("com.apple.preference.security?Privacy_Accessibility")
        }
    }

    func toggleShelf() {
        ControlCenterMenuBar.shared.close()
        DispatchQueue.main.async { DropShelf.shared.toggle() }
    }

    func setBrightness(_ v: Float) {
        brightness = v
        ControlCenterBrightness.write(v)
    }

    func setKeyboardBrightness(_ v: Float) {
        keyboardBrightness = v
        ControlCenterKeyboardBrightness.write(v)
    }

    /// Whether a tile has something to show on this Mac right now. Unavailable tiles are left out of the grid.
    func isAvailable(_ tile: ControlCenterTile) -> Bool {
        let audio = ControlCenterAudio.shared
        switch tile {
        case .wifi: return !loaded || wifi != nil
        case .bluetooth: return ControlCenterSystem.bluetoothAvailable
        case .nightShift: return !loaded || nightShift != nil
        case .lowPower: return BatteryMonitor.shared.reading.isPresent
        case .brightness: return brightness != nil
        case .keyboardBrightness: return keyboardBrightness != nil
        case .volume: return audio.hasVolume || audio.devices.count > 1
        case .micMute: return audio.hasMic
        case .nowPlaying: return ControlCenterNowPlaying.shared.info != nil
        case .audioDevices: return !audio.devices.isEmpty || !audio.inputs.isEmpty
        case .bluetoothDevices: return !ControlCenterBluetoothDevices.shared.devices.isEmpty
        default: return true
        }
    }

    func openMacMaster() {
        ControlCenterMenuBar.shared.close()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Notification.Name("MacMaster.openSection"), object: "dashboard")
    }

    func openSystemSettings() {
        ControlCenterMenuBar.shared.close()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
