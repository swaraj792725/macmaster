import SwiftUI

// MARK: - Palette

enum BatteryPalette {
    static let green = [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)]
    static let yellow = [Color(hex: 0xFDE047), Color(hex: 0xF59E0B)]
    static let red = [Color(hex: 0xFB7185), Color(hex: 0xDC2626)]

    /// Gradient for a charge level 0…1 (green → yellow → red).
    static func gradient(_ p: Double) -> [Color] {
        if p < 0.2 { return red }
        if p < 0.5 { return yellow }
        return green
    }

    static func level(_ p: Double) -> Color { gradient(p).last ?? .green }

    /// Battery temperature color (°C).
    static func temperature(_ c: Double) -> Color {
        switch c {
        case ..<28: return Color(hex: 0x38BDF8)
        case ..<36: return Color(hex: 0x22C55E)
        case ..<40: return Color(hex: 0xEAB308)
        case ..<45: return Color(hex: 0xF97316)
        default: return Color(hex: 0xEF4444)
        }
    }
}

// MARK: - Shapes

/// Lightning bolt, normalized to its rect.
struct BatteryBoltShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        p.move(to: pt(0.60, 0))
        p.addLine(to: pt(0.16, 0.56))
        p.addLine(to: pt(0.47, 0.56))
        p.addLine(to: pt(0.38, 1))
        p.addLine(to: pt(0.84, 0.40))
        p.addLine(to: pt(0.53, 0.40))
        p.closeSubpath()
        return p
    }
}

/// Fill region that grows from the left with a wavy right edge ("liquid").
struct BatteryLiquidShape: Shape {
    var progress: Double
    var phase: Double
    var amplitude: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let p01 = min(max(progress, 0), 1)
        let edge = rect.width * p01
        let amp = amplitude * min(1, min(edge, rect.width - edge) / max(1, rect.width * 0.08))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        let steps = 28
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = rect.minX + edge + amp * CGFloat(sin(t * .pi * 3 + phase))
            p.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * CGFloat(t)))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct BatteryNubShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                               bottomTrailingRadius: rect.width * 0.9, topTrailingRadius: rect.width * 0.9,
                               style: .continuous).path(in: rect)
    }
}

// MARK: - Compact glyph (menu bar / list size)

/// Reusable small battery glyph. Works at menu-bar size (≈ 22×11) and scales up with `height`.
struct BatteryGlyph: View {
    var percent: Double
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var style: BatteryGlyphStyle = .classic
    var height: CGFloat = 11
    /// Override the fill color (e.g. monochrome).
    var tint: Color? = nil

    private var p: Double { min(max(percent, 0), 1) }
    private var fillColors: [Color] { tint.map { [$0, $0] } ?? BatteryPalette.gradient(p) }
    private var fillGradient: LinearGradient {
        LinearGradient(colors: fillColors, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        switch style {
        case .classic: classic
        case .pill: pill
        case .ring: ring
        case .number: number
        }
    }

    private var overlayMark: some View {
        Group {
            if isCharging {
                BatteryBoltShape()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.55), radius: height * 0.05)
            } else if isPluggedIn {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: height * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: height * 0.05)
            }
        }
    }

    private var classic: some View {
        let nubW = max(1.2, height * 0.13)
        let bodyW = height * 2.0
        let line = max(1, height * 0.08)
        let inset = line + height * 0.06
        let innerW = bodyW - inset * 2
        return HStack(spacing: height * 0.04) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: line)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(fillGradient)
                    .frame(width: max(height * 0.18, innerW * p), height: height - inset * 2)
                    .padding(.leading, inset)
                overlayMark
                    .frame(width: height * 0.55, height: height * 0.8)
                    .frame(width: bodyW)
            }
            .frame(width: bodyW, height: height)
            BatteryNubShape()
                .fill(Color.primary.opacity(0.55))
                .frame(width: nubW, height: height * 0.38)
        }
        .fixedSize()
    }

    private var pill: some View {
        let w = height * 2.0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.18))
            Capsule().fill(fillGradient).frame(width: max(height, w * p))
            overlayMark.frame(width: height * 0.55, height: height * 0.8).frame(width: w)
        }
        .frame(width: w, height: height)
        .clipShape(Capsule())
        .fixedSize()
    }

    private var ring: some View {
        let line = max(1.6, height * 0.16)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: max(0.02, p))
                .stroke(LinearGradient(colors: fillColors, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isCharging {
                BatteryBoltShape().fill(Color.primary).frame(width: height * 0.32, height: height * 0.46)
            } else if isPluggedIn {
                Image(systemName: "powerplug.fill").font(.system(size: height * 0.36)).foregroundStyle(Color.primary)
            }
        }
        .padding(line / 2)
        .frame(width: height, height: height)
        .fixedSize()
    }

    private var number: some View {
        HStack(spacing: 1) {
            if isCharging {
                BatteryBoltShape().fill(fillColors.last ?? .green).frame(width: height * 0.45, height: height * 0.8)
            }
            Text("\(Int((p * 100).rounded()))")
                .font(.system(size: height * 1.05, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? BatteryPalette.level(p))
        }
        .fixedSize()
    }
}

