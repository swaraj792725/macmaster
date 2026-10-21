import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import UserNotifications
import CoreLocation
import EventKit
import AVFoundation
import Speech

enum Permission: String, CaseIterable, Identifiable, Hashable, Sendable {
    case accessibility, screenRecording, fullDiskAccess, notifications, location, calendars
    case microphone, camera, speechRecognition
    var id: String { rawValue }

    /// Shown in onboarding. The rest are asked for only when the user turns on a feature that needs them.
    static let core: [Permission] = [.accessibility, .screenRecording, .fullDiskAccess, .notifications, .location, .calendars]
    static let onDemand: [Permission] = [.microphone, .camera, .speechRecognition]

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .notifications: "Notifications"
        case .location: "Location"
        case .calendars: "Calendars"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .speechRecognition: "Speech Recognition"
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
        case .location:
            "macOS hides your Wi-Fi network name from apps unless Location is allowed. MacMaster only uses it to show the network name; your location is never read or stored."
        case .calendars:
            "Lets the Clock popover show your upcoming events, join links and a \"next event\" line. Events are read on demand from the calendars you already have in Calendar; nothing is changed, stored or sent anywhere."
        case .microphone:
            "Lets Dictation hear you and lets the Teleprompter scroll while you speak. Audio is processed on your Mac and never saved."
        case .camera:
            "Lets Privacy Guard notice when you look away or someone looks over your shoulder. Frames are checked in memory and never saved or sent."
        case .speechRecognition:
            "Lets Dictation turn your speech into text. MacMaster asks macOS to recognize speech on your Mac where your language supports it."
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
        case .location:
            ["Wi-Fi network name", "Nearby networks list"]
        case .calendars:
            ["Clock popover events", "Next event in the menu bar"]
        case .microphone:
            ["Dictation", "Teleprompter voice scrolling"]
        case .camera:
            ["Privacy Guard"]
        case .speechRecognition:
            ["Dictation"]
        }
    }

    /// SF Symbol for the permission.
    var symbol: String {
        switch self {
        case .accessibility: SymbolKit.firstAvailable(["accessibility", "figure.stand"])
        case .screenRecording: SymbolKit.firstAvailable(["rectangle.inset.filled.and.person.filled", "record.circle", "rectangle.dashed"])
        case .fullDiskAccess: SymbolKit.firstAvailable(["internaldrive.fill", "externaldrive.fill"])
        case .notifications: SymbolKit.firstAvailable(["bell.badge.fill", "bell.fill"])
        case .location: SymbolKit.firstAvailable(["location.fill", "location"])
        case .calendars: SymbolKit.firstAvailable(["calendar", "calendar.badge.clock"])
        case .microphone: SymbolKit.firstAvailable(["mic.fill", "mic"])
        case .camera: SymbolKit.firstAvailable(["camera.fill", "video.fill"])
        case .speechRecognition: SymbolKit.firstAvailable(["waveform.badge.mic", "waveform"])
        }
    }

    /// Hue gradient used for the permission's icon tile.
    var colors: [Color] {
        switch self {
        case .accessibility: Theme.Palette.blue
        case .screenRecording: Theme.Palette.purple
        case .fullDiskAccess: Theme.Palette.orange
        case .notifications: Theme.Palette.red
        case .location: Theme.Palette.teal
        case .calendars: Theme.Palette.pink
        case .microphone: Theme.Palette.orange
        case .camera: Theme.Palette.green
        case .speechRecognition: Theme.Palette.indigo
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
        case .location: Permissions.locationCanPrompt ? "Grant" : "Open Settings"
        case .calendars: Permissions.calendarsCanPrompt ? "Grant" : "Open Settings"
        case .microphone, .camera, .speechRecognition: Permissions.mediaCanPrompt(self) ? "Grant" : "Open Settings"
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return URL(string: base + "Privacy_Accessibility")!
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")!
        case .fullDiskAccess: return URL(string: base + "Privacy_AllFiles")!
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        case .location: return URL(string: base + "Privacy_LocationServices")!
        case .calendars: return URL(string: base + "Privacy_Calendars")!
        case .microphone: return URL(string: base + "Privacy_Microphone")!
        case .camera: return URL(string: base + "Privacy_Camera")!
        case .speechRecognition: return URL(string: base + "Privacy_SpeechRecognition")!
        }
    }
}

enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess() || screenRecordingLive
        case .fullDiskAccess: return hasFullDiskAccess
        case .notifications: return notificationState.granted
        case .location: return locationGranted
        case .calendars: return calendarsGranted
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// True while macOS has not asked yet, so a request shows the system prompt instead of needing Settings.
    static func mediaCanPrompt(_ p: Permission) -> Bool {
        switch p {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .speechRecognition: SFSpeechRecognizer.authorizationStatus() == .notDetermined
        default: false
        }
    }

    /// Asks for microphone, camera or speech access. Calls back on the main queue with the result.
    static func requestMedia(_ p: Permission, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        func done(_ ok: Bool) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PermissionWatcher.shared.refreshSoon()
                    completion?(ok)
                }
            }
        }
        guard mediaCanPrompt(p) else {
            if !isGranted(p) { NSWorkspace.shared.open(p.settingsURL) }
            done(isGranted(p))
            return
        }
        switch p {
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { done($0) }
        case .camera: AVCaptureDevice.requestAccess(for: .video) { done($0) }
        case .speechRecognition: SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) }
        default: done(isGranted(p))
        }
    }

    /// Number of permissions currently granted.
    static var grantedCount: Int { Permission.core.filter(isGranted).count }

    static func request(_ p: Permission) {
        if p == .notifications { requestNotifications(); return }
        if p == .location { requestLocation(); return }
        if p == .calendars { requestCalendars(); return }
        if Permission.onDemand.contains(p) { requestMedia(p); return }
        if !isGranted(p) { resetStaleEntry(p) }
        switch p {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(p.settingsURL) }
        case .fullDiskAccess:
            NSWorkspace.shared.open(p.settingsURL)
        case .notifications, .location, .calendars, .microphone, .camera, .speechRecognition:
            break
        }
    }

    /// Accessibility is on in System Settings but doesn't work for this build: drop the stale entry and ask again.
    static func repairAccessibility() {
        resetStaleEntry(.accessibility)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(Permission.accessibility.settingsURL)
    }

    /// A grant made for an older build (different signature) still shows "on" in System Settings
    /// but never matches this binary. Clearing our own entry lets macOS add a fresh one.
    private static func resetStaleEntry(_ p: Permission) {
        let service: String
        switch p {
        case .accessibility: service = "Accessibility"
        case .screenRecording: service = "ScreenCapture"
        case .fullDiskAccess, .notifications, .location, .calendars, .microphone, .camera, .speechRecognition: return   // can't be reset without admin rights / not TCC
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

    // MARK: Live checks

    /// AXIsProcessTrusted only reads MacMaster's own entry. This asks the Dock for its role, which fails with
    /// `.apiDisabled` when Accessibility doesn't really work for this build (a stale entry from an older one).
    /// Nil when it can't tell. Never asks MacMaster itself (see `SelfAX`). Blocking, at most 0.5s.
    static func accessibilityWorks() -> Bool? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var v: CFTypeRef?
        switch AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) {
        case .success: return true
        case .apiDisabled: return false
        default: return nil
        }
    }

    /// CGPreflightScreenCaptureAccess keeps its first answer for the life of the process, so a grant made while
    /// MacMaster runs would only show after a relaunch. Other apps' window titles are readable only with Screen
    /// Recording, and that is checked live. False when no other app has a titled window on screen.
    /// Cached for 3s: callers ask on hot paths.
    static var screenRecordingLive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = screenLiveLock.withLock({ _screenLive }), now - c.at < 3 { return c.value }
        let value = otherAppWindowTitlesVisible()
        screenLiveLock.withLock { _screenLive = (value, now) }
        return value
    }

    /// Granted for this run only after a relaunch: titles are readable, but the cached system answer is still no.
    static var screenRecordingNeedsRelaunch: Bool { !CGPreflightScreenCaptureAccess() && screenRecordingLive }

    private static let screenLiveLock = NSLock()
    nonisolated(unsafe) private static var _screenLive: (value: Bool, at: TimeInterval)?

    private static func otherAppWindowTitlesVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = SelfAX.pid
        let system: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "MenuBarAgent"]
        return list.contains { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  !system.contains(w[kCGWindowOwnerName as String] as? String ?? "") else { return false }
            return !(w[kCGWindowName as String] as? String ?? "").isEmpty
        }
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

    // MARK: Location

    /// Raw CoreLocation status (cheap, class-level; safe from any thread).
    private static var locationStatus: CLAuthorizationStatus { CLLocationManager.authorizationStatus() }

    static var locationGranted: Bool {
        let s = locationStatus
        return s == .authorizedAlways   // macOS reports "when in use" grants as authorizedAlways
    }

    /// True while macOS has not yet asked the user (so a request shows the system prompt).
    static var locationCanPrompt: Bool { locationStatus == .notDetermined }

    private static func requestLocation() {
        if locationCanPrompt {
            Task { @MainActor in LocationAuthorizer.shared.requestWhenInUse() }
        } else {
            NSWorkspace.shared.open(Permission.location.settingsURL)
        }
    }

    // MARK: Calendars

    /// Full access to events is needed to read them (write-only does not allow reads).
    static var calendarsGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// True while macOS has not yet asked the user (so a request shows the system prompt).
    static var calendarsCanPrompt: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    private static func requestCalendars() {
        guard calendarsCanPrompt else { NSWorkspace.shared.open(Permission.calendars.settingsURL); return }
        Task { @MainActor in
            _ = await CalendarEvents.shared.requestAccess()
            NotificationCenter.default.post(name: .calendarAuthorizationChanged, object: nil)
        }
    }

    /// Re-reads every permission that needs an async check. Cheap AX/ScreenCapture/FDA checks are read live.
    static func refresh() async { await refreshNotificationStatus() }
}

extension Notification.Name {
    /// Posted on the main queue when the Location authorization status changes.
    static let locationAuthorizationChanged = Notification.Name("MacMaster.locationAuthorizationChanged")
    /// Posted on the main queue after the Calendars permission prompt is answered.
    static let calendarAuthorizationChanged = Notification.Name("MacMaster.calendarAuthorizationChanged")
}

/// Keeps a CLLocationManager alive so the system prompt can complete, and announces status changes.
/// Only authorization is used (so CoreWLAN may reveal SSIDs); no location updates are ever started.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorizer()
    private var manager: CLLocationManager?

    func requestWhenInUse() {
        let m = manager ?? CLLocationManager()
        m.delegate = self
        manager = m
        m.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .locationAuthorizationChanged, object: nil) }
    }
}
