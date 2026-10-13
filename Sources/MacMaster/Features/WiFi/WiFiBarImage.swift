import SwiftUI
import AppKit

// MARK: - Shapes

/// One Wi-Fi arc, centered on the bottom-middle of its frame. Built from points so the sweep direction is unambiguous.
struct WiFiArcShape: Shape {
    var radiusFraction: Double   // radius as a fraction of the frame height

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let r = rect.height * radiusFraction
        var p = Path()
        let steps = 28
        for i in 0...steps {
            let a = (-135.0 + 90.0 * Double(i) / Double(steps)) * .pi / 180
            let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Wi-Fi glyph: dot plus three arcs. `bars` 0…4 lights the dot and then each arc in turn.
struct WiFiArcsView: View {
    var bars: Int
    var ink: Color = .primary
    var slashed = false
    var height: CGFloat = 14

    var body: some View {
        let lw = height * 0.17
        let dim = ink.opacity(0.3)
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                WiFiArcShape(radiusFraction: [0.50, 0.78, 1.05][i] * 0.92)
                    .stroke(bars >= i + 2 ? ink : dim, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            Circle().fill(bars >= 1 ? ink : dim)
                .frame(width: lw * 1.5, height: lw * 1.5)
                .position(x: height * 0.82, y: height - lw * 0.75)
            if slashed {
                Capsule().fill(ink)
                    .frame(width: lw, height: height * 1.2)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: height * 1.64, height: height)
        .compositingGroup()
    }
}

/// Four rising bars.
struct WiFiBarsView: View {
    var bars: Int
    var ink: Color = .primary
    var slashed = false
    var height: CGFloat = 14

    var body: some View {
        let w = height * 0.22
        HStack(alignment: .bottom, spacing: height * 0.11) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: w * 0.35, style: .continuous)
                    .fill(bars > i ? ink : ink.opacity(0.3))
                    .frame(width: w, height: height * (0.34 + 0.22 * CGFloat(i)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .overlay {
            if slashed {
                Capsule().fill(ink).frame(width: w * 0.8, height: height * 1.25).rotationEffect(.degrees(40))
            }
        }
    }
}

struct WiFiTriangle: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// Small padlock built from shapes so it renders crisply at menu bar sizes.
struct WiFiLockView: View {
    var open = false
    var ink: Color = .primary
    var height: CGFloat = 8

    var body: some View {
        let w = height * 0.9
        ZStack(alignment: .bottom) {
            // Shackle
            Path { p in
                let r = w * 0.27
                let cx = w / 2
                p.move(to: CGPoint(x: cx - r, y: height * 0.5))
                p.addLine(to: CGPoint(x: cx - r, y: height * 0.36))
                p.addArc(center: CGPoint(x: cx, y: height * 0.36), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: CGPoint(x: cx + r, y: open ? height * 0.2 : height * 0.5))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: max(1, height * 0.15), lineCap: .round, lineJoin: .round))
            .frame(width: w, height: height, alignment: .top)
            RoundedRectangle(cornerRadius: height * 0.12, style: .continuous)
                .fill(ink)
                .frame(width: w, height: height * 0.5)
        }
        .frame(width: w, height: height)
    }
}

/// Ring gauge that fills with signal; the Wi-Fi glyph sits in the middle.
struct WiFiRingView: View {
    var bars: Int
    var tint: Color
    var ink: Color
    var slashed = false
    var size: CGFloat = 17

    var body: some View {
        let lw = size * 0.15
        ZStack {
            Circle().stroke(ink.opacity(0.22), lineWidth: lw)
            Circle()
                .trim(from: 0, to: slashed ? 0 : max(0.1, Double(bars) / 4))
                .stroke(tint, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            WiFiArcsView(bars: slashed ? 0 : 4, ink: slashed ? ink.opacity(0.7) : ink, slashed: slashed, height: size * 0.36)
        }
        .padding(lw / 2)
        .frame(width: size, height: size)
    }
}

// MARK: - Bar state

/// Everything the menu bar image shows, as plain values so it can be compared and rendered.
struct WiFiBarState: Equatable {
    var style: WiFiIconStyle
    var powerOn: Bool
    var connected: Bool
    var bars: Int
    var ssid: String
    var rssi: Int
    var tint: UInt32
    var down = ""
    var up = ""
    var band = ""
    /// 0 unknown, 1 secured, 2 open.
    var lock = 0
    /// Last latency in ms for the ping style (nil = not measured yet).
    var pingMs: Int?

    /// Changes only when the picture would change.
    var signature: String {
        // Raw dBm jitters every read; only styles that print it (or the name) should redraw for it.
        let dbm = style == .wifiDbm ? String(rssi) : ""
        let name = style.showsName ? ssid : ""
        let extra = "\(band)|\(lock)|\(pingMs.map(String.init) ?? "")"
        return "\(style.rawValue)|\(powerOn)|\(connected)|\(bars)|\(name)|\(dbm)|\(tint)|\(down)|\(up)|\(extra)"
    }

    /// Placeholder values for previews (style picker, right-click menu) when there's no live link to show.
    static func sample(style: WiFiIconStyle) -> WiFiBarState {
        var s = WiFiBarState(style: style, powerOn: true, connected: true, bars: 3, ssid: "Home Wi-Fi", rssi: -58,
                             tint: 0x30D158, down: "1.2M", up: "84K")
        if style == .activity { s.down = "1"; s.up = "1" }
        s.band = "5G"; s.lock = 1; s.pingMs = 14
        return s
    }

    @MainActor static func make(link: WiFiLink, style: WiFiIconStyle) -> WiFiBarState {
        var s = WiFiBarState(style: style, powerOn: link.powerOn, connected: link.isConnected, bars: link.bars,
                             ssid: link.ssid ?? "", rssi: link.rssi, tint: tintHex(link))
        if style.showsSpeed {
            let n = SystemMonitor.shared.network
            if style == .activity {
                // Arrows only light up or not: keep the signature coarse so idle redraws stay rare.
                s.down = n.downRate > 2_000 ? "1" : "0"
                s.up = n.upRate > 2_000 ? "1" : "0"
            } else {
                s.down = WiFiFmt.compactRate(n.downRate)
                s.up = WiFiFmt.compactRate(n.upRate)
            }
        }
        if style == .band { s.band = link.bandBadge }
        if style == .lock { s.lock = link.lockState }
        if style == .ping { s.pingMs = WiFiModel.shared.barPingMs }
        return s
    }

    private static func tintHex(_ l: WiFiLink) -> UInt32 {
        guard l.isConnected, l.rssi != 0 else { return 0x8E8E93 }
        switch l.rssi {
        case (-60)...: return 0x30D158
        case (-70)...: return 0xFF9F0A
        default: return 0xFF453A
        }
    }
}

// MARK: - Bar item view

struct WiFiBarItemView: View {
    let state: WiFiBarState
    let dark: Bool
    /// Settings previews pass the label color so template styles look right on any background.
    var inkOverride: Color?

    private var ink: Color {
        inkOverride ?? (state.style.isTemplate ? .black : (dark ? .white : .black))
    }
    private var slashed: Bool { !state.connected }
    /// Opposite of the label color, for text on solid fills.
    private var inverse: Color { dark ? .black : .white }

    var body: some View {
        HStack(spacing: 5) { content }
            .padding(.horizontal, 2)
            .frame(height: 18)
    }

    @ViewBuilder private var content: some View {
        switch state.style {
        case .classic:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed)
        case .bars:
            WiFiBarsView(bars: state.bars, ink: ink, slashed: slashed)
        case .colorful:
            WiFiArcsView(bars: state.bars, ink: state.connected ? Color(hex: state.tint) : ink.opacity(0.7), slashed: slashed)
        case .dotName:
            Circle().fill(Color(hex: state.tint)).frame(width: 7, height: 7)
            Text(nameText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
        case .speed:
            speedStack
        case .wifiSpeed:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            speedStack
        case .wifiDbm:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            Text(state.connected && state.rssi != 0 ? "\(state.rssi)" : "—")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(ink)
        case .pill:
            pill
        case .ring:
            WiFiRingView(bars: state.bars, tint: Color(hex: state.tint), ink: ink, slashed: slashed)
        case .band:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            if state.connected, !state.band.isEmpty {
                Text(state.band)
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 3.5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(ink, lineWidth: 1))
            }
        case .ping:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            Text(pingText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(ink)
        case .lock:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            if state.connected, state.lock != 0 {
                WiFiLockView(open: state.lock == 2, ink: ink, height: 9)
            }
        case .activity:
            WiFiArcsView(bars: state.bars, ink: ink, slashed: slashed, height: 13)
            HStack(spacing: 1) {
                arrow(up: true, lit: state.connected && state.up == "1")
                arrow(up: false, lit: state.connected && state.down == "1")
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            WiFiBarsView(bars: state.bars, ink: inverse, slashed: slashed, height: 10)
            Text(nameText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(inverse)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 16)
        .background(Capsule(style: .continuous).fill(state.connected ? ink : ink.opacity(0.55)))
    }

    private var pingText: String {
        guard state.connected else { return "—" }
        guard let ms = state.pingMs else { return "··" }
        return "\(ms)ms"
    }

    private func arrow(up: Bool, lit: Bool) -> some View {
        WiFiTriangle(up: up)
            .fill(ink.opacity(lit ? 1 : 0.28))
            .frame(width: 6, height: 5.5)
    }

    private var nameText: String {
        if !state.powerOn { return "Wi-Fi off" }
        if !state.connected { return "Not connected" }
        let n = state.ssid.isEmpty ? "Wi-Fi" : state.ssid
        return n.count > 18 ? String(n.prefix(17)) + "…" : n
    }

    private var speedStack: some View {
        VStack(alignment: .trailing, spacing: -1) {
            Text("↑ \(state.connected ? state.up : "—")")
            Text("↓ \(state.connected ? state.down : "—")")
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(ink)
    }
}

// MARK: - Renderer

enum WiFiBarRenderer {
    @MainActor
    static func image(for state: WiFiBarState, dark: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: WiFiBarItemView(state: state, dark: dark))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = state.style.isTemplate
        return image
    }
}
