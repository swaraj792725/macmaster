import SwiftUI

struct CleanerView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case scan = "Smart Scan", auto = "Auto-Clean"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .scan

    var body: some View {
        Page {
            PageHeader(title: "Cleaner", subtitle: "Keep your Mac clean and fast",
                       symbol: "sparkles", colors: Theme.Palette.cleaner) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            CleanerDiskHeader()
            switch tab {
            case .scan: CleanerScanPane()
            case .auto: CleanerAutoView()
            }
        }
    }
}
