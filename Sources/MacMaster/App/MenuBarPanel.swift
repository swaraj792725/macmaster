import SwiftUI

/// Compact popover shown from the main MacMaster menu bar icon.
struct MenuBarPanel: View {
    @State private var monitor = SystemMonitor.shared
    @State private var battery = BatteryMonitor.shared
    @State private var health = HealthMonitor.shared
    @State private var awake = ToolsKeepAwake.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconTile(symbol: "macbook", colors: Theme.Palette.dashboard, size: 26)
                Text("MacMaster").font(.headline)
                Spacer()
                StatusPill(text: "Health \(health.score)", color: health.score >= 80 ? .green : health.score >= 60 ? .orange : .red)
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    gauge("CPU", monitor.cpu.total, Theme.Palette.stats)
                    gauge("RAM", monitor.memory.usedFraction, [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)])
                    gauge("GPU", monitor.gpu, [Color(hex: 0xF472B6), Color(hex: 0xBE185D)])
                    gauge("Disk", monitor.disk.usedFraction, Theme.Palette.tools)
                }
            }

            VStack(spacing: 6) {
                InfoRow(label: "Network", value: "↓ \(Fmt.rate(monitor.network.downRate))  ↑ \(Fmt.rate(monitor.network.upRate))", symbol: "network")
                if let t = monitor.thermal.cpu { InfoRow(label: "CPU temperature", value: Fmt.temperature(t), symbol: "thermometer.medium") }
                if battery.reading.isPresent {
                    InfoRow(label: "Battery", value: "\(Fmt.percent(battery.reading.percent)) · health \(Fmt.percent(battery.reading.health))",
                            symbol: battery.reading.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                }
            }

            if !health.issues.isEmpty {
                Button { openMain(.health) } label: {
                    Label(health.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack {
                Toggle(isOn: Binding(get: { awake.isActive }, set: { _ in awake.toggle() })) {
                    Label("Keep Awake", systemImage: "cup.and.heat.waves.fill")
                }
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Open") { openMain(nil) }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit MacMaster")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { monitor.start() }
    }

    private func gauge(_ label: String, _ value: Double, _ colors: [Color]) -> some View {
        RingGauge(fraction: value, lineWidth: 6, colors: colors, label: label)
            .frame(width: 64, height: 64)
    }

    private func openMain(_ section: AppSection?) {
        MainStatusItem.shared.close()
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { openWindow(id: "main") }
        MainWindow.show(section: section)
    }
}
