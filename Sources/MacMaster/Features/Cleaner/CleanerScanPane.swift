import SwiftUI

struct CleanerScanPane: View {
    private let engine = CleanerEngine.shared
    @State private var expanded: Set<CleanerCategoryID> = []
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            PermissionBanner(permission: .fullDiskAccess,
                             reason: "Mail, Messages, Safari data and Trash are protected. Without access they are skipped.")
            switch engine.phase {
            case .idle: idle
            case .scanning: scanning
            case .results: results
            case .cleaning: cleaning
            case .done:
                if let s = engine.summary {
                    CleanerSummaryCard(summary: s, onDone: { engine.backToResults() }, onRescan: { engine.scan() })
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            ramCard
        }
        .animation(.smooth, value: engine.phase)
        .sheet(isPresented: $confirming) {
            CleanerConfirmSheet(onConfirm: { confirming = false; engine.clean() },
                                onCancel: { confirming = false })
        }
    }

    // MARK: Phases

    private var idle: some View {
        VStack(spacing: 14) {
            CleanerOrb(scanning: false, title: "Scan", subtitle: "Smart Scan") { engine.scan() }
                .padding(.top, 8)
            Text("Find caches, logs, developer junk, old downloads and more.")
                .font(.headline)
            Text("Nothing is removed until you review the results and confirm.")
                .font(.callout).foregroundStyle(.secondary)
            if let last = engine.lastScan {
                Text("Last scan \(CleanerFormat.relative(last))").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .card()
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                CleanerOrb(scanning: true, progress: engine.scanProgress, title: Fmt.bytes(engine.totalReclaimable),
                           subtitle: "found so far", size: 170)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scanning \(engine.finished.count) of \(CleanerCategoryID.allCases.count)…").font(.title3.weight(.semibold))
                    CapsuleBar(fraction: engine.scanProgress, color: Theme.Palette.cleaner[1]).frame(maxWidth: 280)
                    Button("Cancel") { engine.cancelScan() }
                }
                Spacer()
            }
            categoryList(onlyFinished: true)
        }
        .card()
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.bytes(engine.selectedBytes))
                        .font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.gradient(Theme.Palette.cleaner))
                        .contentTransition(.numericText())
                    Text("selected of \(Fmt.bytes(engine.totalReclaimable)) found · \(Fmt.count(engine.selectedItems.count, "item"))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        confirming = true
                    } label: {
                        Label("Clean", systemImage: "sparkles").font(.headline).frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Palette.cleaner[1])
                    .disabled(engine.selectedItems.isEmpty)
                    HStack {
                        Button("Select safe") { engine.selectAllSafe() }
                        Button("None") { engine.deselectAll() }
                        Button("Rescan") { engine.scan() }
                    }
                    .controlSize(.small)
                }
            }
            categoryList(onlyFinished: false)
        }
        .card()
    }

    private var cleaning: some View {
        VStack(spacing: 14) {
            CleanerOrb(scanning: true, progress: engine.cleanProgress, title: Fmt.percent(engine.cleanProgress),
                       subtitle: "cleaning", size: 150)
            Text(engine.cleanStatus).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            CapsuleBar(fraction: engine.cleanProgress, color: Theme.Palette.cleaner[1]).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .card()
    }

    @ViewBuilder
    private func categoryList(onlyFinished: Bool) -> some View {
        let all = CleanerCategoryID.allCases
        let withItems = all.filter { !engine.items($0).isEmpty }.sorted { engine.total($0) > engine.total($1) }
        let pending = all.filter { !engine.finished.contains($0) }
        let empty = all.filter { engine.finished.contains($0) && engine.items($0).isEmpty }
        VStack(spacing: 8) {
            ForEach(withItems) { CleanerCategoryRow(id: $0, expanded: $expanded) }
            if engine.phase == .scanning {
                ForEach(pending) { CleanerCategoryRow(id: $0, expanded: $expanded) }
            }
            if !empty.isEmpty {
                Text("Nothing to clean in: " + empty.map(\.title).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }

    // MARK: Free RAM

    private var ramCard: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "memorychip", colors: Theme.Palette.stats, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Free up RAM").font(.headline)
                Text(engine.ramMessage ?? "Purges inactive memory and disk caches with the system purge tool. Needs administrator access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.freeRAM()
            } label: {
                if engine.ramBusy { ProgressView().controlSize(.small) } else { Text("Free RAM") }
            }
            .disabled(engine.ramBusy)
        }
        .card()
    }
}
