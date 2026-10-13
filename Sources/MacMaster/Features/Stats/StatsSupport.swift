import SwiftUI
import AppKit
import Charts

// MARK: - Modules & settings keys

enum StatsModule: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, disk, sensors, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "Disk"
        case .sensors: "Sensors"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu.fill"
        case .memory: "memorychip.fill"
        case .gpu: "display"
        case .network: "arrow.up.arrow.down.circle.fill"
        case .disk: "internaldrive.fill"
        case .sensors: "thermometer.medium"
        case .battery: "battery.100.bolt"
        }
    }

    var color: Color {
        switch self {
        case .cpu: Theme.Palette.cpu
        case .memory: Theme.Palette.memory
        case .gpu: Theme.Palette.gpu
        case .network: Theme.Palette.network
        case .disk: Theme.Palette.disk
        case .sensors: Theme.Palette.thermal
        case .battery: Color(hex: 0x4ADE80)
        }
    }

    var colors: [Color] {
        switch self {
        case .cpu: [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)]
        case .memory: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)]
        case .gpu: [Color(hex: 0xF472B6), Color(hex: 0xDB2777)]
        case .network: [Color(hex: 0x34D399), Color(hex: 0x059669)]
        case .disk: [Color(hex: 0xFBBF24), Color(hex: 0xD97706)]
        case .sensors: [Color(hex: 0xFB923C), Color(hex: 0xEF4444)]
        case .battery: Theme.Palette.battery
        }
    }

    var defaultEnabled: Bool { self == .cpu || self == .memory || self == .network }
    var key: String { "mm.stats.menubar.\(rawValue)" }
    var styleKey: String { "mm.stats.menubar.\(rawValue).style" }
    /// Modules whose menu bar item supports graph / text / both.
    var hasBarStyle: Bool { self == .cpu || self == .memory || self == .gpu || self == .disk || self == .battery }

    var openSection: String { self == .battery ? "battery" : "stats" }
}

enum StatsBarStyle: String, CaseIterable, Identifiable {
    case graph, text, both, compact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graph: "Graph"
        case .text: "Text"
        case .both: "Graph + text"
        case .compact: "Compact"
        }
    }
    /// Compact (small icon + stacked label/value) only exists for battery.
    static func styles(for module: StatsModule) -> [StatsBarStyle] {
        module == .battery ? [.graph, .both, .compact, .text] : [.graph, .text, .both]
    }
    /// Battery's "graph" is its icon.
    func title(for module: StatsModule) -> String {
        guard module == .battery else { return title }
        switch self {
        case .graph: return "Icon"
        case .text: return "Text"
        case .both: return "Icon + text"
        case .compact: return "Compact text"
        }
    }
}

enum StatsSettings {
    static let intervalKey = "mm.stats.interval"
    static let batteryGlyphKey = "mm.stats.menubar.battery.glyph"
    static let batteryTimeKey = "mm.stats.menubar.battery.showTime"
    static let batteryPercentKey = "mm.stats.menubar.battery.showPercent"

    static func enabled(_ m: StatsModule) -> Bool {
        (UserDefaults.standard.object(forKey: m.key) as? Bool) ?? m.defaultEnabled
    }
    static func style(_ m: StatsModule) -> StatsBarStyle {
        if let s = UserDefaults.standard.string(forKey: m.styleKey).flatMap(StatsBarStyle.init(rawValue:)) { return s }
        // Battery used to have a "Show percentage" toggle; off meant icon only.
        if m == .battery, (UserDefaults.standard.object(forKey: batteryPercentKey) as? Bool) == false { return .graph }
        return .both
    }
    static func batteryGlyph() -> BatteryGlyphStyle {
        UserDefaults.standard.string(forKey: batteryGlyphKey).flatMap(BatteryGlyphStyle.init(rawValue:)) ?? .classic
    }
    static func batteryShowTime() -> Bool { UserDefaults.standard.bool(forKey: batteryTimeKey) }

    @MainActor static func applyStoredInterval() {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        if v > 0, SystemMonitor.shared.interval != v { SystemMonitor.shared.interval = v }
    }
}

// MARK: - Formatting

enum StatsFmt {
    /// Short rate for tight spaces: "0 B/s", "12.3 KB/s", "4.5 MB/s".
    static func compactRate(_ bps: Double) -> String {
        let v = max(0, bps)
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var x = v
        var i = 0
        while x >= 1000, i < units.count - 1 { x /= 1000; i += 1 }
        if i == 0 { return String(format: "%.0f %@", x, units[i]) }
        return String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    static func percent(_ f: Double) -> String { "\(Int((min(max(f, 0), 9.99) * 100).rounded()))%" }

    static func uptime(_ s: TimeInterval) -> String {
        let d = Int(s) / 86_400, h = (Int(s) % 86_400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func tempColor(_ c: Double) -> Color { Theme.levelColor(c / 100, warn: 0.6, critical: 0.8) }
}

// MARK: - Views

struct StatsAppIcon: View {
    let pid: pid_t
    var size: CGFloat = 20
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill").foregroundStyle(.tertiary)
                .font(.system(size: size * 0.7)).frame(width: size, height: size)
        }
    }
}

/// Dashboard card: gradient icon tile, big number, sparkline and persisted expandable details.
struct StatsCardShell<Accessory: View, Spark: View, Details: View>: View {
    let key: String
    let title: String
    let symbol: String
    let colors: [Color]
    let valueText: String
    var caption: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var spark: () -> Spark
    @ViewBuilder var details: () -> Details
    @AppStorage private var expanded: Bool

