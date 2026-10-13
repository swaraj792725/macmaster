import SwiftUI

// MARK: - Palette

enum BatteryPalette {
    static let green = [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)]
    static let yellow = [Color(hex: 0xFDE047), Color(hex: 0xF59E0B)]
    static let red = [Color(hex: 0xFB7185), Color(hex: 0xDC2626)]

    enum Tone { case green, yellow, red }

    /// Charge tone: red at ≤ 20 %, yellow while Low Power Mode is on (macOS does the same), otherwise green/yellow by level.
    static func tone(_ p: Double, lowPower: Bool = false) -> Tone {
        if p < 0.2 { return .red }
        if lowPower || p < 0.5 { return .yellow }
        return .green
    }

    /// Gradient for a charge level 0…1 (green → yellow → red).
    static func gradient(_ p: Double, lowPower: Bool = false) -> [Color] {
        switch tone(p, lowPower: lowPower) {
        case .red: return red
        case .yellow: return yellow
        case .green: return green
        }
    }

    static func level(_ p: Double, lowPower: Bool = false) -> Color { gradient(p, lowPower: lowPower).last ?? .green }

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
    /// Low Power Mode on (turns the fill yellow, like macOS). Ignored while charging.
    var lowPower: Bool = false

    @Environment(\.colorScheme) private var scheme

    private var p: Double { min(max(percent, 0), 1) }
    private var pct: Int { Int((p * 100).rounded()) }
    private var tone: BatteryPalette.Tone { BatteryPalette.tone(p, lowPower: lowPower && !isCharging) }
    private var fillColors: [Color] { tint.map { [$0, $0] } ?? BatteryPalette.gradient(p, lowPower: lowPower && !isCharging) }
    /// Flat level color for glyphs made of many small parts.
    private var levelColor: Color { fillColors.last ?? .green }
    /// Text/mark color that stays readable on top of the colored fill (dark on yellow, white otherwise).
    private var onFill: Color { tint == nil && tone == .yellow ? Color(hex: 0x422006) : .white }
    private var fillGradient: LinearGradient {
        LinearGradient(colors: fillColors, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        switch style {
        case .classic: classic
        case .pill: pill
        case .ring: ring
        case .number: number
        case .vertical: vertical
        case .segments: segments
        case .orb: orb
        case .line: line
        case .liquid: liquid
        case .inside: inside
        case .dots: dots
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
                BatteryBoltShape().fill(levelColor).frame(width: height * 0.45, height: height * 0.8)
            }
            Text("\(Int((p * 100).rounded()))")
                .font(.system(size: height * 1.05, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor)
        }
        .fixedSize()
    }

    // MARK: More styles

    /// Upright battery (nub on top), fills from the bottom.
    private var vertical: some View {
        let w = height * 0.56
        let nubH = max(1.2, height * 0.1)
        let gap = height * 0.03
        let bodyH = height - nubH - gap
        let line = max(1, height * 0.08)
        let inset = line + height * 0.05
        let innerH = bodyH - inset * 2
        return VStack(spacing: gap) {
            RoundedRectangle(cornerRadius: nubH * 0.5, style: .continuous)
                .fill(Color.primary.opacity(0.55))
                .frame(width: w * 0.4, height: nubH)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: line)
                RoundedRectangle(cornerRadius: height * 0.1, style: .continuous)
                    .fill(fillGradient)
                    .frame(width: w - inset * 2, height: max(height * 0.1, innerH * p))
                    .padding(.bottom, inset)
                overlayMark
                    .frame(width: w * 0.62, height: bodyH * 0.6)
                    .frame(width: w, height: bodyH)
            }
            .frame(width: w, height: bodyH)
        }
        .fixedSize()
    }

    /// Classic outline split into five bars (each bar = 20 %).
    private var segments: some View {
        let nubW = max(1.2, height * 0.13)
        let bodyW = height * 2.0
        let line = max(1, height * 0.08)
        let inset = line + height * 0.07
        let gap = max(0.6, height * 0.07)
        let lit = Int((p * 5).rounded(.up))
        return HStack(spacing: height * 0.04) {
            ZStack {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: line)
                HStack(spacing: gap) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: height * 0.08, style: .continuous)
                            .fill(i < lit ? levelColor : Color.primary.opacity(0.16))
                    }
                }
                .padding(inset)
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

    /// Round disc that fills from the bottom; bolt / plug in the middle.
    private var orb: some View {
        let line = max(1, height * 0.08)
        return ZStack(alignment: .bottom) {
            Circle().fill(Color.primary.opacity(0.16))
            Rectangle().fill(fillGradient).frame(height: p > 0 ? max(1, height * p) : 0)
        }
        .frame(width: height, height: height)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.5), lineWidth: line))
        .overlay(overlayMark.frame(width: height * 0.4, height: height * 0.62))
        .fixedSize()
    }

    /// Percentage with a thin progress bar underneath.
    private var line: some View {
        let w = height * 2.0
        let bar = max(2, height * 0.14)
        return VStack(spacing: height * 0.08) {
            HStack(spacing: height * 0.04) {
                if isCharging {
                    BatteryBoltShape().fill(levelColor).frame(width: height * 0.34, height: height * 0.56)
                } else if isPluggedIn {
                    Image(systemName: "powerplug.fill").font(.system(size: height * 0.42, weight: .bold)).foregroundStyle(levelColor)
                }
                Text("\(pct)%")
                    .font(.system(size: height * 0.66, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
            .frame(width: w, height: height * 0.66)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule().fill(fillGradient).frame(width: p > 0 ? max(bar, w * p) : 0)
            }
            .frame(width: w, height: bar)
        }
        .fixedSize()
    }

    /// Big rounded "glass" with a liquid fill (wavy edge) and the percentage inside.
    private var liquid: some View {
        let w = height * 2.4
        let corner = height * 0.3
        let liquidShape = BatteryLiquidShape(progress: p, phase: 1.1, amplitude: height * 0.06)
        let line = max(1, height * 0.07)
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.primary.opacity(0.14))
            ZStack {
                liquidShape.fill(fillGradient)
                liquidShape.fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            dualText(width: w, onFill: onFill, content: { insideContent($0, suffix: "%") },
                     mask: liquidShape.frame(width: w, height: height))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: line)
        }
        .frame(width: w, height: height)
        .fixedSize()
    }

    /// iOS-style: grey track, solid fill (white/black, green charging, yellow low power, red low), number knocked out.
    private var inside: some View {
        let nubW = max(1.2, height * 0.13)
        let w = height * 2.0
        let corner = height * 0.3
        let inverse: Color = scheme == .dark ? .black : .white
        let red = tone == .red
        let yellow = lowPower && !isCharging && !red
        let fill: Color = tint ?? (isCharging ? Color(hex: 0x22C55E) : red ? Color(hex: 0xEF4444) : yellow ? Color(hex: 0xFACC15) : Color.primary)
        let knock: Color = tint != nil || isCharging || red ? .white : yellow ? Color(hex: 0x422006) : inverse
        let fw = max(height * 0.5, w * p)
        return HStack(spacing: height * 0.04) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.primary.opacity(0.3))
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill).frame(width: fw)
                dualText(width: w, onFill: knock, content: { insideContent($0, suffix: "") },
                         mask: Rectangle().frame(width: fw, height: height))
            }
            .frame(width: w, height: height)
            BatteryNubShape()
                .fill(Color.primary.opacity(0.4))
                .frame(width: nubW, height: height * 0.38)
        }
        .fixedSize()
    }

    /// 2 × 5 grid of dots (each = 10 %); bolt / plug sits to the left.
    private var dots: some View {
        let d = height * 0.38
        let gap = height * 0.1
        let lit = p * 10
        return HStack(spacing: height * 0.14) {
            if isCharging {
                BatteryBoltShape().fill(levelColor).frame(width: height * 0.42, height: height * 0.7)
            } else if isPluggedIn {
                Image(systemName: "powerplug.fill").font(.system(size: height * 0.5, weight: .bold)).foregroundStyle(levelColor)
            }
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<5, id: \.self) { col in
                            let on = min(1, max(0, lit - Double(row * 5 + col)))
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.2))
                                Circle().fill(levelColor).opacity(on)
                            }
                            .frame(width: d, height: d)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    /// Bolt / plug + number, in the given color (drawn twice by `dualText`).
    private func insideContent(_ color: Color, suffix: String) -> some View {
        HStack(spacing: height * 0.04) {
            if isCharging {
                BatteryBoltShape().fill(color).frame(width: height * 0.3, height: height * 0.5)
            } else if isPluggedIn {
                Image(systemName: "powerplug.fill").font(.system(size: height * 0.38, weight: .bold)).foregroundStyle(color)
            }
            Text("\(pct)\(suffix)")
                .font(.system(size: height * 0.64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    /// Text that is `primary` over the empty track and `onFill` over the filled part, so it reads on both.
    private func dualText<C: View, M: View>(width: CGFloat, onFill: Color,
                                            @ViewBuilder content: (Color) -> C, mask: M) -> some View {
        ZStack {
            content(Color.primary)
            content(onFill).mask(alignment: .leading) { mask }
        }
        .frame(width: width, height: height)
    }
}

enum BatteryGlyphStyle: String, CaseIterable, Identifiable {
    case classic, pill, ring, number
    case vertical, segments, orb, line, liquid, inside, dots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic outline"
        case .pill: "Filled pill"
        case .ring: "Ring"
        case .number: "Minimal number"
        case .vertical: "Vertical"
        case .segments: "Segments"
        case .orb: "Bolt orb"
        case .line: "Percent + bar"
        case .liquid: "Liquid"
        case .inside: "iOS style"
        case .dots: "Dots"
        }
    }

    /// The glyph already shows the percentage, so the menu bar skips the separate "72%" text.
    var includesPercent: Bool {
        switch self {
        case .number, .line, .liquid, .inside: true
        default: false
        }
    }

    /// Icon used next to the stacked "BAT / 72%" label (compact style): percentage-carrying glyphs fall back to a plain icon.
    var compactStyle: BatteryGlyphStyle {
        switch self {
        case .number, .inside: .classic
        case .line, .liquid: .pill
        default: self
        }
    }

    /// Glyph height used in the menu bar (pt). Styles that carry text need a bit more room.
    func menuBarHeight(compact: Bool) -> CGFloat {
        switch compact ? compactStyle : self {
        case .ring, .vertical, .orb: compact ? 12 : 14
        case .line, .liquid: 14
        case .inside: 13
        case .classic, .pill, .segments, .dots, .number: compact ? 9 : 11
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
