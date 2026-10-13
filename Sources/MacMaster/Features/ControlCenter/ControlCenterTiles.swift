import SwiftUI

/// Shared surface for every tile: accent gradient when on, quiet fill when off.
struct ControlCenterSurface: ViewModifier {
    var on = false
    var colors: [Color] = []
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if on {
                        shape.fill(Theme.verticalGradient(colors))
                        shape.fill(LinearGradient(colors: [.white.opacity(0.24), .clear],
                                                  startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
                    } else {
                        shape.fill(Color.primary.opacity(0.065))
                        shape.fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                                  startPoint: .top, endPoint: .center))
                    }
                }
            }
            .overlay(shape.strokeBorder(on ? Color.white.opacity(0.28) : Theme.hairline, lineWidth: 0.5))
            .shadow(color: on ? (colors.last ?? .clear).opacity(0.32) : .clear, radius: 7, y: 3)
            .contentShape(shape)
    }
}

extension View {
    func ccSurface(on: Bool = false, colors: [Color] = [], radius: CGFloat = 18) -> some View {
        modifier(ControlCenterSurface(on: on, colors: colors, radius: radius))
    }
}

/// A toggle or action tile in small, wide or large form. Fills whatever frame it is given.
struct ControlCenterTileView: View {
    let tile: ControlCenterTile
    var size: ControlCenterTileSize = .small
    let isOn: Bool
    let subtitle: String
    var title: String?
    var symbol: String?
    var colors: [Color]?
    var variable: Double?
    let action: () -> Void

    private var fg: Color { isOn ? .white : Color.primary }
    private var fg2: Color { isOn ? .white.opacity(0.85) : Color.secondary }
    private var name: String { title ?? tile.title }

    var body: some View {
        Button(action: action) {
            Group {
                switch size {
                case .wide: wide
                case .large, .panel: large
                default: small
                }
            }
            .ccSurface(on: isOn, colors: colors ?? tile.colors)
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isOn)
        .accessibilityLabel("\(name), \(subtitle)")
    }

    private func glyph(_ d: CGFloat, _ font: CGFloat) -> some View {
        ZStack {
            Circle().fill(isOn ? Color.white.opacity(0.25) : Color.primary.opacity(0.09))
            Image(systemName: symbol ?? tile.symbol, variableValue: variable)
                .font(.system(size: font, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: d, height: d)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            glyph(28, 13)
            Spacer(minLength: 4)
            Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(fg)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(fg2)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wide: some View {
        HStack(spacing: 10) {
            glyph(36, 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(fg).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(fg2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            glyph(46, 21)
            Spacer(minLength: 6)
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(fg).lineLimit(1)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(fg2).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Keep Awake in its large form: timer presets right on the tile.
struct ControlCenterKeepAwakeLarge: View {
    private let awake = ToolsKeepAwake.shared

    private let presets: [(ToolsAwakeDuration, String)] = [(.m15, "15m"), (.h1, "1h"), (.h2, "2h"), (.indefinite, "Until off")]

    private var on: Bool { awake.isActive || awake.isArmed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(on ? Color.white.opacity(0.25) : Color.primary.opacity(0.09))
                    Image(systemName: ControlCenterTile.keepAwake.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keep Awake").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(on ? (awake.remaining.map { Fmt.duration($0) } ?? "On") : "Off")
                        .font(.system(size: 10)).opacity(0.85).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                ForEach(presets, id: \.0) { (d, label) in
                    let active = on && awake.currentDuration == d
                    Button {
                        if active { awake.stop() } else { awake.begin(d) }
                    } label: {
                        Text(label).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(active ? ControlCenterTile.keepAwake.colors.last ?? .orange : (on ? Color.white : Color.primary))
                            .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle((on ? Color.white : Color.primary).opacity(0.14)),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if on {
                Button { awake.stop() } label: {
                    Text("Turn off").font(.system(size: 10.5, weight: .medium)).frame(maxWidth: .infinity)
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ccSurface(on: on, colors: ControlCenterTile.keepAwake.colors)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: on)
    }
}

/// Capsule slider with an icon inside, like Control Center's brightness / sound sliders.
struct ControlCenterSlider: View {
    @Binding var value: Double   // 0...1
    let symbol: String
    let colors: [Color]
    var dimmed = false
    /// Fills the symbol progressively (speaker waves) instead of swapping glyphs.
    var variable = false
    var label: String?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(0.08))
                shape.fill(Theme.verticalGradient(colors))
                    .frame(width: max(0, w * value))
                    .opacity(dimmed ? 0.4 : 1)
                    .mask(alignment: .leading) { shape }
                HStack(spacing: 6) {
                    Image(systemName: symbol, variableValue: variable ? value : nil)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(value > 0.12 && !dimmed ? Color.white : Color.secondary)
                        .frame(width: 18)
                    if let label {
                        Text(label).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(value > 0.35 && !dimmed ? Color.white.opacity(0.92) : Color.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(value > 0.88 && !dimmed ? Color.white.opacity(0.9) : Color.secondary)
                }
                .padding(.horizontal, 11)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = max(0, min(1, g.location.x / max(1, w)))
            })
        }
        .frame(height: ControlCenterMetrics.halfRow)
    }
}
