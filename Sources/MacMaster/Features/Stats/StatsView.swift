import SwiftUI

struct StatsView: View {
    private var monitor: SystemMonitor { .shared }
    @AppStorage(StatsSettings.intervalKey) private var storedInterval: Double = 2

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: Theme.spacing, alignment: .top)]

    var body: some View {
        Page(jump: [PageJump("stats.cpu", "CPU"), PageJump("stats.memory", "Memory"), PageJump("stats.gpu", "GPU"),
                    PageJump("stats.disk", "Disk"), PageJump("stats.network", "Network"), PageJump("stats.sensors", "Sensors"),
                    PageJump("stats.power", "Power"), PageJump("stats.processes", "Processes"),
                    PageJump("stats.menubar", "Menu bar")]) {
            PageHeader(title: "Stats", subtitle: "\(SystemInfo.current.chip) · \(SystemInfo.current.osVersion) · up \(StatsFmt.uptime(SystemInfo.uptime))",
                       symbol: "chart.bar.xaxis", colors: Theme.Palette.stats) {
                HStack(spacing: 8) {
                    Text("Refresh").font(.callout).foregroundStyle(.secondary)
                    Picker("Refresh", selection: Binding(get: { monitor.interval }, set: { v in
                        monitor.interval = v
                        storedInterval = v
                    })) {
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            LazyVGrid(columns: columns, spacing: Theme.spacing) {
                StatsCPUCard().searchAnchor("stats.cpu")
                StatsMemoryCard().searchAnchor("stats.memory")
                StatsGPUCard().searchAnchor("stats.gpu")
                StatsDiskCard().searchAnchor("stats.disk")
                StatsNetworkCard().searchAnchor("stats.network")
                StatsSensorsCard().searchAnchor("stats.sensors")
                StatsPowerCard().searchAnchor("stats.power")
            }

            StatsProcessExplorer().searchAnchor("stats.processes")
            StatsMenuBarSettingsCard().searchAnchor("stats.menubar")
        }
        .onAppear {
            StatsSettings.applyStoredInterval()
            monitor.start()
            monitor.requestProcesses()
        }
        .onDisappear { monitor.releaseProcesses() }
    }
}
