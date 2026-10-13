import AppKit
import ScreenCaptureKit

/// ScreenCaptureKit window screenshots with a small bounded cache.
actor WindowPreviewThumbnailer {
    static let shared = WindowPreviewThumbnailer()

    private struct Entry {
        var image: CGImage
        var date: Date
        var pixelWidth: Int
    }

    private var cache: [UInt32: Entry] = [:]
    /// Windows that couldn't be captured recently (minimized, other Space...): don't hammer SCK for them.
    private var failed: [UInt32: Date] = [:]
    /// Last untransformed size seen per window (AX often lists no windows for apps sitting in the Stage Manager strip).
    private var cleanSize: [UInt32: CGSize] = [:]
    private let maxEntries = 90
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private var inflight: Task<SCShareableContent?, Never>?

    /// Thumbnails saved to disk survive relaunches, so windows sitting in the Stage Manager strip
    /// (which can't be captured untilted) still have a picture after MacMaster restarts.
    private var diskLoaded = false
    private nonisolated static let diskQueue = DispatchQueue(label: "MacMaster.thumbs.disk", qos: .utility)
    private nonisolated static let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.macmaster.app/WindowThumbs", isDirectory: true)
    }()

    /// Window ids are only unique within one login session: key the disk cache by boot + loginwindow.
    private nonisolated static func sessionKey() -> String {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        let login = RunningAppCache.shared.apps.first { $0.bundleID == "com.apple.loginwindow" }?.pid ?? 0
        return "\(tv.tv_sec)-\(login)"
    }

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        let fm = FileManager.default
        let dir = Self.diskDir
        let keyURL = dir.appendingPathComponent("session")
        let key = Self.sessionKey()
        if (try? String(contentsOf: keyURL, encoding: .utf8)) != key {
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? key.write(to: keyURL, atomically: true, encoding: .utf8)
            return
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.pathExtension == "jpg" {
            guard let id = UInt32(f.deletingPathExtension().lastPathComponent), cache[id] == nil,
                  let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            cache[id] = Entry(image: img, date: min(date, Date().addingTimeInterval(-120)), pixelWidth: img.width)
        }
    }

    private nonisolated static func save(_ image: CGImage, id: UInt32) {
        diskQueue.async {
            let url = diskDir.appendingPathComponent("\(id).jpg")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    private nonisolated static func remove(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        diskQueue.async {
            for id in ids { try? FileManager.default.removeItem(at: diskDir.appendingPathComponent("\(id).jpg")) }
        }
    }

    /// Any recent image for the window (stale-while-revalidate).
    func cached(_ id: UInt32, maxAge: TimeInterval = 30) -> CGImage? {
        guard let e = cache[id], Date().timeIntervalSince(e.date) < maxAge else { return nil }
        return e.image
    }

    /// Whatever is cached for a window regardless of age (for instant first paint).
    func peek(_ id: UInt32) -> (image: CGImage, age: TimeInterval, pixelWidth: Int)? {
        loadDiskIfNeeded()
        guard let e = cache[id] else { return nil }
        return (e.image, Date().timeIntervalSince(e.date), e.pixelWidth)
    }

    func peekAll(_ ids: [UInt32]) -> [UInt32: CGImage] {
        loadDiskIfNeeded()
        var out: [UInt32: CGImage] = [:]
        for id in ids { if let e = cache[id] { out[id] = e.image } }
        return out
    }

    /// Forget thumbnails of windows that no longer exist.
    func prune(keeping ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }   // an empty list is a failed read, not "every window closed"
        let gone = cache.keys.filter { !ids.contains($0) }
        for k in gone { cache[k] = nil }
        Self.remove(gone)
        for k in cleanSize.keys where !ids.contains(k) { cleanSize[k] = nil }
    }

    func capture(id: UInt32, box: CGSize, maxAge: TimeInterval) async -> CGImage? {
        let wantWidth = Int(box.width)
        if id & 0x8000_0000 != 0 { return nil } // synthetic id, no real window
        loadDiskIfNeeded()
        if let f = failed[id], Date().timeIntervalSince(f) < 15 { return nil }
        if let e = cache[id], Date().timeIntervalSince(e.date) < maxAge, e.pixelWidth >= wantWidth - 8 { return e.image }

        var shareable = await shareableContent(refresh: false)
        var target = shareable?.windows.first { $0.windowID == id }
        if target == nil {
            shareable = await shareableContent(refresh: true)
            target = shareable?.windows.first { $0.windowID == id }
        }
        guard let scWindow = target, scWindow.frame.width > 1, scWindow.frame.height > 1 else {
            failed[id] = Date()
            return nil
        }

        // Live bounds: the shareable-content list can be seconds old, and Stage Manager animates windows in and out.
        let frame = WindowPreviewStageManager.liveBounds(id) ?? scWindow.frame
        guard frame.width > 1, frame.height > 1 else { return cache[id]?.image }

        // Stage Manager shows non-active windows shrunk and tilted in its side strip, and SCK captures
        // them exactly like that. Keep the last clean image instead of replacing it with a skewed one.
        var provisional = false
        if WindowPreviewStageManager.isEnabled {
            let pid = scWindow.owningApplication?.processID
            let real = pid.flatMap { WindowPreviewStageManager.realSize(pid: $0, id: id) } ?? cleanSize[id]
            let shrunk = real.map { frame.width < $0.width * 0.92 || frame.height < $0.height * 0.92 }
                ?? WindowPreviewStageManager.looksLikeStrip(frame)
            if shrunk {
                if let cached = cache[id]?.image { return cached }
                // Never seen this window un-shrunk (e.g. an app you haven't switched to since launch):
                // a strip-sized capture beats an icon-only tile. Marked stale so a clean one replaces it.
                provisional = true
            } else {
                cleanSize[id] = frame.size
            }
        }

        let scale = min(box.width / frame.width, box.height / frame.height, 2)
        let cfg = SCStreamConfiguration()
        cfg.width = max(2, Int(frame.width * scale))
        cfg.height = max(2, Int(frame.height * scale))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
            failed[id] = Date()
            return cache[id]?.image
        }

        store(image, id: id, wantWidth: wantWidth, provisional: provisional)
        return image
    }

    private func store(_ image: CGImage, id: UInt32, wantWidth: Int, provisional: Bool = false) {
        failed[id] = nil
        // Requested box width, not the aspect-fitted one. Provisional (strip-sized) images are dated in the
        // past so the next un-shrunk sighting recaptures; they're kept in memory only.
        cache[id] = Entry(image: image, date: provisional ? .distantPast : Date(), pixelWidth: wantWidth)
        if !provisional { Self.save(image, id: id) }
        if cache.count > maxEntries {
            let drop = cache.sorted { $0.value.date < $1.value.date }.prefix(cache.count - maxEntries)
            for (k, _) in drop { cache[k] = nil }
            Self.remove(drop.map(\.key))
        }
    }

    /// Drop the in-memory cache (switcher turned off). `disk: true` also wipes saved thumbnails (permissions changed).
    func clear(disk: Bool = false) {
        if disk { Self.remove(Array(cache.keys)) }
        diskLoaded = false
        cache.removeAll()
        failed.removeAll()
        content = nil
    }

    private func shareableContent(refresh: Bool) async -> SCShareableContent? {
        if !refresh, let c = content, Date().timeIntervalSince(contentDate) < 2 { return c }
        if let t = inflight { return await t.value }
        let t = Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        inflight = t
        let c = await t.value
        inflight = nil
        if let c { content = c; contentDate = Date() }
        return c
    }
}

