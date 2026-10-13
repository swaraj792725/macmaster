import SwiftUI
import Charts

private let batteryStateScale: KeyValuePairs<String, Color> = [
    "Charging": Color(hex: 0x22C55E),
    "On battery": Color(hex: 0xF59E0B),
]

/// Hour labels for a day of data, weekday labels for longer spans; short enough not to truncate at the edge.
@AxisContentBuilder
private func batteryTimeAxis(_ points: [BatterySeriesPoint]) -> some AxisContent {
    let span = (points.last?.date ?? .now).timeIntervalSince(points.first?.date ?? .now)
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel(format: span > 36 * 3600 ? .dateTime.weekday(.abbreviated) : .dateTime.hour(),
                       collisionResolution: .greedy(minimumSpacing: 6)).font(.caption2)
    }
}

/// Segmented (charging vs on-battery) line chart.
struct BatterySegmentedChart: View {
    let points: [BatterySeriesPoint]
    var yDomain: ClosedRange<Double>? = nil
    var unit: String
    var showsZeroLine = false

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Value", p.value),
                         series: .value("Segment", p.segment), stacking: .unstacked)
                    .foregroundStyle(by: .value("State", p.stateLabel))
                    .opacity(0.18)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Value", p.value),
                         series: .value("Segment", p.segment))
                    .foregroundStyle(by: .value("State", p.stateLabel))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if showsZeroLine { RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4)) }
        }
        .chartForegroundStyleScale(batteryStateScale)
        .chartYScale(domain: yDomain ?? autoDomain)
        .chartPlotStyle { $0.clipped() } // monotone curves can overshoot the domain
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))\(unit)").font(.caption2) }
                }
            }
        }
        .chartXAxis { batteryTimeAxis(points) }
        .chartXScale(range: .plotDimension(endPadding: 14))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
    }

    private var autoDomain: ClosedRange<Double> {
        let vals = points.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max(1, (hi - lo) * 0.15)
        return (min(lo, 0) - (showsZeroLine ? pad : 0))...(max(hi, 0) + pad)
    }
}

/// Single-series temperature chart with a heat gradient.
struct BatteryTemperatureChart: View {
    let points: [BatterySeriesPoint]

    var body: some View {
        let vals = points.map(\.value)
        let lo = floor((vals.min() ?? 20) - 2), hi = ceil((vals.max() ?? 40) + 2)
        Chart {
            ForEach(points) { p in
                // Area starts at the axis floor, not 0 °C, so it stays inside the plot.
                AreaMark(x: .value("Time", p.date), yStart: .value("Floor", lo), yEnd: .value("°C", p.value),
                         series: .value("S", p.segment))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFB923C).opacity(0.35), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("°C", p.value), series: .value("S", p.segment))
                    .foregroundStyle(Color(hex: 0xFB923C))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 5))
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))°").font(.caption2) }
                }
            }
        }
        .chartXAxis { batteryTimeAxis(points) }
        .chartXScale(range: .plotDimension(endPadding: 14))
    }
}

/// Card with range picker and three charts built from `BatteryMonitor.history`.
struct BatteryChartsSection: View {
    @State private var range: BatteryRange = .day
    @State private var level: [BatterySeriesPoint] = []
    @State private var power: [BatterySeriesPoint] = []
    @State private var temp: [BatterySeriesPoint] = []

    private var monitor: BatteryMonitor { .shared }

    var body: some View {
        let history = monitor.history
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack {
                SectionTitle(text: "History", symbol: "chart.xyaxis.line")
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(BatteryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.spacing)], spacing: Theme.spacing) {
                chartCard(title: "Charge level", symbol: "battery.75percent", colors: Theme.Palette.battery, empty: level.isEmpty) {
                    BatterySegmentedChart(points: level, yDomain: 0...100, unit: "%")
                }
                chartCard(title: "Power flow", symbol: "bolt.fill", colors: Theme.Palette.tools, empty: power.isEmpty) {
                    BatterySegmentedChart(points: power, unit: "W", showsZeroLine: true)
                }
                chartCard(title: "Temperature", symbol: "thermometer.medium", colors: [Color(hex: 0xFB923C), Color(hex: 0xEF4444)], empty: temp.isEmpty) {
                    BatteryTemperatureChart(points: temp)
                }
            }
        }
        .task(id: "\(range.rawValue)-\(history.count)-\(history.last?.date.timeIntervalSince1970 ?? 0)") {
            level = BatteryChartPrep.prepare(history, range: range) { $0.percent * 100 }
            power = BatteryChartPrep.prepare(history, range: range) { $0.watts }
            temp = BatteryChartPrep.prepare(history, range: range) { $0.temperature }
        }
    }

    private func chartCard<C: View>(title: String, symbol: String, colors: [Color], empty: Bool,
                                    @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, colors: colors, size: 24)
                Text(title).font(.headline)
            }
            if empty {
                Text("Collecting data — history is recorded once a minute while MacMaster runs.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                chart().frame(height: 170)
            }
        }
        .card()
    }
}
