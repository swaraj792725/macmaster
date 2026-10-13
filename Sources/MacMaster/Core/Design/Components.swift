import SwiftUI
import Charts

// MARK: - Card

enum CardKind {
    /// Inset grouped surface (System Settings style). Default.
    case grouped
    /// Liquid Glass on macOS 26+, material elsewhere. Use for hero surfaces.
    case glass
}

/// Card container. Grouped surface by default; optional Liquid Glass.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.spacing
    var kind: CardKind = .grouped
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let padded = content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        switch kind {
        case .grouped:
            padded
                .background(Theme.cardFill, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        case .glass:
            if #available(macOS 26.0, *), Theme.glassEnabled {
                padded.glassEffect(.regular, in: shape)
            } else {
                padded
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }
}

extension View {
    func card(padding: CGFloat = Theme.spacing) -> some View { modifier(CardModifier(padding: padding)) }

    func card(padding: CGFloat = Theme.spacing, kind: CardKind, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardModifier(padding: padding, kind: kind, radius: radius))
    }
}

// MARK: - Page scaffolding

/// Standard page header: large title, secondary subtitle, icon tile and trailing accessory.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, subtitle: String, symbol: String, colors: [Color],
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.colors = colors; self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, colors: colors, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.bottom, 4)
    }
}

/// Scrollable page with standard padding. Use for every feature screen.
struct Page<Content: View>: View {
    var spacing: CGFloat = Theme.spacing
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = Theme.spacing, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content() }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

struct SectionTitle: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: SymbolKit.resolve(symbol))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text).font(.system(size: 15, weight: .semibold))
        }
        .padding(.top, 4)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var symbol: String
    var colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, colors: colors, size: 24)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .card()
    }
}

/// Key/value row for detail lists.
struct InfoRow: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: SymbolKit.resolve(symbol)).frame(width: 18).foregroundStyle(.secondary)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

// MARK: - Gauges

/// Circular ring gauge with a centered value.
struct RingGauge: View {
    let fraction: Double
    var lineWidth: CGFloat = 10
    var colors: [Color]? = nil
    var label: String? = nil
    var valueText: String? = nil

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        let base = Theme.levelColor(clamped)
        let stroke: [Color] = (colors?.isEmpty == false) ? (colors ?? []) : [base.lighter(0.15), base]
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0005, clamped))
                .stroke(AngularGradient(colors: stroke,
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(max(40, 360 * clamped))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: clamped)
            VStack(spacing: 0) {
                Text(valueText ?? Fmt.percent(clamped))
                    .font(.system(size: max(12, lineWidth * 1.7), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6).lineLimit(1)
                if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(lineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Gauge")
        .accessibilityValue(valueText ?? Fmt.percent(clamped))
    }
}

/// Horizontal capsule bar.
struct CapsuleBar: View {
    let fraction: Double
    var color: Color? = nil
    var height: CGFloat = 8
    var body: some View {
        let f = min(max(fraction, 0), 1)
        let c = color ?? Theme.levelColor(f)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [c.lighter(0.12), c], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(height, geo.size.width * f))
                    .animation(.smooth, value: f)
            }
        }
        .frame(height: height)
    }
}

/// Tiny area chart for a history series (values 0…1 unless `maxValue` given).
struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var maxValue: Double? = nil
    var minValue: Double = 0

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("t", item.offset), yStart: .value("floor", minValue), yEnd: .value("v", item.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.0)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", item.offset), y: .value("v", item.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: minValue...max(minValue + 1, maxValue ?? (values.max() ?? 1) * 1.15))
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
    }
}

// MARK: - Permission banner

/// Inline banner that explains a missing permission and links to System Settings.
struct PermissionBanner: View {
    let permission: Permission
    var reason: String
    @State private var granted = false

    var body: some View {
        Group {
            if !granted {
                HStack(spacing: 12) {
                    IconTile(symbol: "lock.shield.fill", colors: Theme.Palette.orange, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(permission.title) needed").font(.headline)
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Recheck") { granted = Permissions.isGranted(permission) }
                        .buttonStyle(.mmSecondary)
                    Button("Grant Access") { Permissions.request(permission) }
                        .buttonStyle(.mmPrimary)
                }
                .padding(Theme.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xFF9F0A).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color(hex: 0xFF9F0A).opacity(0.28), lineWidth: 0.5))
            }
        }
        .onAppear { granted = Permissions.isGranted(permission) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            granted = Permissions.isGranted(permission)
        }
    }
}

/// Small colored status dot + text.
struct StatusPill: View {
    let text: String
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.18), lineWidth: 0.5))
    }
}

/// Empty / idle state placeholder.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: SymbolKit.resolve(symbol))
                .font(.system(size: 38, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