enum BatteryGlyphStyle: String, CaseIterable, Identifiable {
    case classic, pill, ring, number
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic outline"
        case .pill: "Filled pill"
        case .ring: "Ring"
        case .number: "Minimal number"
        }
    }
}

// MARK: - Hero illustration

/// Large liquid-fill battery illustration with animated wave while charging.
struct BatteryHeroGlyph: View {
    var percent: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var width: CGFloat = 300

    private var p: Double { min(max(percent, 0), 1) }

    var body: some View {
        let h = width * 0.5
        let nubW = width * 0.045
        let bodyW = width - nubW - 3
        let corner = h * 0.27
        let border = max(3, width * 0.018)
        let inset = border + width * 0.014
        let colors = BatteryPalette.gradient(p)

        HStack(spacing: 3) {
            ZStack {
                // glass body
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.3), lineWidth: border)

                // liquid
                TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: !isCharging)) { ctx in
                    let phase = ctx.date.timeIntervalSinceReferenceDate * 2.4
                    let liquid = BatteryLiquidShape(progress: p, phase: phase,
                                                    amplitude: isCharging ? h * 0.035 : h * 0.008)
                    ZStack {
                        liquid.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        liquid.fill(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                                   startPoint: .top, endPoint: .center))
                        if isCharging {
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            let x = (t.truncatingRemainder(dividingBy: 2.6) / 2.6) * 1.6 - 0.3
                            LinearGradient(stops: [.init(color: .clear, location: max(0, x - 0.15)),
                                                   .init(color: .white.opacity(0.35), location: min(1, max(0, x))),
                                                   .init(color: .clear, location: min(1, x + 0.15))],
                                           startPoint: .leading, endPoint: .trailing)
                                .mask(liquid)
                        }
                    }
                    .animation(.smooth(duration: 0.8), value: p)
                }
                .clipShape(RoundedRectangle(cornerRadius: corner - inset * 0.6, style: .continuous))
                .padding(inset)

                // content
                HStack(spacing: width * 0.02) {
                    if isCharging {
                        BatteryBoltShape().fill(.white)
                            .frame(width: h * 0.26, height: h * 0.4)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    } else if isPluggedIn {
                        Image(systemName: "powerplug.fill")
                            .font(.system(size: h * 0.26, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.system(size: h * 0.42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
                .animation(.smooth, value: Int(p * 100))
            }
            .frame(width: bodyW, height: h)

            BatteryNubShape()
                .fill(Color.primary.opacity(0.3))
                .frame(width: nubW, height: h * 0.34)
        }
        .frame(width: width, height: h)
        .shadow(color: (colors.last ?? .green).opacity(isCharging ? 0.35 : 0.15), radius: 22, y: 8)
    }
}
