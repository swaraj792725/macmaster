import SwiftUI
import AppKit

/// Live permission status. Polls only between `start()` and `stop()` (page visible) and only
/// while the app is active; also refreshes when the app becomes active.
@MainActor @Observable
final class PermissionsModel {
    private(set) var status: [Permission: Bool] = [:]
    private(set) var checking = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        for p in Permission.allCases { status[p] = Permissions.isGranted(p) }
    }

    var grantedCount: Int { status.values.filter { $0 }.count }
    var total: Int { Permission.allCases.count }
    func isGranted(_ p: Permission) -> Bool { status[p] ?? false }

    func start() {
        guard poll == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        poll = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                if NSApp.isActive { await self?.refresh() }
            }
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() async {
        await Permissions.refreshNotificationStatus()
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, Permissions.isGranted($0)) })
        }.value
        if result != status { withAnimation(.smooth(duration: 0.25)) { status = result } }
    }

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
        Permissions.request(p)
        // The user answers in a system dialog / System Settings; look again shortly.
        Task {
            for delay in [0.6, 1.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                await refresh()
            }
        }
    }
}
