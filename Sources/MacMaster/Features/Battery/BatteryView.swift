import SwiftUI
import AppKit

struct BatteryView: View {
    private var monitor: BatteryMonitor { .shared }
    private let columns = [GridItem(.adaptive(minimum: 320), spacing: Theme.spacing, alignment: .top)]

    var body: some View {
        let r = monitor.reading
        Page {
            PageHeader(title: "Battery", subtitle: r.deviceName.map { "\($0) · health, power and charging insights" } ?? "Health, power and charging insights",
                       symbol: "battery.100.bolt", colors: Theme.Palette.battery) {
                if r.isPresent {
                    StatusPill(text: BatteryFormat.headline(r), color: r.isCharging ? .green : (r.isPluggedIn ? .blue : BatteryPalette.level(r.percent)))
                }
            }

            if !r.isPresent {
                EmptyStateView(symbol: "desktopcomputer", title: "No battery found",
                               message: "This Mac doesn't have an internal battery, so there's nothing to show here.")
                    .card()
            } else {
                BatteryHeroCard(reading: r, history: monitor.history)
                BatteryTipsCard(tips: BatteryTips.make(reading: r, history: monitor.history))

                LazyVGrid(columns: columns, spacing: Theme.spacing) {
                    BatteryHealthCard(reading: r)
                    BatteryElectricalCard(reading: r)
                    BatteryCellsCard(reading: r)
                    BatteryEstimatesCard(reading: r, history: monitor.history)
                    BatteryEnergyCard()
                    BatteryAlertsCard()
                }

                BatteryChartsSection()
                BatteryChargeLimitCard()
            }
        }
        .onAppear { monitor.start(); monitor.refresh() }
    }
}

// MARK: - Hero

private struct BatteryHeroCard: View {
    let reading: BatteryReading
    let history: [BatteryPoint]

    var body: some View {
        let r = reading
        HStack(alignment: .center, spacing: 32) {
            BatteryHeroGlyph(percent: r.percent, isCharging: r.isCharging, isPluggedIn: r.isPluggedIn, width: 300)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 10) {
                Text(BatteryFormat.headline(r))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.interpolate)
                Text(BatteryFormat.detail(r))
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let t = r.temperature {
                        StatusPill(text: Fmt.temperature(t), color: BatteryPalette.temperature(t))
                    }
                    if r.isPluggedIn, let w = r.adapterWatts {
                        StatusPill(text: "\(w) W adapter", color: .blue)
                    }
                    if r.optimizedCharging == true {
                        StatusPill(text: "Optimized charging", color: .green)
                    }
                    StatusPill(text: "\(r.cycleCount) cycles", color: .gray)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 24)
    }
}

// MARK: - Tips

private struct BatteryTipsCard: View {
    let tips: [BatteryTip]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Tips", symbol: "lightbulb.fill")
            ForEach(tips) { tip in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tip.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tip.color)
                        .frame(width: 32, height: 32)
                        .background(tip.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tip.title).font(.subheadline.weight(.semibold))
                        Text(tip.message).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .card()
    }
}

// MARK: - Health

private struct BatteryHealthCard: View {
    let reading: BatteryReading

    var body: some View {
        let r = reading
        let health = r.health
        let cycleFrac = min(1, Double(r.cycleCount) / 1000)
        let wear = r.cycleCount >= 20 ? (1 - health) / Double(r.cycleCount) * 100 * 100 : nil  // % of capacity lost per 100 cycles
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "Health", symbol: "heart.fill")
                Spacer()
                if let c = r.condition { StatusPill(text: c, color: Theme.levelColor(1 - health, warn: 0.15, critical: 0.25)) }
            }
            HStack(spacing: 18) {
                RingGauge(fraction: health, lineWidth: 11,
                          colors: BatteryPalette.gradient(max(0.5, health)),
                          label: "of design",
                          valueText: Fmt.percent(health))
                    .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    capRow("Design", r.designCapacity)
                    capRow("Full charge", r.fullChargeCapacity)
                    capRow("Nominal", r.nominalCapacity)
                    capRow("Remaining", r.remainingCapacity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Cycle count").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(r.cycleCount) / 1000").monospacedDigit()
                }.font(.callout)
                CapsuleBar(fraction: cycleFrac, color: Theme.levelColor(cycleFrac, warn: 0.6, critical: 0.85), height: 8)
            }
            InfoRow(label: "Est. wear per 100 cycles",
                    value: wear.map { String(format: "%.1f%%", $0) } ?? "Not enough cycles yet",
                    symbol: "chart.line.downtrend.xyaxis")
        }
        .card()
    }

    private func capRow(_ label: String, _ mAh: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(mAh > 0 ? "\(mAh) mAh" : "—").monospacedDigit()
        }.font(.callout)
    }
}

