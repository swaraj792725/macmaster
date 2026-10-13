import SwiftUI

/// Animated scan orb: pulsing rings + rotating arc. Doubles as the primary "Scan" button.
struct CleanerOrb: View {
    var scanning: Bool
    var progress: Double = 0
    var title: String
    var subtitle: String?
    var size: CGFloat = 190
    var action: () -> Void = {}

    private let colors = Theme.Palette.cleaner

    var body: some View {
        Button(action: action) {
            // Idle orb is static; it only animates (capped at 30 fps) while a scan runs.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !scanning)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let speed = scanning ? 1.0 : 0.35
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = (t * 0.45 * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(colors[0].opacity((1 - phase) * 0.35), lineWidth: 2)
                            .scaleEffect(0.86 + phase * 0.5)
                    }
                    Circle()
                        .fill(RadialGradient(colors: [colors[0].opacity(0.95), colors[1]],
                                             center: .topLeading, startRadius: 4, endRadius: size * 0.8))
                        .frame(width: size * 0.78, height: size * 0.78)
                        .shadow(color: colors[1].opacity(0.55), radius: 24, y: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .scaleEffect(1 + 0.015 * sin(t * (scanning ? 4 : 1.6)))
                    Circle()
                        .trim(from: 0, to: scanning ? max(0.08, min(progress, 1)) : 0.22)
                        .stroke(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.95)], center: .center),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: size * 0.9, height: size * 0.9)
                        .rotationEffect(.degrees(scanning ? t * 220 : t * 40))
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: size * 0.17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .disabled(scanning)
        .accessibilityLabel(scanning ? "Scanning" : "Start scan")
    }
}

struct CleanerCheckbox: View {
    var state: CleanerCheckState
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : (state == .mixed ? "minus.square.fill" : "square"))
                .font(.system(size: 18))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Palette.cleaner[1]))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Counts up to `value` when it changes inside an animation.
struct CleanerCountUp: View, Animatable {
    var value: Double
    var size: CGFloat = 48
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(Fmt.bytes(Int64(max(0, value))))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
    }
}

/// Wrapping legend/pill flow.
struct CleanerFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal.width ?? 600, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = layout(bounds.width, subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var frames: [CGRect] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowH), frames)
    }
}
