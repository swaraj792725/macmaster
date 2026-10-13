import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Model

struct WindowPreviewWindow: Identifiable, @unchecked Sendable {
    let id: UInt32               // CGWindowID (synthetic with the high bit set when unknown)
    let pid: pid_t
    var title: String
    var appName: String
    var bundleID: String?
    var frame: CGRect
    var isMinimized: Bool
    var isOnScreen: Bool
    var onOtherSpace: Bool
    var order: Int
    var ax: AXUIElement?
}

struct WindowPreviewAppInfo: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
}

// MARK: - AX helpers

enum WindowPreviewAX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        guard let v = attr(el, name) else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (attr(el, name) as? [AXUIElement]) ?? []
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attr(el, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = attr(el, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(s, to: GetWindowFn.self)
    }()

    /// Private-but-stable: maps an AX window to its CGWindowID.
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(el, &id) == .success && id != 0 ? id : nil
    }
}

// MARK: - Enumeration

struct WindowPreviewCGInfo: Sendable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    var bounds: CGRect
    var name: String
    var onScreen: Bool
    var alpha: Double
    var order: Int
}

enum WindowPreviewEnumerator {
    static func cgInfo() -> [WindowPreviewCGInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowPreviewCGInfo] = []
        out.reserveCapacity(list.count)
        for (i, d) in list.enumerated() {
            guard let id = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32 else { continue }
            var rect = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? NSDictionary {
                rect = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
            }
            out.append(WindowPreviewCGInfo(
                id: id, pid: pid,
                layer: d[kCGWindowLayer as String] as? Int ?? 0,
                bounds: rect,
                name: d[kCGWindowName as String] as? String ?? "",
                onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
                alpha: d[kCGWindowAlpha as String] as? Double ?? 1,
                order: i))
        }
        return out
    }

    /// Windows of regular running apps. Call from main; enumeration itself happens off-main.
    @MainActor
    static func runningApps() -> [WindowPreviewAppInfo] {
        RunningAppCache.shared.regularApps
            .map { WindowPreviewAppInfo(pid: $0.pid, name: $0.name, bundleID: $0.bundleID) }
    }

    static func windows(for app: WindowPreviewAppInfo, includeMinimized: Bool) async -> [WindowPreviewWindow] {
        await Task.detached(priority: .userInitiated) {
            windows(app: app, cg: cgInfo(), includeMinimized: includeMinimized)
        }.value
    }

    static func allWindows(apps: [WindowPreviewAppInfo], includeMinimized: Bool) async -> [WindowPreviewWindow] {
        let cg = await Task.detached(priority: .userInitiated) { cgInfo() }.value
        var all: [WindowPreviewWindow] = []
        await withTaskGroup(of: [WindowPreviewWindow].self) { group in
            for app in apps {
                group.addTask(priority: .userInitiated) { windows(app: app, cg: cg, includeMinimized: includeMinimized) }
            }
            for await ws in group { all.append(contentsOf: ws) }
        }
        return all.sorted { $0.order < $1.order }
    }

    /// Sync core. Merges AX windows (titles, minimized, raise handles) with the CG list (z-order,
    /// windows on other Spaces).
    static func windows(app: WindowPreviewAppInfo, cg: [WindowPreviewCGInfo], includeMinimized: Bool) -> [WindowPreviewWindow] {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.4)
        let cgByID = Dictionary(cg.filter { $0.pid == app.pid }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let axWindows = WindowPreviewAX.elements(axApp, kAXWindowsAttribute)

        var result: [WindowPreviewWindow] = []
        var seen = Set<UInt32>()
        for (idx, ax) in axWindows.enumerated() {
            let role = WindowPreviewAX.string(ax, kAXRoleAttribute)
            guard role == nil || role == kAXWindowRole else { continue }
            let subrole = WindowPreviewAX.string(ax, kAXSubroleAttribute)
            if let subrole, subrole != kAXStandardWindowSubrole, subrole != kAXDialogSubrole { continue }
            let frame = WindowPreviewAX.frame(ax) ?? .zero
            if frame.width < 60 || frame.height < 40 { continue }
            let minimized = WindowPreviewAX.bool(ax, kAXMinimizedAttribute) ?? false
            if minimized && !includeMinimized { continue }
            let wid = WindowPreviewAX.windowID(ax)
            let info = wid.flatMap { cgByID[$0] }
            if let info, info.layer != 0 { continue }
            let id = wid ?? (UInt32(truncatingIfNeeded: CFHash(ax)) | 0x8000_0000)
            guard seen.insert(id).inserted else { continue }
            var title = WindowPreviewAX.string(ax, kAXTitleAttribute) ?? ""
            if title.isEmpty { title = info?.name ?? "" }
            if title.isEmpty { title = app.name }
            result.append(WindowPreviewWindow(
                id: id, pid: app.pid, title: title, appName: app.name, bundleID: app.bundleID,
                frame: frame, isMinimized: minimized, isOnScreen: info?.onScreen ?? false,
                onOtherSpace: false,
                order: minimized ? 20_000 + (info?.order ?? idx)
                    : (info.map { $0.onScreen ? $0.order : 12_000 + $0.order } ?? 10_000 + idx), ax: ax))
        }

        // Windows AX can't see (other Spaces). Only trust ones with a title (needs Screen Recording).
        let axFailed = axWindows.isEmpty
        for info in cgByID.values where !seen.contains(info.id) {
            guard info.layer == 0, info.alpha > 0.05, info.bounds.width >= 120, info.bounds.height >= 80 else { continue }
            if info.onScreen && !axFailed { continue }
            if !info.onScreen && info.name.isEmpty { continue }
            let title = info.name.isEmpty ? app.name : info.name
            result.append(WindowPreviewWindow(
                id: info.id, pid: app.pid, title: title, appName: app.name, bundleID: app.bundleID,
                frame: info.bounds, isMinimized: false, isOnScreen: info.onScreen,
                onOtherSpace: !info.onScreen, order: 15_000 + info.order, ax: nil))
        }
        return result.sorted { $0.order < $1.order }
    }
}
