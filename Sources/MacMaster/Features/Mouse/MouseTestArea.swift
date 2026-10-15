import SwiftUI

/// Scroll test surface + live raw-vs-smoothed chart + detected buttons.
struct MouseTestArea: View {
    @ObservedObject var engine: MouseEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Test area", symbol: "scope")
            Text("Scroll the list with your mouse wheel and press any mouse button. The chart compares what the wheel sent (bars) with the smoothed scrolling we produce (curve).")
                .font(.callout).foregroundStyle(.secondary)
            if engine.status != .running {
                Label("Engine isn’t running — turn it on and grant Accessibility to see live data.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                scrollSurface
                VStack(alignment: .leading, spacing: 10) {
                    MouseScrollChart().frame(height: 120)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    chartLegend
                    MouseButtonReadout()
                }
            }
        }
        .card()
    }

    private var scrollSurface: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(0..<60, id: \.self) { i in
                    HStack {
                        Text("Row \(i + 1)").font(.system(.callout, design: .rounded).weight(.medium))
                        Spacer()
                        Circle().fill(Theme.gradient(Theme.Palette.mouse)).frame(width: 8, height: 8)
                            .opacity(0.4 + 0.6 * Double(i % 5) / 4)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.white.opacity(i % 2 == 0 ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(8)
        }
        .frame(width: 240, height: 250)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            Label("Raw wheel ticks", systemImage: "chart.bar.fill").foregroundStyle(Color(hex: 0xFBBF24))
            Label("Smoothed speed", systemImage: "waveform.path").foregroundStyle(Theme.Palette.mouse[0])
        }
        .font(.caption)
    }
}

struct MouseScrollChart: View {
    private let window = 4.0

    var body: some View {
        TimelineView(MouseActivitySchedule(fast: 1.0 / 30)) { _ in
            let snap = MouseTelemetry.shared.snapshot()
            Canvas { ctx, size in
                let now = snap.now
                let win = window
                func x(_ t: Double) -> CGFloat { CGFloat(1 - (now - t) / win) * size.width }

                let raw = snap.raw.filter { now - $0.time < win }
                let sm = snap.smoothed.filter { now - $0.time < win }
                let maxRaw = max(raw.map(\.value).max() ?? 0, 60)
                let maxSm = max(sm.map(\.value).max() ?? 0, 300)

                for s in raw {
                    let hgt = CGFloat(min(1, s.value / maxRaw)) * size.height * 0.85
                    var p = Path()
                    p.move(to: CGPoint(x: x(s.time), y: size.height))
                    p.addLine(to: CGPoint(x: x(s.time), y: size.height - hgt))
                    ctx.stroke(p, with: .color(Color(hex: 0xFBBF24).opacity(0.9)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                if let last = sm.last, sm.count > 1 {
                    var line = Path()
                    var area = Path()
                    for (i, s) in sm.enumerated() {
                        let pt = CGPoint(x: x(s.time), y: size.height - CGFloat(min(1, s.value / maxSm)) * size.height * 0.85)
                        if i == 0 {
                            line.move(to: pt)
                            area.move(to: CGPoint(x: pt.x, y: size.height))
                            area.addLine(to: pt)
                        } else {
                            line.addLine(to: pt)
                            area.addLine(to: pt)
                        }
                    }
                    area.addLine(to: CGPoint(x: x(last.time), y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [Theme.Palette.mouse[0].opacity(0.45), Theme.Palette.mouse[0].opacity(0.02)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    ctx.stroke(line, with: .color(Theme.Palette.mouse[0]), lineWidth: 2)
                }
            }
        }
    }
}

struct MouseButtonReadout: View {
    var body: some View {
        TimelineView(MouseActivitySchedule(fast: 0.25, idleAfter: 6)) { _ in
            let snap = MouseTelemetry.shared.snapshot()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                    Text("Last scroll device:").foregroundStyle(.secondary)
                    Text(snap.now - snap.lastScrollTime < 5 ? snap.lastScrollDevice : "—").fontWeight(.medium)
                }
                .font(.callout)
                let recent = Array(snap.buttons.filter { $0.down }.suffix(4).reversed())
                if recent.isEmpty {
                    Text("Press a mouse button to see its number here.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(recent) { e in
                            Text("#\(e.button) · \(mouseButtonName(e.button).components(separatedBy: " (").first ?? "")")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.Palette.mouse[1].opacity(0.25), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}
