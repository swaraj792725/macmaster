import AppKit
import ApplicationServices
import CoreGraphics

/// Synthetic input: pressing menu bar items and ⌘-dragging them between sections.
enum MenuBarManagerAutomation {
    // MARK: Press

    /// Press a status item through Accessibility (AXExtrasMenuBar children, matched by frame).
    nonisolated static func pressViaAccessibility(pid: pid_t, frame: CGRect) async -> Bool {
        guard pid != SelfAX.pid else { return false } // our own items get a synthetic click instead
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return false }
        let bar = unsafeBitCast(barRef, to: AXUIElement.self)
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement], !kids.isEmpty else { return false }

        var best: (AXUIElement, CGFloat)?
        for kid in kids {
            guard let r = axFrame(kid) else { continue }
            let d = abs(r.midX - frame.midX) + abs(r.midY - frame.midY)
            if best == nil || d < best!.1 { best = (kid, d) }
        }
        // A single child is unambiguous; otherwise require the match to be close.
        guard let (el, dist) = best, dist < 14 || kids.count == 1 else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// How the user clicked an item in the dropdown.
    enum PressKind: Sendable {
        case primary
        /// Right-click: items usually show an alternate menu.
        case secondary
        /// Option-click: forwarded as a real click with ⌥ held when the item is on screen.
        case option
    }

    /// Presses a menu bar item by identity (not by position), so it works for items macOS moved or hid.
    /// Finds the app's AXMenuBarItem with the same stable key, then falls back to the closest frame.
    /// Blocking: call off the main thread.
    nonisolated static func press(app: MenuBarManagerAppRef, key: String, frame: CGRect,
                                  kind: PressKind = .primary) -> Bool {
        let leaves = MenuBarManagerScanner.axLeaves(of: app, timeout: 0.8)
        guard !leaves.isEmpty else { return false }
        var target = leaves.first { $0.raw.stableKey == key }
        if target == nil {
            // Identity changed (title edits...). Take the closest frame, or the only item.
            if leaves.count == 1 { target = leaves[0] }
            else if let c = leaves.min(by: { dist($0.raw.frame, frame) < dist($1.raw.frame, frame) }),
                    dist(c.raw.frame, frame) < 14 { target = c }
        }
        guard let el = target?.element else { return false }
        let action = kind == .secondary ? "AXShowMenu" : kAXPressAction
        let r = AXUIElementPerformAction(el, action as CFString)
        // A timeout means the app is busy opening its menu; clicking again would close it.
        if r == .success || r == .cannotComplete { return true }
        // Some items only implement AXPress.
        return kind == .secondary && AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    private nonisolated static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    /// Synthetic click with optional modifiers / right button, used when AXPress fails and the item is on screen.
    nonisolated static func click(at p: CGPoint, right: Bool = false, flags: CGEventFlags = []) async {
        let src = CGEventSource(stateID: .hidSystemState)
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for (t, wait) in [(CGEventType.mouseMoved, UInt64(40_000_000)), (down, 45_000_000), (up, 0)] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: button) else { continue }
            e.flags = flags
            if t != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
            e.post(tap: .cghidEventTap)
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
        }
    }

    private nonisolated static func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: ⌘-drag

    /// ⌘-drag from one point to another with eased intermediate steps. Restores the cursor afterwards.
    nonisolated static func commandDrag(from a: CGPoint, to b: CGPoint) async {
        let src = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location ?? a
        post(.mouseMoved, at: a, src: src, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseDown, at: a, src: src, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 90_000_000)
        let steps = 16
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t * t * (3 - 2 * t) // smoothstep
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            post(.leftMouseDragged, at: p, src: src, flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        post(.leftMouseUp, at: b, src: src, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 120_000_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private nonisolated static func post(_ type: CGEventType, at p: CGPoint, src: CGEventSource?,
                                         flags: CGEventFlags = []) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.flags = flags
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        e.post(tap: .cghidEventTap)
    }
}
