import SwiftUI

// MARK: - Button styles

/// Prominent capsule button (filled with the tint).
struct MMPrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(
                Capsule().fill(LinearGradient(colors: [tint.lighter(0.12), tint], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary bordered capsule button.
struct MMSecondaryButtonStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// Borderless low-emphasis button with a hover wash.
struct MMGhostButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.18 : (hover ? 0.10 : 0))))
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.15), value: hover)
    }
}

extension ButtonStyle where Self == MMPrimaryButtonStyle {
    static var mmPrimary: MMPrimaryButtonStyle { MMPrimaryButtonStyle() }
    static func mmPrimary(tint: Color) -> MMPrimaryButtonStyle { MMPrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == MMSecondaryButtonStyle {
    static var mmSecondary: MMSecondaryButtonStyle { MMSecondaryButtonStyle() }
    static func mmSecondary(tint: Color) -> MMSecondaryButtonStyle { MMSecondaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == MMGhostButtonStyle {
    static var mmGhost: MMGhostButtonStyle { MMGhostButtonStyle() }
}

/// Plain button that gives its (card) label a hover lift + press feedback.
struct MMCardButtonStyle: ButtonStyle {
    var scale: CGFloat = 1.012

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverLift(scale: scale, pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == MMCardButtonStyle {
    static var mmCard: MMCardButtonStyle { MMCardButtonStyle() }
}

// MARK: - Hover

/// Subtle scale + brightness on hover. Cheap: no shadows, no blur.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.015
    var pressed: Bool = false
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.985 : (hover ? scale : 1))
            .brightness(hover ? 0.025 : 0)
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.18), value: hover)
            .animation(.smooth(duration: 0.12), value: pressed)
    }
}

extension View {
    /// Subtle hover lift for interactive cards.
    func hoverLift(scale: CGFloat = 1.015) -> some View { modifier(HoverLift(scale: scale)) }
}

// MARK: - Availability-guarded effects

extension View {
    /// Bounce a symbol when `value` changes (macOS 14+, guarded for older SDK behavior).
    @ViewBuilder
    func mmSymbolBounce<V: Equatable>(value: V) -> some View {
        if #available(macOS 14.0, *) { self.symbolEffect(.bounce, value: value) } else { self }
    }

    /// Numeric roll for changing numbers.
    func mmNumeric() -> some View { self.contentTransition(.numericText()).monospacedDigit() }
}

/// Settings-row switch: label on the left, switch pinned to the trailing edge (like System Settings).
struct MMSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
        }
        .frame(maxWidth: 560)
    }
}

extension ToggleStyle where Self == MMSwitchToggleStyle {
    static var mmSwitch: MMSwitchToggleStyle { MMSwitchToggleStyle() }
}

extension Binding where Value == Double {
    /// Rounds writes to `step`. Use instead of `Slider(step:)`, which draws a tick mark for every step on macOS.
    func snapped(_ step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ($0 / step).rounded() * step })
    }
}