// MARK: - Electrical

private struct BatteryMetric: View {
    let title: String
    let value: String
    var caption: String? = nil
    var color: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatteryElectricalCard: View {
    let reading: BatteryReading

    var body: some View {
        let r = reading
        let bp = r.batteryPowerWatts
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Live electrical", symbol: "bolt.fill")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                BatteryMetric(title: "Voltage", value: String(format: "%.2f V", r.voltage))
                BatteryMetric(title: "Current", value: String(format: "%+.2f A", r.amperage),
                              caption: r.amperage < 0 ? "discharging" : (r.amperage > 0 ? "charging" : "idle"))
                BatteryMetric(title: bp >= 0 ? "Charging power" : "Discharging power",
                              value: BatteryFormat.watts(abs(bp)),
                              color: bp >= 0.1 ? .green : (bp <= -0.1 ? .orange : nil))
                BatteryMetric(title: "System draw",
                              value: r.systemPowerWatts.map { BatteryFormat.watts($0) } ?? "—")
                BatteryMetric(title: "Adapter",
                              value: r.adapterWatts.map { "\($0) W" } ?? (r.isPluggedIn ? "Connected" : "None"),
                              caption: r.adapterName)
                BatteryMetric(title: "Temperature",
                              value: r.temperature.map { Fmt.temperature($0) } ?? "—",
                              color: r.temperature.map { BatteryPalette.temperature($0) })
            }
        }
        .card()
    }
}

// MARK: - Cells

private struct BatteryCellsCard: View {
    let reading: BatteryReading

    var body: some View {
        let cells = reading.cellVoltages.filter { $0 > 0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Cells", symbol: "square.grid.3x1.below.line.grid.1x2")
                Spacer()
                if let lo = cells.min(), let hi = cells.max() {
                    let spread = hi - lo
                    StatusPill(text: spread > 30 ? "Imbalance \(spread) mV" : "Balanced · Δ\(spread) mV",
                               color: spread > 30 ? .orange : .green)
                }
            }
            if cells.isEmpty {
                Text("Cell voltages aren't reported by this battery.").font(.callout).foregroundStyle(.secondary)
            } else {
                let lo = cells.min() ?? 0
                ForEach(Array(cells.enumerated()), id: \.offset) { idx, mv in
                    HStack(spacing: 10) {
                        Text("Cell \(idx + 1)").font(.callout).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        CapsuleBar(fraction: (Double(mv) - 3000) / 1400,
                                   color: mv - lo > 30 ? .orange : Theme.Palette.network, height: 8)
                        Text("\(mv) mV").font(.callout).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
        .card()
    }
}

// MARK: - Estimates

private struct BatteryEstimatesCard: View {
    let reading: BatteryReading
    let history: [BatteryPoint]

    var body: some View {
        let r = reading
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let rate = BatteryAnalytics.dischargePerHour(history, since: startOfDay)
        let since = BatteryAnalytics.sinceFullCharge(history, currentPercent: r.percent)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Estimates", symbol: "clock.fill")
            InfoRow(label: "Time left at current draw",
                    value: BatteryAnalytics.hoursAtCurrentDraw(r).map { BatteryFormat.hours($0) } ?? (r.isPluggedIn ? "On power" : "—"),
                    symbol: "hourglass")
            InfoRow(label: "System estimate",
                    value: r.timeToEmpty.map { BatteryFormat.minutes($0) } ?? r.timeToFull.map { "\(BatteryFormat.minutes($0)) to full" } ?? "—",
                    symbol: "gauge.with.dots.needle.33percent")
            InfoRow(label: "Avg. discharge today",
                    value: rate.map { String(format: "%.1f%% / hour", $0 * 100) } ?? "Not enough data",
                    symbol: "arrow.down.right")
            if let rate, rate > 0.005 {
                InfoRow(label: "Projected full-to-empty",
                        value: BatteryFormat.hours(1 / rate), symbol: "battery.100")
            }
            InfoRow(label: "On battery since last full",
                    value: since.map { BatteryFormat.hours($0.onBattery / 3600) } ?? "—",
                    symbol: "powerplug.portrait")
            InfoRow(label: "Used since last full",
                    value: since.map { Fmt.percent($0.used) } ?? "—", symbol: "minus.circle")
            if let since {
                InfoRow(label: "Last full charge",
                        value: since.since.formatted(.relative(presentation: .named)), symbol: "calendar")
            }
        }
        .card()
    }
}

// MARK: - Energy impact

private struct BatteryProcessIcon: View {
    let pid: pid_t
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "gearshape.fill").foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
    }
}

