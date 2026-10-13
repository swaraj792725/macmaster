import SwiftUI

struct CleanerConfirmSheet: View {
    var onConfirm: () -> Void
    var onCancel: () -> Void
    private let engine = CleanerEngine.shared
    @State private var ackTrash = false

    var body: some View {
        let items = engine.selectedItems
        let grouped = Dictionary(grouping: items, by: \.category)
        let cats = CleanerCategoryID.allCases.filter { grouped[$0] != nil }
        let hasTrash = grouped[.trash] != nil
        let hasAdmin = items.contains(where: \.needsAdmin)
        let hasPermanent = items.contains { $0.action == .delete }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", colors: Theme.Palette.cleaner, size: 40)
                VStack(alignment: .leading) {
                    Text("Ready to clean").font(.title2.weight(.bold))
                    Text("\(items.count) items · \(Fmt.bytes(engine.selectedBytes))").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(cats) { c in
                        let list = grouped[c] ?? []
                        HStack(spacing: 10) {
                            IconTile(symbol: c.symbol, colors: c.colors, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.callout.weight(.medium))
                                Text(Set(list.map(\.actionLabel)).sorted().joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(list.count)").foregroundStyle(.secondary)
                            Text(Fmt.bytes(list.reduce(0) { $0 + $1.size })).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 260)

            VStack(alignment: .leading, spacing: 6) {
                if hasPermanent {
                    Label("Caches and logs are deleted permanently; apps rebuild them as needed. Everything else goes to the Trash.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if hasAdmin {
                    Label("macOS will ask for your administrator password once.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hasTrash {
                    Toggle(isOn: $ackTrash) {
                        Text("I understand emptying the Trash is permanent and cannot be undone.")
                            .font(.callout.weight(.medium)).foregroundStyle(.red)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Clean \(Fmt.bytes(engine.selectedBytes))", action: onConfirm)
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.cleaner[1])
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || (hasTrash && !ackTrash))
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

struct CleanerSummaryCard: View {
    let summary: CleanerSummary
    var onDone: () -> Void
    var onRescan: () -> Void
    @State private var shown: Double = 0
    @State private var showFailures = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: summary.failures.isEmpty ? "checkmark.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.gradient(Theme.Palette.cleaner))
                .symbolEffect(.bounce, value: shown)
            CleanerCountUp(value: shown, size: 54)
                .foregroundStyle(Theme.gradient(Theme.Palette.cleaner))
            Text(summary.freed > 0 ? "freed from your Mac" : "nothing needed removing")
                .foregroundStyle(.secondary)
            Text("\(summary.removedCount) item\(summary.removedCount == 1 ? "" : "s") cleaned")
                .font(.callout).foregroundStyle(.secondary)

            let top = summary.perCategory.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5)
            if !top.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(top), id: \.key) { cat, bytes in
                        HStack {
                            IconTile(symbol: cat.symbol, colors: cat.colors, size: 22)
                            Text(cat.title).font(.callout)
                            Spacer()
                            Text(Fmt.bytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 380)
            }

            if !summary.failures.isEmpty {
                DisclosureGroup(isExpanded: $showFailures) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.failures) { f in
                            Text("\(f.name) — \(f.reason)").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    Label("\(summary.failures.count) item\(summary.failures.count == 1 ? "" : "s") could not be removed",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .frame(maxWidth: 480)
            }
            HStack {
                Button("Scan again", action: onRescan)
                Button("Done", action: onDone).buttonStyle(.borderedProminent).tint(Theme.Palette.cleaner[1])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .card()
        .onAppear {
            shown = 0
            withAnimation(.easeOut(duration: 1.4)) { shown = Double(summary.freed) }
        }
    }
}
