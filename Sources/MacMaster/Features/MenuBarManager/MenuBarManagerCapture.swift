import AppKit
import ScreenCaptureKit

/// Captured menu bar item image.
struct MenuBarManagerCapturedImage {
    let image: NSImage
    /// Region captures include the menu bar background, so they're always drawn as-is.
    let isMonochrome: Bool
    let date: Date
}

/// Captures each item's region of the menu bar with ScreenCaptureKit (display filter + `sourceRect`)
/// and caches it by item key. Items must be on-screen (expanded) to be captured.
@MainActor
final class MenuBarManagerCapture {
    static let shared = MenuBarManagerCapture()

    private(set) var cache: [String: MenuBarManagerCapturedImage] = [:]
    private var inFlight = false
    private var lastAttempt: [String: Date] = [:]

    /// What to capture: a cache key and the item's frame in global CG coordinates.
    struct Request {
        let key: String
        let frame: CGRect
    }

    func image(for item: MenuBarManagerItem) -> MenuBarManagerCapturedImage? { cache[item.cacheKey] }
    func image(for entry: MenuBarManagerEntry) -> MenuBarManagerCapturedImage? { cache[entry.cacheKey] }

    func prune(keeping keys: Set<String>) {
        for k in cache.keys where !keys.contains(k) { cache.removeValue(forKey: k) }
    }

    func remove(prefix: String) {
        for k in cache.keys where k.hasPrefix(prefix) { cache.removeValue(forKey: k) }
        for k in lastAttempt.keys where k.hasPrefix(prefix) { lastAttempt.removeValue(forKey: k) }
    }

    func removeAll() { cache.removeAll(); lastAttempt.removeAll() }

    /// Capture items whose cached image is missing or older than `maxAge`. Returns true if anything changed.
    @discardableResult
    func refresh(_ items: [MenuBarManagerItem], maxAge: TimeInterval = 30) async -> Bool {
        let reqs = items.compactMap { it -> Request? in
            guard it.frame.width > 1, !it.isOffscreen, !it.isClipped else { return nil }
            return Request(key: it.cacheKey, frame: it.frame)
        }
        return await refresh(requests: reqs, maxAge: maxAge)
    }

    @discardableResult
    func refresh(_ entries: [MenuBarManagerEntry], maxAge: TimeInterval = 30) async -> Bool {
        let reqs = entries.filter(\.canCapture).map { Request(key: $0.cacheKey, frame: $0.frame) }
        return await refresh(requests: reqs, maxAge: maxAge)
    }

    @discardableResult
    func refresh(requests: [Request], maxAge: TimeInterval = 30) async -> Bool {
        guard Permissions.isGranted(.screenRecording), !inFlight else { return false }
        let now = Date()
        let wanted = requests.filter { it in
            if let t = lastAttempt[it.key], now.timeIntervalSince(t) < 15 { return false } // back off
            if let c = cache[it.key] { return now.timeIntervalSince(c.date) > maxAge }
            return true
        }
        guard !wanted.isEmpty else { return false }
        inFlight = true
        defer { inFlight = false }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              !content.displays.isEmpty else { return false }
        var changed = false
        for it in wanted {
            lastAttempt[it.key] = now
            let mid = CGPoint(x: it.frame.midX, y: it.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(mid) }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = max(1, Int(NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            })?.backingScaleFactor ?? 2))
            // sourceRect is in the display's own point space (top-left origin).
            cfg.sourceRect = CGRect(x: it.frame.minX - display.frame.minX, y: it.frame.minY - display.frame.minY,
                                    width: it.frame.width, height: it.frame.height)
            cfg.width = max(1, Int(it.frame.width.rounded(.up))) * scale
            cfg.height = max(1, Int(it.frame.height.rounded(.up))) * scale
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                  cg.width > 1 else { continue }
            let img = NSImage(cgImage: cg, size: NSSize(width: it.frame.width, height: it.frame.height))
            cache[it.key] = MenuBarManagerCapturedImage(image: img, isMonochrome: false, date: now)
            changed = true
        }
        return changed
    }
}
