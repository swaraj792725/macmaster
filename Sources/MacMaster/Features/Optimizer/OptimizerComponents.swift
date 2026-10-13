import SwiftUI

// MARK: - Score ring

struct OptimizerScoreRing: View {
    let score: Int
    let hasScore: Bool
    var busy = false
    var size: CGFloat = 200
    var caption: String? = nil

    var body: some View {
        let lw = size * 0.075
        let colors = OptimizerGrade.colors(score)
        let fraction = hasScore ? max(0.015, Double(score) / 100) : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lw)
            if busy {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                    let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(colors: [colors[0].opacity(0.05), colors[0], colors[1]],
                                                center: .center, startAngle: .degrees(0), endAngle: .degrees(100)),
                                style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                }
            } else {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0),
                                            endAngle: .degrees(360 * max(fraction, 0.05))),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: (colors.last ?? .clear).opacity(0.35), radius: lw * 0.8)
                    .animation(.smooth(duration: 0.9), value: score)
            }
            VStack(spacing: 2) {
                if busy {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: size * 0.26, weight: .semibold))
                        .foregroundStyle(Theme.gradient(colors))
                        .symbolEffect(.pulse)
                } else {
                    Text(hasScore ? "\(score)" : "–")
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(score)))
                        .animation(.smooth(duration: 0.9), value: score)
                    Text(caption ?? (hasScore ? OptimizerGrade.label(score) : "Not checked"))
                        .font(.system(size: max(11, size * 0.075), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(lw / 2)
    }
}

// MARK: - Small pieces

struct OptimizerBadge: View {
    let text: String
    var symbol: String? = nil
    var color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct OptimizerStatusIcon: View {
    let status: OptimizerTaskStatus

    var body: some View {
        Group {
            switch status {
            case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x22C55E))
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(hex: 0xEF4444))
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 18))
        .frame(width: 22, height: 22)
        .contentTransition(.symbolEffect(.replace))
    }
}

struct OptimizerTaskRow: View {
    let report: OptimizerTaskReport

    var body: some View {
        HStack(spacing: 12) {
            OptimizerStatusIcon(status: report.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.title).font(.callout.weight(.medium))
                if !report.message.isEmpty {
                    Text(report.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if report.requiresAdmin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Live graphs

struct OptimizerLiveGraphs: View {
    private let monitor = SystemMonitor.shared

    var body: some View {
        let points = Array(monitor.history.suffix(60))
        HStack(spacing: Theme.spacing) {
            graph(title: "Memory", symbol: "memorychip", color: Theme.Palette.memory,
                  value: Fmt.percent(monitor.memory.usedFraction), caption: "\(Fmt.memory(monitor.memory.used)) of \(Fmt.memory(monitor.memory.total))",
                  values: points.map(\.memory))
            graph(title: "CPU", symbol: "cpu", color: Theme.Palette.cpu,
                  value: Fmt.percent(monitor.cpu.total), caption: "\(SystemInfo.current.logicalCores) cores",
                  values: points.map(\.cpu))
        }
    }

    private func graph(title: String, symbol: String, color: Color, value: String, caption: String, values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, colors: [color.opacity(0.8), color], size: 24)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Sparkline(values: values, color: color, maxValue: 1)
                .frame(height: 54)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Compare tile (before / after)

struct OptimizerCompareTile: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let before: String
    let after: String
    var delta: String? = nil
    var improved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, colors: colors, size: 24)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(before).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                Text(after).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            }
            if let delta {
                OptimizerBadge(text: delta, symbol: improved ? "arrow.down.right" : nil,
                               color: improved ? Color(hex: 0x22C55E) : .secondary)
            }
        }
        .card()
    }
}

// MARK: - Section card helper

struct OptimizerSectionCard<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: title, symbol: symbol)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .card()
    }
}
