import AppKit

/// Value snapshot of a display. `frame`/`visible` are in AX space (top-left origin, primary screen = (0,0)).
struct TilingScreenInfo: Sendable, Equatable {
    var id: UInt32
    var frame: CGRect
    var visible: CGRect
    var nsFrame: CGRect
}

enum TilingScreens {
    /// Height of the primary screen — the pivot for bottom-left ↔ top-left conversion.
    @MainActor static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    @MainActor static func snapshot() -> [TilingScreenInfo] {
        let h = primaryHeight
        return NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return TilingScreenInfo(id: id, frame: flip(s.frame, h), visible: flip(s.visibleFrame, h), nsFrame: s.frame)
        }
    }

    /// Bottom-left rect → top-left rect (and back; the transform is its own inverse).
    static func flip(_ r: CGRect, _ primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @MainActor static func axPoint(fromNS p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    @MainActor static func nsRect(fromAX r: CGRect) -> CGRect { flip(r, primaryHeight) }
    @MainActor static var mouseAX: CGPoint { axPoint(fromNS: NSEvent.mouseLocation) }

    /// Screen containing the point, else the nearest one.
    static func screen(containing p: CGPoint, in screens: [TilingScreenInfo]) -> TilingScreenInfo? {
        if let s = screens.first(where: { $0.frame.contains(p) }) { return s }
        return screens.min { dist(p, $0.frame) < dist(p, $1.frame) }
    }

    /// Screen with the largest overlap with a window frame (falls back to its center).
    static func screen(for frame: CGRect, in screens: [TilingScreenInfo]) -> TilingScreenInfo? {
        var best: (TilingScreenInfo, CGFloat)?
        for s in screens {
            let i = s.frame.intersection(frame)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? 0) { best = (s, area) }
        }
        if let best { return best.0 }
        return screen(containing: CGPoint(x: frame.midX, y: frame.midY), in: screens)
    }

    private static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

enum TilingGeometry {
    static let halfCycle: [CGFloat] = [0.5, 2.0 / 3.0, 1.0 / 3.0]

    /// Target frame (AX space) for a positional layout. `step` only matters for halves (Rectangle-style cycling).
    static func target(for layout: TilingLayout, current: CGRect, screen: TilingScreenInfo,
                       gap: CGFloat, step: Int = 0) -> CGRect? {
        let vis = screen.visible
        switch layout {
        case .almostMaximize:
            return rounded(vis.insetBy(dx: vis.width * 0.05, dy: vis.height * 0.05))
        case .center:
            let avail = vis.insetBy(dx: gap, dy: gap)
            let w = min(current.width, avail.width), h = min(current.height, avail.height)
            return rounded(CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h))
        case .shrink, .grow:
            let dir: CGFloat = layout == .grow ? 1 : -1
            let dw = vis.width * 0.08 * dir, dh = vis.height * 0.08 * dir
            let w = min(vis.width, max(240, current.width + dw))
            let h = min(vis.height, max(160, current.height + dh))
            var x = current.midX - w / 2, y = current.midY - h / 2
            x = min(max(x, vis.minX), vis.maxX - w)
            y = min(max(y, vis.minY), vis.maxY - h)
            return rounded(CGRect(x: x, y: y, width: w, height: h))
        case .restore, .previousDisplay, .nextDisplay:
            return nil
        default:
            guard var unit = layout.unitRect else { return nil }
            if layout.isHalf {
                let f = halfCycle[((step % 3) + 3) % 3]
                switch layout {
                case .leftHalf: unit = CGRect(x: 0, y: 0, width: f, height: 1)
                case .rightHalf: unit = CGRect(x: 1 - f, y: 0, width: f, height: 1)
                case .topHalf: unit = CGRect(x: 0, y: 0, width: 1, height: f)
                default: unit = CGRect(x: 0, y: 1 - f, width: 1, height: f)
                }
            }
            return tile(unit, in: vis, gap: gap)
        }
    }

    /// Sub-rect of `vis`, with `gap` to screen edges and `gap` between neighbouring tiles.
    static func tile(_ unit: CGRect, in vis: CGRect, gap: CGFloat) -> CGRect {
        let base = vis.insetBy(dx: gap, dy: gap)
        var r = CGRect(x: base.minX + unit.minX * base.width, y: base.minY + unit.minY * base.height,
                       width: unit.width * base.width, height: unit.height * base.height)
        let h = gap / 2
        if unit.minX > 0.001 { r.origin.x += h; r.size.width -= h }
        if unit.maxX < 0.999 { r.size.width -= h }
        if unit.minY > 0.001 { r.origin.y += h; r.size.height -= h }
        if unit.maxY < 0.999 { r.size.height -= h }
        return rounded(r)
    }

    static func rounded(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    static func approx(_ a: CGRect, _ b: CGRect, tol: CGFloat = 6) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// Grid arrangement of `count` tiles (last row stretches to fill).
    static func gridFrames(count: Int, in vis: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        var out: [CGRect] = []
        for r in 0..<rows {
            let inRow = r == rows - 1 ? count - cols * (rows - 1) : cols
            for c in 0..<inRow {
                let unit = CGRect(x: CGFloat(c) / CGFloat(inRow), y: CGFloat(r) / CGFloat(rows),
                                  width: 1 / CGFloat(inRow), height: 1 / CGFloat(rows))
                out.append(tile(unit, in: vis, gap: max(gap, 6)))
            }
        }
        return out
    }
}

// MARK: - Snap zones

enum TilingZones {
    /// Layout for a cursor position (AX space) or nil. Edges shared with another display are ignored.
    static func zone(at p: CGPoint, screens: [TilingScreenInfo], config c: TilingZoneConfig)
        -> (layout: TilingLayout, screen: TilingScreenInfo)? {
        guard let screen = TilingScreens.screen(containing: p, in: screens), screen.frame.contains(p) else { return nil }
        let f = screen.frame
        func covered(_ q: CGPoint) -> Bool { screens.contains { $0.frame.contains(q) } }
        let s = c.sensitivity
        let band = max(s * 4, 40)
        let nearLeft = p.x - f.minX <= s && !covered(CGPoint(x: f.minX - 3, y: p.y))
        let nearRight = f.maxX - p.x <= s && !covered(CGPoint(x: f.maxX + 3, y: p.y))
        let nearTop = p.y - f.minY <= s && !covered(CGPoint(x: p.x, y: f.minY - 3))
        let nearBottom = f.maxY - p.y <= s && !covered(CGPoint(x: p.x, y: f.maxY + 3))
        let inLeftBand = p.x - f.minX <= band, inRightBand = f.maxX - p.x <= band
        let inTopBand = p.y - f.minY <= band, inBottomBand = f.maxY - p.y <= band

        func hit(_ l: TilingLayout) -> (layout: TilingLayout, screen: TilingScreenInfo) { (l, screen) }

        if c.corners {
            if (nearLeft && inTopBand) || (nearTop && inLeftBand) { return hit(.topLeft) }
            if (nearRight && inTopBand) || (nearTop && inRightBand) { return hit(.topRight) }
            if (nearLeft && inBottomBand) || (nearBottom && inLeftBand) { return hit(.bottomLeft) }
            if (nearRight && inBottomBand) || (nearBottom && inRightBand) { return hit(.bottomRight) }
        }
        if c.halves {
            if nearLeft { return hit(.leftHalf) }
            if nearRight { return hit(.rightHalf) }
        }
        if c.top, nearTop { return hit(.maximize) }
        if c.thirds, nearBottom {
            let t = (p.x - f.minX) / f.width
            return hit(t < 1.0 / 3 ? .leftThird : (t < 2.0 / 3 ? .centerThird : .rightThird))
        }
        return nil
    }
}

/// Region of the zone-map diagram (unit coordinates, top-left origin).
struct TilingZoneRegion: Identifiable, Hashable {
    var id: TilingLayout { layout }
    var layout: TilingLayout
    var rect: CGRect

    /// Which snap setting controls this region (nil = always on).
    var toggleKey: String? {
        switch layout {
        case .leftHalf, .rightHalf: TilingSettings.Key.snapHalves
        case .maximize: TilingSettings.Key.snapTop
        case .topLeft, .topRight, .bottomLeft, .bottomRight: TilingSettings.Key.snapCorners
        case .leftThird, .centerThird, .rightThird: TilingSettings.Key.snapThirds
        default: nil
        }
    }

    static let all: [TilingZoneRegion] = {
        let cw = 0.22, ch = 0.3
        let mid = 1 - 2 * cw
        return [
            .init(layout: .topLeft, rect: CGRect(x: 0, y: 0, width: cw, height: ch)),
            .init(layout: .maximize, rect: CGRect(x: cw, y: 0, width: mid, height: ch)),
            .init(layout: .topRight, rect: CGRect(x: 1 - cw, y: 0, width: cw, height: ch)),
            .init(layout: .leftHalf, rect: CGRect(x: 0, y: ch, width: cw, height: 1 - 2 * ch)),
            .init(layout: .center, rect: CGRect(x: cw, y: ch, width: mid, height: 1 - 2 * ch)),
            .init(layout: .rightHalf, rect: CGRect(x: 1 - cw, y: ch, width: cw, height: 1 - 2 * ch)),
            .init(layout: .bottomLeft, rect: CGRect(x: 0, y: 1 - ch, width: cw, height: ch)),
            .init(layout: .leftThird, rect: CGRect(x: cw, y: 1 - ch, width: mid / 3, height: ch)),
            .init(layout: .centerThird, rect: CGRect(x: cw + mid / 3, y: 1 - ch, width: mid / 3, height: ch)),
            .init(layout: .rightThird, rect: CGRect(x: cw + 2 * mid / 3, y: 1 - ch, width: mid / 3, height: ch)),
            .init(layout: .bottomRight, rect: CGRect(x: 1 - cw, y: 1 - ch, width: cw, height: ch)),
        ]
    }()
}