private struct BatteryEnergyCard: View {
    private var sys: SystemMonitor { .shared }

    var body: some View {
        let top = Array(sys.topCPU.prefix(6))
        let maxCPU = max(0.01, top.first?.cpu ?? 0.01)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Apps using energy", symbol: "flame.fill")
            if top.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Sampling processes…").foregroundStyle(.secondary) }
                    .font(.callout)
            } else {
                ForEach(top) { p in
                    HStack(spacing: 10) {
                        BatteryProcessIcon(pid: p.pid)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.callout).lineLimit(1)
                            CapsuleBar(fraction: p.cpu / maxCPU, color: Theme.levelColor(min(1, p.cpu / 2), warn: 0.35, critical: 0.7), height: 5)
                        }
                        Text(String(format: "%.1f%%", p.cpu * 100))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                Text("Ranked by CPU time — a good proxy for energy impact.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
        .onAppear { sys.requestProcesses() }
        .onDisappear { sys.releaseProcesses() }
    }
}

// MARK: - Alerts

private struct BatteryAlertsCard: View {
    @AppStorage(BatteryAlerts.Key.lowEnabled) private var lowOn = true
    @AppStorage(BatteryAlerts.Key.lowThreshold) private var low = 20
    @AppStorage(BatteryAlerts.Key.highEnabled) private var highOn = false
    @AppStorage(BatteryAlerts.Key.highThreshold) private var high = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Alerts", symbol: "bell.badge.fill")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Notify when battery is low", isOn: $lowOn)
                if lowOn {
                    HStack {
                        Slider(value: Binding(get: { Double(low) }, set: { low = Int($0) }), in: 5...50, step: 5)
                        Text("\(low)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Notify when charged to…", isOn: $highOn)
                if highOn {
                    HStack {
                        Slider(value: Binding(get: { Double(high) }, set: { high = Int($0) }), in: 50...100, step: 5)
                        Text("\(high)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Text("Handy if you like to unplug at 80%.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.mmSwitch)
        .card()
        .onChange(of: lowOn) { _, on in if on { Notifier.requestAuthorization() } }
        .onChange(of: highOn) { _, on in if on { Notifier.requestAuthorization() } }
    }
}

// MARK: - Charge limit info

private struct BatteryChargeLimitCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "leaf.fill", colors: Theme.Palette.cleaner, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("About charge limits").font(.headline)
                Text("Capping charging at 80% requires writing to the SMC as root, which MacMaster doesn't do. macOS has a built-in alternative: Optimized Battery Charging learns your routine and holds the battery at 80% until you need it. Turn it on in System Settings → Battery → Battery Health.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Battery Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(.top, 4)
            }
        }
        .card()
    }
}
