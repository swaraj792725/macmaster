import CoreGraphics
import Foundation

/// Keeps MacMaster's Accessibility clients away from MacMaster itself. An AX request aimed at our own
/// windows is answered by our own main thread inside SwiftUI's accessibility code; if that throws,
/// HIServices swallows the exception and SwiftUI's update lock can stay held, freezing the app at the
/// next UI event. Window hit-tests and window queries skip our own process instead.
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
