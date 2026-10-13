import SwiftUI

enum PowerTab: String, CaseIterable, Identifiable {
    case overview, schedule, sleep, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .schedule: "Schedule"
        case .sleep: "Sleep"
        case .settings: "Settings"
        }
    }
}

/// Root screen of the Power feature.
struct PowerView: View {
    @AppStorage("mm.power.tab") private var tabRaw = PowerTab.overview.rawValue

    private var tab: PowerTab { PowerTab(rawValue: tabRaw) ?? .overview }

    var body: some View {
        Page {
            PageHeader(title: "Power", subtitle: "Sleep, schedule and tune how your Mac uses energy",
                       symbol: "bolt.fill", colors: Theme.Palette.yellow) {
                Picker("Section", selection: $tabRaw) {
                    ForEach(PowerTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
            }
            Group {
                switch tab {
                case .overview: PowerOverviewTab()
                case .schedule: PowerScheduleTab()
                case .sleep: PowerSleepTab()
                case .settings: PowerSettingsTab()
                }
            }
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: tabRaw)
        .onAppear { PowerScheduler.shared.start() }
    }
}
