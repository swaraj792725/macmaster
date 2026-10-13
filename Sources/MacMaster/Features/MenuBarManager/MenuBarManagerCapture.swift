import AppKit
import ScreenCaptureKit
import SwiftUI

/// Captured menu bar item image.
struct MenuBarManagerCapturedImage {
    /// `keyed`: the neutral (white / black / grey) part of the glyph as black-on-clear, drawn as a template so it takes
    /// the label colour of wherever it's shown. Otherwise the raw opaque capture.
    let image: NSImage
    /// Coloured part (badges, a red battery...), drawn as-is. Nil for plain glyphs.
    let color: NSImage?
    /// The bar's backdrop was keyed out. False only for degenerate captures (the raw image is kept).
    let keyed: Bool
    let date: Date
}

/// Draws a capture at its natural aspect ratio, tinted by the surrounding appearance when keyed.
struct MenuBarManagerCaptureView: View {
    let capture: MenuBarManagerCapturedImage

    var body: some View {
        ZStack {
            if capture.keyed {
                Image(nsImage: capture.image).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.primary)
                if let c = capture.color { Image(nsImage: c).renderingMode(.original).resizable().scaledToFit() }
            } else {
                Image(nsImage: capture.image).renderingMode(.original).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .aspectRatio(capture.image.size, contentMode: .fit)
    }
}

/// Region captures come back opaque: ScreenCaptureKit composites the bar's items over the backdrop (black, or the
/// wallpaper-tinted bar colour), so drawn as-is they show as solid rectangles. This keys that backdrop out:
/// alpha = how far a pixel is from the backdrop (relative to the furthest it could be), colour is un-blended.
/// Grey pixels go to a template layer (re-tinted per appearance), saturated ones to a colour layer.
enum MenuBarManagerKeyer {
    nonisolated static func key(_ cg: CGImage, size: NSSize) -> (neutral: NSImage, color: NSImage?)? {
        let w = cg.width, h = cg.height
        guard w > 3, h > 3 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Backdrop = most common colour along the top and bottom edges (empty bar above and below the glyph).
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        var ring: [(Int, Int, Int)] = []
        // Top and bottom rows only: glyphs can run to the side edges but not the full bar height.
        for x in 0..<w { ring.append(at(x, 0)); ring.append(at(x, h - 1)); ring.append(at(x, 1)); ring.append(at(x, h - 2)) }
        var bins: [Int: Int] = [:]
        for c in ring { bins[(c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4), default: 0] += 1 }
        guard let top = bins.max(by: { $0.value < $1.value })?.key else { return nil }
        let members = ring.filter { (($0.0 >> 4) << 8 | ($0.1 >> 4) << 4 | ($0.2 >> 4)) == top }
        let n = Float(members.count)
        let bg: (Float, Float, Float) = (
            Float(members.reduce(0) { $0 + $1.0 }) / n / 255,
            Float(members.reduce(0) { $0 + $1.1 }) / n / 255,
            Float(members.reduce(0) { $0 + $1.2 }) / n / 255)
        // Furthest a pixel can sit from the backdrop per channel (a white glyph on black: 1).
        let sr = 1 / max(bg.0, 1 - bg.0, 0.1), sg = 1 / max(bg.1, 1 - bg.1, 0.1), sb = 1 / max(bg.2, 1 - bg.2, 0.1)
        var neutral = [UInt8](repeating: 0, count: w * h * 4)
        var colored = [UInt8](repeating: 0, count: w * h * 4)
        var colorPixels = 0
        for i in 0..<(w * h) {
            let r = Float(px[i * 4]) / 255, g = Float(px[i * 4 + 1]) / 255, b = Float(px[i * 4 + 2]) / 255
            let d = min(1, max(abs(r - bg.0) * sr, abs(g - bg.1) * sg, abs(b - bg.2) * sb))
            // Dead zone: a wallpaper gradient / blur noise behind the bar must not leave a tinted box.
            let a = (d - 0.1) / 0.9
            guard a > 0.04 else { continue }
            let cr = min(1, max(0, bg.0 + (r - bg.0) / a)), cg = min(1, max(0, bg.1 + (g - bg.1) / a)),
                cb = min(1, max(0, bg.2 + (b - bg.2) / a))
            let sat = max(cr, cg, cb) - min(cr, cg, cb)
            let t = min(1, max(0, (sat - 0.12) / 0.18))
            let wc = t * t * (3 - 2 * t) // weight of the colour layer
            let an = a * (1 - wc), ac = a * wc
            neutral[i * 4 + 3] = UInt8((an * 255).rounded())
            if ac > 0.02 {
                colored[i * 4] = UInt8((cr * ac * 255).rounded())
                colored[i * 4 + 1] = UInt8((cg * ac * 255).rounded())
                colored[i * 4 + 2] = UInt8((cb * ac * 255).rounded())
                colored[i * 4 + 3] = UInt8((ac * 255).rounded())
                if ac > 0.3 { colorPixels += 1 }
            }
        }
        func image(_ data: inout [UInt8], template: Bool) -> NSImage? {
            let out = data.withUnsafeMutableBytes { buf -> CGImage? in
                CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: info)?.makeImage()
            }
            guard let out else { return nil }
            let img = NSImage(cgImage: out, size: size)
            img.isTemplate = template
            return img
        }
        guard let neutralImage = image(&neutral, template: true) else { return nil }
        return (neutralImage, colorPixels >= 3 ? image(&colored, template: false) : nil)
    }
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
            let size = NSSize(width: it.frame.width, height: it.frame.height)
            if let k = MenuBarManagerKeyer.key(cg, size: size) {
                cache[it.key] = MenuBarManagerCapturedImage(image: k.neutral, color: k.color, keyed: true, date: now)
            } else {
                cache[it.key] = MenuBarManagerCapturedImage(image: NSImage(cgImage: cg, size: size), color: nil, keyed: false, date: now)
            }
            changed = true
        }
        return changed
    }
}
