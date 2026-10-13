import CoreGraphics
import Foundation

/// Keeps MacMaster's Accessibility clients away from MacMaster itself. An AX request aimed at our own
/// process is answered in-process, on the asking (background) thread, so our AppKit/SwiftUI accessibility
/// code runs off main. AppKit then raises ("NSWindow geometry should only be modified on the main thread"),
/// HIServices swallows the exception, SwiftUI's update lock stays held and the app freezes.
/// Window hit-tests, window queries and the menu bar scanner skip our own process and use AppKit instead.
enum SelfAX {
    static let pid = ProcessInfo.processInfo.processIdentifier

    /// True when the frontmost on-screen window at `p` (global top-left coordinates, as AX uses) is ours.
    /// Thread-safe; costs one window-list snapshot.
    static func ownsWindow(at p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(p) else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
            return (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) == pid } ?? false
        }
        return false
    }
}
