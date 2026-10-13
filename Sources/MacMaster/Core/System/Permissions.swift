import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import UserNotifications

enum Permission: String, CaseIterable, Identifiable, Hashable, Sendable {
    case accessibility, screenRecording, fullDiskAccess, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .notifications: "Notifications"
        }
    }

    /// Why MacMaster asks for this, in plain language.
    var blurb: String {
        switch self {
        case .accessibility:
            "Lets MacMaster see and move windows, listen for your shortcuts and mouse buttons, and read menu bar items. Without it, most of the enhancement features cannot work."
        case .screenRecording:
            "Lets MacMaster capture window thumbnails and menu bar icon images for previews. Nothing is recorded or saved, and nothing leaves your Mac."
        case .fullDiskAccess:
            "Lets the Cleaner and Uninstaller look inside protected folders such as app containers and system caches, so deep scans find everything."
        case .notifications:
            "Lets MacMaster tell you when a scheduled clean finishes, the battery needs attention, or the Health Monitor spots a problem."
        }
    }

    /// Feature names that need this permission.
    var features: [String] {
        switch self {
        case .accessibility:
            ["Window Switcher", "Window Tiling", "Mouse buttons", "Keyboard remaps", "Menu Bar Icons", "Clipboard paste"]
        case .screenRecording:
            ["Window previews", "Window thumbnails", "Menu bar icon images"]
        case .fullDiskAccess:
            ["Cleaner deep scans", "Uninstaller deep scans", "Leftover Hunter"]
        case .notifications:
            ["Scheduled clean alerts", "Battery alerts", "Health Monitor alerts"]
        }
    }

    /// SF Symbol for the permission.
    var symbol: String {
        switch self {
        case .accessibility: SymbolKit.firstAvailable(["accessibility", "figure.stand"])
        case .screenRecording: SymbolKit.firstAvailable(["rectangle.inset.filled.and.person.filled", "record.circle", "rectangle.dashed"])
        case .fullDiskAccess: SymbolKit.firstAvailable(["internaldrive.fill", "externaldrive.fill"])
        case .notifications: SymbolKit.firstAvailable(["bell.badge.fill", "bell.fill"])
        }
    }

    /// Hue gradient used for the permission's icon tile.
    var colors: [Color] {
        switch self {
        case .accessibility: Theme.Palette.blue
        case .screenRecording: Theme.Palette.purple
        case .fullDiskAccess: Theme.Palette.orange
        case .notifications: Theme.Palette.red
        }
    }

    /// Most of the app depends on this one. Others only unlock specific features.
    var isRequired: Bool { self == .accessibility }

    /// Label for the primary action button when the permission is missing.
    var actionTitle: String {
        switch self {
        case .accessibility, .screenRecording: "Grant"
        case .fullDiskAccess: "Open Settings"
        case .notifications: Permissions.notificationsCanPrompt ? "Grant" : "Open Settings"
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return URL(string: base + "Privacy_Accessibility")!
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")!
        case .fullDiskAccess: return URL(string: base + "Privacy_AllFiles")!
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
    }
}

enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .fullDiskAccess: return hasFullDiskAccess
        case .notifications: return notificationState.granted
        }
    }

    /// Number of permissions currently granted.
    static var grantedCount: Int { Permission.allCases.filter(isGranted).count }

    static func request(_ p: Permission) {
        if p == .notifications { requestNotifications(); return }
        if !isGranted(p) { resetStaleEntry(p) }
        switch p {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(p.settingsURL) }
        case .fullDiskAccess:
            NSWorkspace.shared.open(p.settingsURL)
        case .notifications:
            break
        }
    }

    /// A grant made for an older build (different signature) still shows "on" in System Settings
    /// but never matches this binary. Clearing our own entry lets macOS add a fresh one.
    private static func resetStaleEntry(_ p: Permission) {
        let service: String
        switch p {
        case .accessibility: service = "Accessibility"
        case .screenRecording: service = "ScreenCapture"
        case .fullDiskAccess, .notifications: return   // can't be reset without admin rights / not TCC
        }
        guard let id = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// FDA has no API; probe a TCC-protected location.
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
        for url in probes where FileManager.default.fileExists(atPath: url.path) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return false }
            try? h.close()
            return true
        }
        // No probe exists — check Containers listing as a weaker signal.
        return (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Containers/com.apple.Safari").path)) != nil
    }

    // MARK: Notifications

    /// UNUserNotificationCenter only answers asynchronously, so the status is cached and
    /// `isGranted(.notifications)` stays cheap. Call `refreshNotificationStatus()` to update it.
    private struct NotificationState { var granted = false; var canPrompt = false; var loaded = false }
    private static let notificationLock = NSLock()
    nonisolated(unsafe) private static var _notificationState = NotificationState()

    private static var notificationState: NotificationState {
        let (s, needsLoad): (NotificationState, Bool) = notificationLock.withLock {
            let s = _notificationState
            if !s.loaded { _notificationState.loaded = true }   // kick off exactly one lazy load
            return (s, !s.loaded)
        }
        if needsLoad { Task.detached { await refreshNotificationStatus() } }
        return s
    }

    /// True while macOS has not yet asked the user (so a request shows the system prompt).
    static var notificationsCanPrompt: Bool { notificationState.canPrompt }

    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Re-reads the notification authorization status into the cache.
    static func refreshNotificationStatus() async {
        guard canUseNotificationCenter else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationLock.withLock {
            _notificationState.granted = status == .authorized || status == .provisional
            _notificationState.canPrompt = status == .notDetermined
            _notificationState.loaded = true
        }
    }

    private static func requestNotifications() {
        guard canUseNotificationCenter else { NSWorkspace.shared.open(Permission.notifications.settingsURL); return }
        if notificationState.canPrompt {
            Task.detached {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refreshNotificationStatus()
            }
        } else {
            NSWorkspace.shared.open(Permission.notifications.settingsURL)
        }
    }

    /// Re-reads every permission that needs an async check. Cheap AX/ScreenCapture/FDA checks are read live.
    static func refresh() async { await refreshNotificationStatus() }
}
