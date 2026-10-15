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
        let hits = windowHits(at: p)
        var tried = 0
        var fallback: (pid: pid_t, bounds: CGRect)?
        for h in hits {
            if h.owner == pid { return nil }
            // Overlays (Dock's full-screen layer, Stage Manager, menu bar) have no AX window under the point
            // and must not use up the budget meant for real windows.
            guard h.layer == 0 else { continue }
            if fallback == nil { fallback = (h.owner, h.bounds) }
            guard tried < 4 else { break }
            tried += 1
            let app = AXUIElementCreateApplication(h.owner)
            AXUIElementSetMessagingTimeout(app, timeout)
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success, let el { return el }
        }
        // Hit-test found nothing (some apps answer nil over custom-drawn chrome): fall back to the owner of
        // the topmost normal window and pick its AXWindow whose frame matches that window's bounds.
        guard let fb = fallback else { return nil }
        let app = AXUIElementCreateApplication(fb.pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGFloat)?
        for w in wins {
            guard let f = axFrame(w), f.insetBy(dx: -2, dy: -2).contains(p) else { continue }
            let d = abs(f.minX - fb.bounds.minX) + abs(f.minY - fb.bounds.minY)
                + abs(f.width - fb.bounds.width) + abs(f.height - fb.bounds.height)
            if best == nil || d < best!.1 { best = (w, d) }
        }
        return best.map { $0.0 }
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sv) == .success,
              let pv, let sv,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// Owners of the visible on-screen windows containing `p`, front to back.
    private static func windowOwners(at p: CGPoint) -> [pid_t] {
        windowHits(at: p).map(\.owner)
    }

    /// Visible on-screen windows containing `p`, front to back, adjacent windows of one owner and layer merged.
    private static func windowHits(at p: CGPoint) -> [(owner: pid_t, layer: Int, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var hits: [(owner: pid_t, layer: Int, bounds: CGRect)] = []
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(p) else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
            guard let owner = (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            if let l = hits.last, l.owner == owner, l.layer == layer { continue }
            hits.append((owner, layer, r))
        }
        return hits
    }
}
