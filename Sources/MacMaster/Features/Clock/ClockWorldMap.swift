import SwiftUI

/// Shared geometry for the world map: an equirectangular strip from 84N to 60S.
enum ClockWorldMap {
    static let latTop = 84.0, latBottom = -60.0
    /// Width / height of the strip (360 degrees by 144 degrees).
    static let aspect: CGFloat = 2.5

    static func point(lat: Double, lon: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: (lon + 180) / 360 * size.width,
                y: (latTop - lat) / (latTop - latBottom) * size.height)
    }

    /// Dot sets for the strides the map can use, built once.
    static let dotSets: [Int: [(lat: Double, lon: Double)]] = {
        var out: [Int: [(lat: Double, lon: Double)]] = [:]
        for s in 2...5 { out[s] = ClockLandMask.dots(stride: s, latTop: Int(latTop), latBottom: Int(latBottom)) }
        return out
    }()

    /// Night-side darkness (0...1) for a sun altitude in degrees: clear by day, then civil, nautical and
    /// astronomical twilight each darken further, with full night beyond -18.
    static func nightAlpha(_ altitude: Double) -> Double {
        let stops: [(Double, Double)] = [(0.5, 0), (0, 0.12), (-6, 0.30), (-12, 0.46), (-18, 0.58), (-30, 0.64)]
        if altitude >= stops[0].0 { return 0 }
        for i in 1..<stops.count where altitude >= stops[i].0 {
            let (a0, v0) = stops[i - 1], (a1, v1) = stops[i]
            return v0 + (v1 - v0) * (altitude - a0) / (a1 - a0)
        }
        return stops[stops.count - 1].1
    }

    /// Soft night shading as a small RGBA image (2 degrees per pixel), stretched over the map.
    static func nightImage(sun: ClockSun) -> CGImage? {
        let cols = 180, rows = 72
        var px = [UInt8](repeating: 0, count: cols * rows * 4)
        let span = latTop - latBottom
        for j in 0..<rows {
            let lat = latTop - (Double(j) + 0.5) / Double(rows) * span
            for i in 0..<cols {
                let lon = -180 + (Double(i) + 0.5) / Double(cols) * 360
                let a = nightAlpha(sun.altitude(lat: lat, lon: lon))
                let o = (j * cols + i) * 4
                // Premultiplied deep blue.
                px[o] = UInt8(8 * a); px[o + 1] = UInt8(14 * a); px[o + 2] = UInt8(48 * a); px[o + 3] = UInt8(255 * a)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func markers(zones: [String]) -> [ClockMapMarker] {
        var ids = [TimeZone.current.identifier]
        for z in zones where !ids.contains(z) { ids.append(z) }
        return ids.enumerated().map { i, id in
            ClockMapMarker(id: id, name: i == 0 ? "\(ClockZones.city(id)) (here)" : ClockZones.city(id),
                           point: ClockGeo.coordinate(for: id), isLocal: i == 0)
        }
    }
}

struct ClockMapMarker: Identifiable {
    let id: String
    let name: String
    let point: ClockGeo.Point
    let isLocal: Bool
}

/// Dotted world map with a live day/night terminator and a dot per world-clock city.
struct ClockWorldMapView: View {
    let zones: [String]
    var compact = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            TimelineView(.everyMinute) { ctx in
                ClockMapCanvas(date: ctx.date)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
            ClockMapMarkers(zones: zones, compact: compact)
        }
        .aspectRatio(ClockWorldMap.aspect, contentMode: .fit)
        .frame(maxWidth: compact ? .infinity : 760)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World map showing where it is day and night")
    }
}

/// The land dots, night shading and sun. Redrawn once a minute by its parent timeline.
struct ClockMapCanvas: View {
    let date: Date

    var body: some View {
        Canvas { ctx, size in
            let sun = ClockSun(date: date)
            let perDeg = size.width / 360
            let stride = max(2, min(5, Int((3.4 / max(perDeg, 0.1)).rounded())))
            let d = max(1.2, Double(stride) * perDeg * 0.56)

            // Land dots, shaded by how high the sun is there.
            var buckets = [Path(), Path(), Path(), Path()]
            for p in ClockWorldMap.dotSets[stride] ?? [] {
                let a = sun.altitude(lat: p.lat, lon: p.lon)
                let k = a > 0 ? 0 : a > -6 ? 1 : a > -12 ? 2 : 3
                let c = ClockWorldMap.point(lat: p.lat, lon: p.lon, in: size)
                buckets[k].addEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            }
            let opacities = [0.62, 0.44, 0.30, 0.20]
            for (k, path) in buckets.enumerated() { ctx.fill(path, with: .color(Color.primary.opacity(opacities[k]))) }

            // Night shading on top, so ocean darkens too and the terminator reads clearly.
            if let img = ClockWorldMap.nightImage(sun: sun) {
                let resolved = ctx.resolve(Image(decorative: img, scale: 1).interpolation(.high))
                ctx.draw(resolved, in: CGRect(origin: .zero, size: size))
            }

            // Sun.
            let s = ClockWorldMap.point(lat: sun.lat, lon: sun.lon, in: size)
            let glow = max(10, size.width * 0.03)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - glow, y: s.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [Color.yellow.opacity(0.55), .clear]),
                                           center: s, startRadius: 0, endRadius: glow))
            let r = max(3, size.width * 0.009)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)), with: .color(.yellow))
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)),
                       with: .color(.orange), lineWidth: 1)
        }
    }
}

