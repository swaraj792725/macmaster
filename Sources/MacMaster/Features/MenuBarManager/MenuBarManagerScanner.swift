import AppKit
import CoreGraphics
import ApplicationServices

/// Screen geometry helpers (CG coordinates: origin top-left of the primary display, y down).
enum MenuBarManagerGeometry {
    /// Primary display height, used for AppKit <-> CG flips.
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    @MainActor static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @MainActor static func cgFrame(of screen: NSScreen) -> CGRect { cgRect(fromAppKit: screen.frame) }

    /// Height of the menu bar strip at the top of a screen.
    @MainActor static func stripHeight(of screen: NSScreen) -> CGFloat {
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        return max(24, NSStatusBar.system.thickness, screen.safeAreaInsets.top, inset)
    }

    /// Menu bar strip in CG coordinates.
    @MainActor static func stripRect(of screen: NSScreen) -> CGRect {
        let f = cgFrame(of: screen)
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: stripHeight(of: screen))
    }

    /// The notch (camera housing) in CG coordinates, if the screen has one.
    @MainActor static func notchRect(of screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        // Documented as screen coordinates; tolerate screen-local values on non-origin displays.
        let local = screen.frame.minX != 0 && left.minX < screen.frame.minX - 0.5
        let dx = local ? screen.frame.minX : 0
        let cg = cgFrame(of: screen)
        let minX = left.maxX + dx, maxX = right.minX + dx
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: cg.minY, width: maxX - minX, height: stripHeight(of: screen))
    }

    /// Screen (menu bar) containing a CG-space point, else the primary one.
    @MainActor static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgFrame(of: $0).contains(p) } ?? NSScreen.screens.first
    }
}

