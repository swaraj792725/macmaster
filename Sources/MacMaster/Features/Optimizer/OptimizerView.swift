import SwiftUI

enum OptimizerTab: String, CaseIterable, Identifiable {
    case optimize, tweaks, maintenance, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optimize: "Optimize"
        case .tweaks: "Tweaks"
        case .maintenance: "Maintenance"
        case .history: "History"
        }
    }
}

/// Root screen of the Optimizer feature.
struct OptimizerView: View {
    private let engine = OptimizerEngine.shared
    @State private var tab: OptimizerTab = .optimize
    @State private var flow = OptimizerFlow()
    @State private var confirmRun = false

    var body: some View {
        Page {
            PageHeader(title: "Optimizer", subtitle: "Tune memory, CPU, disk and animations",
                       symbol: "gauge.with.dots.needle.67percent",
                       colors: [Color(hex: 0x34D399), Color(hex: 0x0EA5E9)]) {
                Picker("Section", selection: $tab) {
                    ForEach(OptimizerTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
            Group {
                switch tab {
                case .optimize: OptimizerOptimizeTab(flow: flow)
                case .tweaks: OptimizerTweaksTab()
                case .maintenance: OptimizerMaintenanceTab()
                case .history: OptimizerHistoryTab()
                }
            }
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: tab)
        .searchTab($tab)
        .animation(.smooth(duration: 0.35), value: flow.stage)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab == .optimize && flow.stage == .review && !engine.recommendations.isEmpty { actionBar }
        }
        .onAppear { engine.start() }
        .confirmationDialog("Run \(flow.selectedRecs.count) task\(flow.selectedRecs.count == 1 ? "" : "s")?",
                            isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Optimize") { Task { await flow.applySelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(flow.confirmationText)
        }
    }

    private var actionBar: some View {
        let recs = flow.selectedRecs
        let admin = recs.filter(\.requiresAdmin).count
        let mem = recs.reduce(Int64(0)) { $0 + $1.estimatedMemory }
        let disk = recs.reduce(Int64(0)) { $0 + $1.estimatedDisk }
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recs.isEmpty ? "Nothing selected" : "\(recs.count) selected")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    if mem > 0 { Text("~\(Fmt.bytes(mem)) memory") }
                    if disk > 0 { Text("~\(Fmt.bytes(disk)) disk") }
                    if admin > 0 { Label("\(admin) need your password", systemImage: "lock.fill") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { flow.reset() }.controlSize(.large)
            Button {
                if flow.needsConfirmation { confirmRun = true } else { Task { await flow.applySelected() } }
            } label: {
                Text(recs.isEmpty ? "Optimize" : "Optimize \(recs.count) item\(recs.count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recs.isEmpty)
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
