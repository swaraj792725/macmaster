import SwiftUI
import AppKit

/// Live permission status for the Permissions page and onboarding, read from `PermissionWatcher`.
/// Between `start()` and `stop()` (page visible) the watcher checks every few seconds, also while
/// MacMaster is in the background and the user is in System Settings.
@MainActor @Observable
final class PermissionsModel {
    private(set) var checking = false
    @ObservationIgnored private var started = false
    private var watcher: PermissionWatcher { .shared }

    var status: [Permission: Bool] { watcher.status }
    /// Counts cover the core permissions; the on-demand ones (microphone, camera, speech) don't count as missing.
    var grantedCount: Int { Permission.core.filter(isGranted).count }
    var total: Int { Permission.core.count }
    func isGranted(_ p: Permission) -> Bool { watcher.isGranted(p) }
    var menuBarAllowed: Bool? { watcher.menuBarAllowed }

    /// Extra line under a permission when something is off beyond granted / missing.
    func note(for p: Permission) -> String? {
        switch p {
        case .accessibility where watcher.accessibilityBroken:
            "Switched on in System Settings, but macOS still blocks MacMaster (usually left over from an older version). Press Fix, then switch MacMaster on again in the list."
        case .screenRecording where watcher.screenRecordingNeedsRelaunch:
            "Granted. Quit MacMaster completely (⌥⌘Q) and open it again so every preview can use it."
        default: nil
        }
    }

    func start() {
        guard !started else { return }
        started = true
        watcher.beginFastPolling()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.endFastPolling()
    }

    func refresh() async { await watcher.refresh() }

    /// User-pressed Re-check: shows a brief spinner.
    func recheck() {
        checking = true
        Task {
            await refresh()
            try? await Task.sleep(for: .milliseconds(350))
            checking = false
        }
    }

    func request(_ p: Permission) {
        if p == .accessibility, watcher.accessibilityBroken { Permissions.repairAccessibility() }
        else { Permissions.request(p) }
        // The user answers in a system dialog / System Settings; look again shortly.
        Task {
            for delay in [0.6, 1.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                await refresh()
            }
        }
    }

    func openMenuBarSettings() { watcher.openMenuBarSettings() }
}
