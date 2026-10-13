import SwiftUI

struct UninstallerRemovalSheet: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = model.summary {
                results(summary)
            } else if model.isRemoving {
                running
            } else if let plan = model.plan {
                confirm(plan)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isRemoving)
    }

    // MARK: Confirm

    private func confirm(_ plan: UninstallerRemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let app = plan.app { UninstallerAppIcon(url: app.url, size: 44) }
                else { IconTile(symbol: "trash.fill", colors: Theme.Palette.uninstaller, size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title).font(.title3.weight(.semibold))
                    Text("\(plan.items.count) item\(plan.items.count == 1 ? "" : "s") · \(Fmt.bytes(plan.totalSize))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.items.prefix(60)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.category.symbol).foregroundStyle(.secondary).frame(width: 16)
                            Text(item.isReceipt ? "Receipt: \(item.name)" : item.displayPath)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.isReceipt ? "" : Fmt.bytes(item.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if plan.items.count > 60 {
                        Text("… and \(plan.items.count - 60) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 190)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                if plan.appIsRunning, let app = plan.app {
                    note("\(app.name) is running and will be quit first.", "power", .orange)
                }
                if plan.adminCount > 0 {
                    note("\(plan.adminCount) item\(plan.adminCount == 1 ? "" : "s") need administrator access – you will be asked once.", "lock.shield", .orange)
                }
                if plan.items.contains(where: { $0.launchLabel != nil }) {
                    note("Launch agents/daemons will be unloaded first.", "bolt.slash", .secondary)
                }
                Toggle(isOn: Binding(get: { model.plan?.deleteImmediately ?? false },
                                     set: { model.plan?.deleteImmediately = $0 })) {
                    Text("Delete immediately instead of moving to Trash").font(.callout)
                }
                if model.plan?.deleteImmediately == true {
                    note("Deleted items cannot be recovered.", "exclamationmark.triangle.fill", .red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.dismissPlan() }.keyboardShortcut(.cancelAction)
                Button(plan.source == .reset ? "Reset" : (plan.source == .app ? "Uninstall" : "Remove")) {
                    model.executeRemoval()
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func note(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Removing…").font(.title3.weight(.semibold))
            Text(model.removalProgress).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: Results

    private func results(_ s: UninstallerRemovalSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: s.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                         colors: s.failures.isEmpty ? Theme.Palette.cleaner : Theme.Palette.tools, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.failures.isEmpty ? "Done" : "Finished with issues").font(.title3.weight(.semibold))
                    Text("\(s.removedCount) removed · \(Fmt.bytes(s.freed)) \(s.permanent ? "freed" : "moved to Trash")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !s.failures.isEmpty {
                Text("\(s.failures.count) could not be removed").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.failures) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(f.reason).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 160)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(s.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { model.dismissPlan() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}