    init(key: String, title: String, symbol: String, colors: [Color], valueText: String, caption: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder spark: @escaping () -> Spark,
         @ViewBuilder details: @escaping () -> Details) {
        self.key = key; self.title = title; self.symbol = symbol; self.colors = colors
        self.valueText = valueText; self.caption = caption
        self.accessory = accessory; self.spark = spark; self.details = details
        _expanded = AppStorage(wrappedValue: false, "mm.stats.card.\(key).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, colors: colors, size: 34)
                Text(title).font(.headline)
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.3)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(expanded ? "Hide details" : "Show details")
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(valueText)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let caption {
                        Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            spark().frame(height: 56)
            if expanded {
                Divider()
                details().transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
    }
}

/// Stacked horizontal bar with legend.
struct StatsStackedBar: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }
    let segments: [Segment]

    var body: some View {
        let total = max(1, segments.map(\.value).reduce(0, +))
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments) { s in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(s.color.gradient)
                            .frame(width: max(0, (geo.size.width - CGFloat(segments.count - 1) * 2) * s.value / total))
                    }
                }
                .animation(.smooth, value: segments.map(\.value))
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(segments) { s in
                    HStack(spacing: 6) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.label).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(Fmt.bytes(UInt64(max(0, s.value)))).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// Dual-series (e.g. down / up) line chart over sample index.
struct StatsDualLineChart: View {
    let a: [Double]
    let b: [Double]
    var aName = "Down"
    var bName = "Up"
    var aColor: Color = Theme.Palette.network
    var bColor: Color = Theme.Palette.cpu

    private struct P: Identifiable { let id: Int; let x: Int; let y: Double; let s: String }

    var body: some View {
        let pts = a.enumerated().map { P(id: $0.offset, x: $0.offset, y: $0.element, s: aName) }
            + b.enumerated().map { P(id: 100_000 + $0.offset, x: $0.offset, y: $0.element, s: bName) }
        let top = max(1, (a + b).max() ?? 1)
        Chart(pts) { p in
            AreaMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", p.s), stacking: .unstacked)
                .foregroundStyle(by: .value("Series", p.s))
                .opacity(0.14)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.x), y: .value("v", p.y), series: .value("s", p.s))
                .foregroundStyle(by: .value("Series", p.s))
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([aName: aColor, bName: bColor])
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(top * 1.1))
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
    }
}

/// Process rows (icon, name, trailing value).
struct StatsProcessList: View {
    let processes: [ProcessSample]
    let value: (ProcessSample) -> String
    var limit = 5

    var body: some View {
        VStack(spacing: 6) {
            if processes.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Sampling processes…").foregroundStyle(.secondary) }
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(processes.prefix(limit)) { p in
                HStack(spacing: 8) {
                    StatsAppIcon(pid: p.pid, size: 18)
                    Text(p.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(value(p)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Two-tone capsule (e.g. user / system).
struct StatsSplitBar: View {
    let first: Double
    let second: Double
    var firstColor: Color = Theme.Palette.cpu
    var secondColor: Color = Theme.Palette.thermal
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 1) {
                    Capsule().fill(firstColor.gradient).frame(width: geo.size.width * min(1, max(0, first)))
                    Capsule().fill(secondColor.gradient).frame(width: geo.size.width * min(1, max(0, second)))
                }
                .animation(.smooth, value: first + second)
            }
        }
        .frame(height: 8)
    }
}

/// Larger history area chart for popovers / detail sections.
struct StatsAreaChart: View {
    let values: [Double]
    var color: Color
    var maxValue: Double? = 1
    var body: some View {
        Sparkline(values: values, color: color, maxValue: maxValue)
    }
}

extension StatsCardShell {
    /// Convenience for the standard modules.
    init(module: StatsModule, valueText: String, caption: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder spark: @escaping () -> Spark,
         @ViewBuilder details: @escaping () -> Details) {
        self.init(key: module.rawValue, title: module.title, symbol: module.symbol, colors: module.colors,
                  valueText: valueText, caption: caption, accessory: accessory, spark: spark, details: details)
    }
}

/// Small ring without text, for card accessories.
struct StatsMiniRing: View {
    let fraction: Double
    var color: Color
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 7)
            Circle().trim(from: 0, to: min(1, max(0.001, fraction)))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
        .frame(width: size, height: size)
    }
}
