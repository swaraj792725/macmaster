import AppKit
import SwiftUI

/// Facade started by the app: owns the Dock preview and the window switcher, honors their settings
/// and (re)starts them once Accessibility is granted.
@MainActor
final class WindowPreviewController: ObservableObject {
    static let shared = WindowPreviewController()

    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var dockRunning = false
    @Published private(set) var switcherRunning = false

    private let dock = WindowPreviewDockController()
    private let switcher = WindowPreviewSwitcher()
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var lastScreenRecording = false

    private init() {}

    func start() {
        started = true
        WindowPreviewNativeSwitcher.healIfNeeded()   // undo a ⌘Tab suppression left behind by a crash
        reconcile()
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.reconcile()
            }
        }
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        dock.stop()
        switcher.stop()
        dockRunning = false
        switcherRunning = false
        Task { await WindowPreviewThumbnailer.shared.clear() }
    }

    func settingsChanged() {
        guard started else { return }
        reconcile()
    }

    /// Bring running components in line with permissions + settings.
    private func reconcile() {
        let ax = Permissions.isGranted(.accessibility)
        let sr = Permissions.isGranted(.screenRecording)
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if sr != screenRecordingGranted { screenRecordingGranted = sr }
        if sr != lastScreenRecording {
            lastScreenRecording = sr
            Task { await WindowPreviewThumbnailer.shared.clear(disk: true) }
        }
        let s = WindowPreviewSettings.shared

        let wantDock = ax && s.dockPreviews
        if wantDock && !dockRunning { dock.start(); dockRunning = true }
        if !wantDock && dockRunning { dock.stop(); dockRunning = false }

        let wantSwitcher = ax && s.switcherEnabled
        if wantSwitcher && !switcher.isRunning { switcherRunning = switcher.start() }
        if !wantSwitcher && switcher.isRunning { switcher.stop(); switcherRunning = false }
        if wantSwitcher && switcher.isRunning && !switcher.isHealthy {
            // Dead tap with ⌘Tab suppressed would leave no app switcher at all: rebuild it.
            switcher.stop()
            switcherRunning = switcher.start()
        }
        if switcher.isRunning { switcher.syncSettings() }
    }
}
