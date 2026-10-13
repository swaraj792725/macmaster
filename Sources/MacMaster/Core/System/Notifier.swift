import Foundation
import UserNotifications

/// User notifications. Falls back to an AppleScript notification when the
/// UserNotifications center is unavailable (e.g. running unbundled via `swift run`).
enum Notifier {
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// - Parameter id: stable identifier so repeated alerts replace each other.
    static func post(title: String, body: String, id: String = UUID().uuidString, sound: Bool = true) {
        guard isBundled else {
            let t = title.replacingOccurrences(of: "\"", with: "'")
            let b = body.replacingOccurrences(of: "\"", with: "'")
            NSAppleScript(source: "display notification \"\(b)\" with title \"\(t)\"")?.executeAndReturnError(nil)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