/// Stage Manager state and the untransformed window size (AX reports the real size, CG/SCK the strip one).
enum WindowPreviewStageManager {
    nonisolated(unsafe) private static var cached: (value: Bool, date: Date)?
    static var isEnabled: Bool {
        if let c = cached, Date().timeIntervalSince(c.date) < 5 { return c.value }
        let v = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        cached = (v, Date())
        return v
    }

    static func liveBounds(_ id: UInt32) -> CGRect? {
        // The array must hold raw CGWindowID values, not NSNumbers.
        var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &raw, 1, nil),
              let arr = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let d = arr.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: d)
    }

    /// No reference size: a small window hugging the left or right screen edge is a strip thumbnail.
    static func looksLikeStrip(_ f: CGRect) -> Bool {
        guard f.width < 320, f.height < 320 else { return false }
        let screens = NSScreen.screens
        guard let primaryH = screens.first?.frame.maxY else { return false }
        let mid = CGPoint(x: f.midX, y: primaryH - f.midY) // CG (top-left) → AppKit coordinates
        guard let screen = screens.first(where: { $0.frame.contains(mid) }) else { return false }
        return f.minX - screen.frame.minX < 260 || screen.frame.maxX - f.maxX < 260
    }

    static func realSize(pid: pid_t, id: UInt32) -> CGSize? {
        guard Permissions.isGranted(.accessibility) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let win = WindowPreviewAX.elements(app, kAXWindowsAttribute).first(where: { WindowPreviewAX.windowID($0) == id }),
              let f = WindowPreviewAX.frame(win), f.width > 1, f.height > 1 else { return nil }
        return f.size
    }
}
