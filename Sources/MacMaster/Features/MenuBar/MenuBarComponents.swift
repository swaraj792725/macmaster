import SwiftUI
import AppKit

// MARK: - Glass

struct MenuBarGlass: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }
}

extension View {
    func menuBarGlass(radius: CGFloat = 16) -> some View { modifier(MenuBarGlass(radius: radius)) }
}

struct MenuBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Icon button (header)

struct MenuBarIconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? Color.primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.14 : 0.07)))
        }
        .buttonStyle(MenuBarPressStyle())
        .help(help)
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Logo tile

struct MenuBarLogoTile: View {
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient(Theme.Palette.dashboard))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(
                Image(nsImage: MenuBarIconRenderer.logoImage(size: 64))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.14)
            )
            .frame(width: size, height: size)
            .shadow(color: (Theme.Palette.dashboard.last ?? .black).opacity(0.35), radius: 4, y: 2)
    }
}

// MARK: - Mini gauge

struct MenuBarMiniGauge: View {
    let label: String
    let fraction: Double
    let colors: [Color]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let f = min(max(fraction, 0), 1)
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: max(0.01, f))
                        .stroke(Theme.gradient(colors), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: f)
                    Text("\(Int((f * 100).rounded()))")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 40, height: 40)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        }
        .buttonStyle(MenuBarPressStyle())
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
        .help("Open \(label) details")
    }
}

// MARK: - Toggle tile

struct MenuBarToggleTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let tint: Color
    var busy = false
    var compact = false
    let action: () -> Void
    @State private var hover = false

    private var iconCircle: some View {
        let size: CGFloat = compact ? 34 : 32
        return ZStack {
            Circle().fill(isOn ? tint : Color.primary.opacity(0.13))
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.2), value: isOn)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    VStack(spacing: 5) {
                        iconCircle
                        Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                } else {
                    HStack(spacing: 9) {
                        iconCircle
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 50)
                }
            }
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .menuBarGlass(radius: 14)
        }
        .buttonStyle(MenuBarPressStyle())
        .disabled(busy)
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Capsule slider

struct MenuBarSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let onChange: (Double) -> Void
    var height: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let fillW = max(height, w * CGFloat(min(max(value, 0), 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(Color.white)
                        .frame(width: fillW)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .frame(width: height)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let v = Double(min(max(g.location.x / max(w, 1), 0), 1))
                        value = v
                        onChange(v)
                    }
                )
            }
            .frame(height: height)
        }
    }
}

// MARK: - Quick action button

struct MenuBarActionButton: View {
    let action: MenuBarQuickAction
    var busy = false
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Theme.gradient(action.colors))
                    if busy {
                        ProgressView().controlSize(.small).scaleEffect(0.6).colorScheme(.dark)
                    } else {
                        Image(systemName: action.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34)
                .shadow(color: (action.colors.last ?? .black).opacity(hover ? 0.45 : 0.25), radius: hover ? 6 : 3, y: 2)
                Text(action.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(MenuBarPressStyle())
        .disabled(busy)
        .help(action.help)
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Process row

struct MenuBarProcessRow: View {
    let sample: ProcessSample
    let canQuit: Bool
    let quit: () -> Void
    @State private var hover = false

    private var icon: NSImage? {
        if let app = NSRunningApplication(processIdentifier: sample.pid), let i = app.icon { return i }
        return nil
    }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(4).foregroundStyle(.secondary) }
            }
            .frame(width: 22, height: 22)
            Text(sample.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            Text(Fmt.bytes(sample.memory)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            Text(String(format: "%.0f%%", sample.cpu * 100))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(Theme.levelColor(sample.cpu, warn: 0.5, critical: 1.0))
            Button(action: quit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .opacity(canQuit ? (hover ? 1 : 0.55) : 0)
            }
            .buttonStyle(.plain)
            .disabled(!canQuit)
            .help("Quit \(sample.name)")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Section header

struct MenuBarSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.leading, 4)
    }
}
