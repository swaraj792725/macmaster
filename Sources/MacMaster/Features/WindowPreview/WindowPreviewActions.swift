import AppKit
import ApplicationServices

/// Window operations through the Accessibility API.
@MainActor
enum WindowPreviewActions {
    /// Find a live AX element for a window (the stored one may be stale).
    private static func resolve(_ w: WindowPreviewWindow) -> AXUIElement? {
        guard w.pid != SelfAX.pid else { return nil }
        if let ax = w.ax, WindowPreviewAX.string(ax, kAXRoleAttribute) != nil { return ax }
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let all = WindowPreviewAX.elements(app, kAXWindowsAttribute)
        if let m = all.first(where: { WindowPreviewAX.windowID($0) == w.id }) { return m }
        if let m = all.first(where: { WindowPreviewAX.string($0, kAXTitleAttribute) == w.title }) { return m }
        return nil
    }

    static func focus(_ w: WindowPreviewWindow) {
        if w.pid == SelfAX.pid {
            if let win = NSApp.window(withWindowNumber: Int(w.id)) {
                if win.isMiniaturized { win.deminiaturize(nil) }
                win.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            return
        }
        let axApp = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        let running = NSRunningApplication(processIdentifier: w.pid)
        if running?.isHidden == true { running?.unhide() }
        if let ax = resolve(w) {
            if w.isMinimized || WindowPreviewAX.bool(ax, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, ax)
        } else {
            // Window on another Space or not reachable: activating the app switches to its Space.
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        running?.activate()
    }

    static func close(_ w: WindowPreviewWindow) {
        if w.pid == SelfAX.pid { NSApp.window(withWindowNumber: Int(w.id))?.performClose(nil); return }
        guard let ax = resolve(w),
              let btn = WindowPreviewAX.attr(ax, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }

    /// Returns the new minimized state.
    @discardableResult
    static func toggleMinimize(_ w: WindowPreviewWindow) -> Bool {
        if w.pid == SelfAX.pid, let win = NSApp.window(withWindowNumber: Int(w.id)) {
            if win.isMiniaturized { win.deminiaturize(nil) } else { win.miniaturize(nil) }
            return win.isMiniaturized
        }
        guard let ax = resolve(w) else { return w.isMinimized }
        let now = WindowPreviewAX.bool(ax, kAXMinimizedAttribute) ?? w.isMinimized
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, (!now) as CFBoolean)
        return !now
    }

    static func quitApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    static func hideApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    /// Toggles native full screen for the window (AXFullScreen). Returns false when unsupported.
    @discardableResult
    static func toggleFullscreen(_ w: WindowPreviewWindow) -> Bool {
        if w.pid == SelfAX.pid, let win = NSApp.window(withWindowNumber: Int(w.id)) {
            win.toggleFullScreen(nil)
            return true
        }
        guard let ax = resolve(w) else { return false }
        let now = WindowPreviewAX.bool(ax, "AXFullScreen") ?? false
        return AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, (!now) as CFBoolean) == .success
    }
}
