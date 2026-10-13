import SwiftUI

struct StatsView: View {
    private var monitor: SystemMonitor { .shared }
    @AppStorage(StatsSettings.intervalKey) private var storedInterval: Double = 2

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: Theme.spacing, alignment: .top)]

    var body: some View {
        Page {
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
                StatsCPUCard()
                StatsMemoryCard()
                StatsGPUCard()
                StatsDiskCard()
                StatsNetworkCard()
                StatsSensorsCard()
                StatsPowerCard()
            }

            StatsProcessExplorer()
            StatsMenuBarSettingsCard()
        }
        .onAppear {
            StatsSettings.applyStoredInterval()
            monitor.start()
            monitor.requestProcesses()
        }
        .onDisappear { monitor.releaseProcesses() }
    }
}