/// Reads menu bar windows from the window server. All functions are thread-safe.
enum MenuBarManagerScanner {
    nonisolated static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    nonisolated static let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Every status-level window (layer 25) with a short bar-like height, anywhere in the window list.
    nonisolated static func statusWindows() -> [MenuBarManagerRawWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [MenuBarManagerRawWindow] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == statusLevel,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            guard rect.height > 0, rect.height <= 60, rect.width > 0 else { continue }
            out.append(MenuBarManagerRawWindow(
                id: num, pid: pid_t(pid),
                ownerName: w[kCGWindowOwnerName as String] as? String ?? "",
                title: w[kCGWindowName as String] as? String ?? "",
                frame: rect, layer: statusLevel,
                isOnScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                key: "w\(num)"))
        }
        return out
    }

    // MARK: Accessibility scan (macOS 26+: status items are no longer per-item windows)

    nonisolated static func fnv(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h & 0x3FFF_FFFF_FFFF_FFFF)
    }

    /// Owners of system menu bar items (not apps the user installed).
    nonisolated static let systemOwners: Set<String> = ["Control Center", "SystemUIServer", "MenuBarAgent", "Window Server"]

    /// Pids whose windows live at the menu bar level but which may not be listed as apps (MenuBarAgent...).
    nonisolated static func extraAgentPids() -> [MenuBarManagerAppRef] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var seen = Set<pid_t>(), out: [MenuBarManagerAppRef] = []
        for w in list {
            guard let name = w[kCGWindowOwnerName as String] as? String, systemOwners.contains(name),
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid > 0, seen.insert(pid_t(pid)).inserted else { continue }
            out.append(MenuBarManagerAppRef(pid: pid_t(pid), name: name))
        }
        return out
    }

    /// Walks `AXExtrasMenuBar` of every app (plus system agents) and returns each extra's frame.
    /// Blocking; call off the main thread. Needs Accessibility.
    /// `own` is MacMaster's own items from `ownStatusItems()`; our process is never asked through AX.
    nonisolated static func axStatusItems(apps: [MenuBarManagerAppRef], own: [MenuBarManagerRawWindow]) -> [MenuBarManagerRawWindow] {
        var all = apps
        let known = Set(apps.map(\.pid))
        for e in extraAgentPids() where !known.contains(e.pid) { all.append(e) }
        all = all.filter { $0.pid > 0 && $0.pid != SelfAX.pid }

        // Timeouts are set per element in axLeaves; the system-wide one is process-global and would starve
        // every other AX caller (tiling, window previews...) down to 0.1s.
        let lock = NSLock()
        nonisolated(unsafe) var results: [MenuBarManagerRawWindow] = []
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            let found = axLeaves(of: all[i]).map(\.raw)
            guard !found.isEmpty else { return }
            lock.lock(); results.append(contentsOf: found); lock.unlock()
        }
        return results.isEmpty ? [] : results + own
    }

    /// MacMaster's own status items, read through AppKit with the same ids and keys `axLeaves` would give
    /// them. Asking AX about our own process runs our accessibility code on the asking (background) thread;
    /// an exception there leaves SwiftUI's lock held and freezes the app. See `SelfAX`.
    @MainActor static func ownStatusItems() -> [MenuBarManagerRawWindow] {
        let pid = SelfAX.pid
        let name = NSRunningApplication.current.localizedName ?? "MacMaster"
        let owner = Bundle.main.bundleIdentifier ?? name
        var ordinals: [String: Int] = [:]
        var out: [MenuBarManagerRawWindow] = []
        for (item, w) in ownItems() {
            // Keys use what AX reported for our buttons (their accessibility identifier, normally empty),
            // so saved favorites and hidden items keep matching.
            let ident = item.button?.accessibilityIdentifier() ?? ""
            let title = item.button?.title ?? ""
            let desc = item.button?.accessibilityLabel() ?? ""
            let label = !title.isEmpty ? title : (!desc.isEmpty ? desc : ident)
            let base = "\(pid)|\(ident.isEmpty ? label : ident)"
            let n = ordinals[base, default: 0]
            ordinals[base] = n + 1
            let key = "\(base)|\(n)"
            out.append(MenuBarManagerRawWindow(
                id: fnv(key), pid: pid, ownerName: name, title: label,
                frame: MenuBarManagerGeometry.cgRect(fromAppKit: w.frame),
                layer: statusLevel, isOnScreen: true, identifier: item.autosaveName ?? ident, key: key,
                bundleID: owner, stableKey: "\(owner)|\(ident.isEmpty ? label : ident)|\(n)"))
        }
        return out
    }

    /// Clicks one of our own status items (by `stableKey` from `ownStatusItems()`). False if it's gone.
    @MainActor static func pressOwn(stableKey: String, secondary: Bool = false) -> Bool {
        let own = ownStatusItems()
        guard let i = own.firstIndex(where: { $0.stableKey == stableKey }) else { return false }
        let items = ownItems()
        guard i < items.count, let button = items[i].0.button else { return false }
        if secondary, let menu = items[i].0.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            button.performClick(nil)
        }
        return true
    }

    /// Visible status bar windows on a screen and their items, in window order. `statusItem` is AppKit's own
    /// (undocumented) back pointer from NSStatusBarWindow; checked before use. macOS 26+ also keeps parked
    /// copies of each window below the screen; those are skipped.
    @MainActor private static func ownItems() -> [(NSStatusItem, NSWindow)] {
        let sel = NSSelectorFromString("statusItem")
        let screens = NSScreen.screens.map(\.frame)
        return NSApp.windows.compactMap { w in
            guard w.isVisible, w.frame.width > 0, w.frame.height > 0,
                  screens.contains(where: { $0.intersects(w.frame) }),
                  w.responds(to: sel), let item = w.value(forKey: "statusItem") as? NSStatusItem else { return nil }
            return (item, w)
        }
    }

    /// One menu bar item of an app: the AX element to act on plus its raw record.
    struct AXLeaf {
        let element: AXUIElement
        let raw: MenuBarManagerRawWindow
    }

    /// Items of one app's `AXExtrasMenuBar`. macOS 26+ wraps system items (Wi-Fi, clock...) in AXGroup /
    /// AXHostingView children of MenuBarAgent; descend to the inner AXMenuBarItem so they get a real identifier.
    nonisolated static func axLeaves(of app: MenuBarManagerAppRef, timeout: Float = 0.1) -> [AXLeaf] {
        guard app.pid != SelfAX.pid else { return [] }
        let el = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return [] }
        let bar = unsafeBitCast(barRef, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(bar, timeout)
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return [] }
        let system = systemOwners.contains(app.name)
        let owner = app.bundleID.isEmpty ? app.name : app.bundleID
        var ordinals: [String: Int] = [:]
        var out: [AXLeaf] = []
        for kid in kids {
            AXUIElementSetMessagingTimeout(kid, timeout)
            let inner = innerMenuBarItem(of: kid, timeout: timeout)
            let leaf = inner ?? kid
            guard let f = axRect(leaf) ?? axRect(kid), f.width > 0, f.height > 0 else { continue }
            var ident = axString(leaf, kAXIdentifierAttribute)
            var title = axString(leaf, kAXTitleAttribute)
            var desc = axString(leaf, kAXDescriptionAttribute)
            if inner != nil {
                if ident.isEmpty { ident = axString(kid, kAXIdentifierAttribute) }
                if title.isEmpty { title = axString(kid, kAXTitleAttribute) }
                if desc.isEmpty { desc = axString(kid, kAXDescriptionAttribute) }
            }
            let label = !title.isEmpty ? title : (!desc.isEmpty ? desc : ident)
            let base = "\(app.pid)|\(ident.isEmpty ? label : ident)"
            let n = ordinals[base, default: 0]
            ordinals[base] = n + 1
            let key = "\(base)|\(n)"
            let isSystem = system || ident.hasPrefix("com.apple.menuextra")
            let stable: String
            if isSystem, ident.hasPrefix("com.apple.menuextra") {
                stable = n == 0 ? ident : "\(ident)|\(n)"
            } else {
                stable = "\(owner)|\(ident.isEmpty ? label : ident)|\(n)"
            }
            let raw = MenuBarManagerRawWindow(
                id: fnv(key), pid: app.pid,
                ownerName: system ? "Control Center" : app.name,
                title: label, frame: f,
                layer: statusLevel, isOnScreen: true, identifier: ident, key: key,
                bundleID: app.bundleID, stableKey: stable, isSystem: isSystem)
            out.append(AXLeaf(element: leaf, raw: raw))
        }
        return out
    }

    /// First AXMenuBarItem below `el` (depth <= 3), unless `el` already is one.
    private nonisolated static func innerMenuBarItem(of el: AXUIElement, depth: Int = 0, timeout: Float = 0.1) -> AXUIElement? {
        if depth == 0, axString(el, kAXRoleAttribute) == "AXMenuBarItem" { return nil }
        guard depth < 3 else { return nil }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids {
            AXUIElementSetMessagingTimeout(k, timeout)
            if axString(k, kAXRoleAttribute) == "AXMenuBarItem" { return k }
            if let found = innerMenuBarItem(of: k, depth: depth + 1, timeout: timeout) { return found }
        }
        return nil
    }

    nonisolated static func axString(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        return (ref as? String) ?? ""
    }

    nonisolated static func axRect(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &sz) else { return nil }
        return CGRect(origin: p, size: sz)
    }

    /// True if any of `pids` currently owns a pop-up-menu-level (or higher) window that is on screen.
    nonisolated static func hasOpenMenu(pids: Set<pid_t>) -> Bool {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, pids.contains(pid_t(owner)),
                  let layer = w[kCGWindowLayer as String] as? Int else { continue }
            if layer >= popUpLevel { return true }
        }
        return false
    }
}
