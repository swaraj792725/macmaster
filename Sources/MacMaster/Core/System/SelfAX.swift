import ApplicationServices
import CoreGraphics
import Foundation

/// Keeps MacMaster's Accessibility clients away from MacMaster itself. An AX request aimed at our own
/// process is answered in-process, on the asking (background) thread, so our AppKit/SwiftUI accessibility
/// code runs off main. AppKit then raises ("NSWindow geometry should only be modified on the main thread"),
/// HIServices swallows the exception, SwiftUI's update lock stays held and the app freezes (or SwiftUI's
/// accessibility tree is read mid-update and the app crashes).
/// Window hit-tests, window queries and the menu bar scanner skip our own process and use AppKit instead.
enum SelfAX {
    static let pid = ProcessInfo.processInfo.processIdentifier

    /// True when the frontmost on-screen window at `p` (global top-left coordinates, as AX uses) is ours.
    /// Thread-safe; costs one window-list snapshot.
    static func ownsWindow(at p: CGPoint) -> Bool {
        windowOwners(at: p).first == pid
    }

    /// The AX element at `p` (global top-left coordinates). Nil over our own windows.
    /// Never hit-tests the system-wide element: that can still land on one of our windows (through another
    /// app's click-through overlay, or a window that moved after a check), which runs our SwiftUI accessibility
    /// off main. Instead it asks only the app that owns the window under `p`, trying the next window down
    /// when an app has nothing there (an overlay). Thread-safe; blocking.
    static func element(at p: CGPoint, timeout: Float) -> AXUIElement? {
        for owner in windowOwners(at: p).prefix(3) {
            if owner == pid { return nil }
            let app = AXUIElementCreateApplication(owner)
            AXUIElementSetMessagingTimeout(app, timeout)
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success, let el { return el }
        }
        return nil
    }

    /// Owners of the visible on-screen windows containing `p`, front to back.
    private static func windowOwners(at p: CGPoint) -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var owners: [pid_t] = []
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(p) else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
            guard let owner = (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) else { continue }
            if owners.last != owner { owners.append(owner) }
        }
        return owners
    }
}