/// City dots plus the hover label. Hover state lives here so the Canvas is never redrawn by the pointer.
struct ClockMapMarkers: View {
    let zones: [String]
    let compact: Bool
    @State private var settings = ClockSettings.shared
    @State private var hoverID: String?

    var body: some View {
        GeometryReader { geo in
            let items = ClockWorldMap.markers(zones: zones)
            let positions = items.map { ClockWorldMap.point(lat: $0.point.lat, lon: $0.point.lon, in: geo.size) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    dot(m, hovered: hoverID == m.id)
                        .position(positions[i])
                }
                if let id = hoverID, let i = items.firstIndex(where: { $0.id == id }) {
                    tooltip(items[i], at: positions[i], in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    var best: (id: String, dist: CGFloat)?
                    for (i, m) in items.enumerated() {
                        let dist = hypot(positions[i].x - p.x, positions[i].y - p.y)
                        if dist <= 12, dist < (best?.dist ?? .infinity) { best = (m.id, dist) }
                    }
                    if hoverID != best?.id { hoverID = best?.id }
                case .ended:
                    hoverID = nil
                }
            }
        }
    }

    private func dot(_ m: ClockMapMarker, hovered: Bool) -> some View {
        let base: CGFloat = compact ? 5 : 6
        let size = hovered ? base + 2 : base
        return ZStack {
            if m.isLocal { Circle().fill(Color.accentColor.opacity(0.3)).frame(width: size * 2.4, height: size * 2.4) }
            Circle().fill(m.isLocal ? Color.accentColor : Color.orange)
                .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .frame(width: size, height: size)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func tooltip(_ m: ClockMapMarker, at p: CGPoint, in size: CGSize) -> some View {
        let now = Date()
        let tz = TimeZone(identifier: m.id) ?? .current
        let phase = ClockSun(date: now).phase(lat: m.point.lat, lon: m.point.lon)
        let time = now.formatted(Date.FormatStyle(timeZone: tz)
            .hour(settings.use24h ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)).minute())
        let leftHalf = p.x < size.width / 2
        return VStack(alignment: .leading, spacing: 1) {
            Text(m.name).font(.caption.weight(.semibold))
            HStack(spacing: 4) {
                Image(systemName: phase == .day ? "sun.max.fill" : phase == .twilight ? "sun.haze.fill" : "moon.stars.fill")
                    .foregroundStyle(phase == .day ? Color.orange : phase == .twilight ? Color.pink : Color.indigo)
                Text("\(time) \u{00B7} \(phase.rawValue)").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .fixedSize()
        .alignmentGuide(.leading) { d in leftHalf ? -(p.x + 9) : d.width - (p.x - 9) }
        .alignmentGuide(.top) { d in p.y < d.height + 14 ? -(p.y + 9) : d.height - (p.y - 9) }
        .allowsHitTesting(false)
    }
}
