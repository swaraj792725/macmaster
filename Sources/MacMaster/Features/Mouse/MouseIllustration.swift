import SwiftUI

func mouseButtonName(_ n: Int) -> String {
    switch n {
    case 0: return "Left button"
    case 1: return "Right button"
    case 2: return "Middle button"
    case 3: return "Button 4 (side, back)"
    case 4: return "Button 5 (side, forward)"
    default: return "Button \(n + 1)"
    }
}

/// A drawn mouse; tapping the wheel / side buttons selects that button for mapping.
struct MouseIllustration: View {
    @Binding var selected: Int
    let mappings: [Int: MouseButtonMapping]
    let gestureButton: Int?

    private let w: CGFloat = 150
    private let h: CGFloat = 230

    var body: some View {
        TimelineView(MouseActivitySchedule(fast: 1.0 / 20, idleAfter: 0.5)) { _ in
            let pressed = Self.pressedButtons()
            ZStack(alignment: .top) {
                // Body
                UnevenRoundedRectangle(topLeadingRadius: 74, bottomLeadingRadius: 62,
                                       bottomTrailingRadius: 62, topTrailingRadius: 74, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 74, bottomLeadingRadius: 62,
                                               bottomTrailingRadius: 62, topTrailingRadius: 74, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    )
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)

                // Left / right buttons (not remappable, drawn for orientation)
                HStack(spacing: 3) {
                    UnevenRoundedRectangle(topLeadingRadius: 74, bottomLeadingRadius: 6,
                                           bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
                        .fill(.white.opacity(pressed.contains(0) ? 0.35 : 0.07))
                    UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6,
                                           bottomTrailingRadius: 6, topTrailingRadius: 74, style: .continuous)
                        .fill(.white.opacity(pressed.contains(1) ? 0.35 : 0.07))
                }
                .frame(width: w - 14, height: 98)
                .padding(.top, 7)

                // Middle (wheel)
                part(button: 2, pressed: pressed) {
                    Capsule()
                }
                .frame(width: 20, height: 46)
                .padding(.top, 28)

                // Side buttons
                part(button: 3, pressed: pressed) { Capsule() }
                    .frame(width: 11, height: 34)
                    .offset(x: -w / 2 + 3, y: 118)
                part(button: 4, pressed: pressed) { Capsule() }
                    .frame(width: 11, height: 34)
                    .offset(x: -w / 2 + 3, y: 158)
            }
            .frame(width: w + 40, height: h + 10, alignment: .top)
        }
    }

    @ViewBuilder
    private func part<S: InsettableShape>(button: Int, pressed: Set<Int>, @ViewBuilder shape: () -> S) -> some View {
        let isSel = selected == button
        let isDown = pressed.contains(button)
        let mapped = mappings[button]?.isManaged == true || gestureButton == button
        let base: Color = isDown ? .white : (isSel ? Theme.Palette.mouse[0] : (mapped ? Theme.Palette.mouse[1] : .white.opacity(0.3)))
        shape()
            .fill(base.opacity(isSel || isDown || mapped ? 1 : 0.8))
            .overlay(shape().strokeBorder(.white.opacity(isSel ? 0.9 : 0.25), lineWidth: isSel ? 2 : 1))
            .shadow(color: isSel ? Theme.Palette.mouse[0].opacity(0.7) : .clear, radius: 8)
            .contentShape(shape())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = button } }
            .help(mouseButtonName(button))
    }

    private static func pressedButtons() -> Set<Int> {
        let snap = MouseTelemetry.shared.snapshot()
        var last: [Int: MouseTelemetryButtonEvent] = [:]
        for e in snap.buttons { last[e.button] = e }
        var set = Set<Int>()
        for (b, e) in last where e.down || snap.now - e.time < 0.2 { set.insert(b) }
        return set
    }
}
