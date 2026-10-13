import SwiftUI

// MARK: - Tweaks tab

struct OptimizerTweaksTab: View {
    private let engine = OptimizerEngine.shared
    @State private var confirmRestore = false

    var body: some View {
        let model = engine.tweaks
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(spacing: 14) {
                IconTile(symbol: "slider.horizontal.3", colors: OptimizerCategory.visual.colors, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Visual performance tweaks").font(.headline)
                    Text("Trade animations for speed. Each switch shows the live system setting and can be reversed. MacMaster remembers your original values.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: "\(model.enabledCount) of \(OptimizerTweakCatalog.all.count) on",
                           color: model.enabledCount > 0 ? Color(hex: 0x0EA5E9) : .secondary)
                Button {
                    confirmRestore = true
                } label: {
                    if model.isRestoring { ProgressView().controlSize(.small) } else { Label("Restore Defaults", systemImage: "arrow.uturn.backward") }
                }
                .disabled(model.isRestoring || (model.enabledCount == 0 && !model.hasOriginals))
            }
            .card()

            VStack(spacing: 0) {
                ForEach(Array(OptimizerTweakCatalog.all.enumerated()), id: \.element.id) { i, tweak in
                    OptimizerTweakRow(tweak: tweak, model: model)
                    if i < OptimizerTweakCatalog.all.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .card(padding: 8)

            Text("Dock and Finder restart briefly when their settings change. Accessibility options may need MacMaster to be allowed in System Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Restore all visual settings?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Defaults") { Task { await model.restoreAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every tweak is returned to the value it had before MacMaster changed it. The Dock and Finder will restart.")
        }
    }
}

private struct OptimizerTweakRow: View {
    let tweak: OptimizerTweak
    let model: OptimizerTweakModel

    var body: some View {
        let busy = model.busy.contains(tweak.id)
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: tweak.symbol, colors: tweak.colors, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tweak.title).font(.callout.weight(.semibold))
                    if let note = tweak.restart.note {
                        OptimizerBadge(text: note, color: .secondary)
                    }
                }
                Text(tweak.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let err = model.errors[tweak.id] {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xF59E0B))
                        Text(err).font(.caption).foregroundStyle(Color(hex: 0xB45309))
                        if tweak.needsAccessibilityAccess {
                            Button("Open Accessibility Settings") { OptimizerTweakModel.openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Toggle(tweak.title, isOn: Binding(
                get: { model.isOn(tweak.id) },
                set: { v in Task { await model.set(tweak.id, on: v) } }))
                .labelsHidden().toggleStyle(.switch).disabled(busy || model.isRestoring)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }
}

// MARK: - Maintenance tab

struct OptimizerMaintenanceTab: View {
    private let engine = OptimizerEngine.shared
    @State private var pending: OptimizerMaintenanceTask?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            statusRow
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Theme.spacing, alignment: .top)], spacing: Theme.spacing) {
                ForEach(OptimizerMaintenance.all) { task in
                    OptimizerMaintenanceCard(task: task) {
                        if task.requiresAdmin { pending = task } else { Task { await engine.performMaintenance(task.id) } }
                    }
                }
            }
        }
        .confirmationDialog(pending?.title ?? "Run task", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { task in
            Button("Run (needs password)") { Task { await engine.performMaintenance(task.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text("\(task.detail)\n\nmacOS will ask for your administrator password.")
        }
    }

    private var statusRow: some View {
        let snap = engine.snapshot
        let days = (snap?.uptime ?? SystemInfo.uptime) / 86_400
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.spacing)], spacing: Theme.spacing) {
            StatTile(title: "Spotlight", value: snap?.spotlightEnabled.map { $0 ? "On" : "Off" } ?? "Unknown",
                     caption: snap?.spotlightText.isEmpty == false ? snap?.spotlightText : "Run a check to read status",
                     symbol: "magnifyingglass", colors: OptimizerCategory.disk.colors)
            StatTile(title: "Local snapshots", value: snap.map { "\($0.localSnapshots)" } ?? "–",
                     caption: "Time Machine on this disk", symbol: "clock.arrow.circlepath", colors: OptimizerCategory.system.colors)
            StatTile(title: "Disk free", value: snap.map { Fmt.bytes($0.diskAvailable) } ?? "–",
                     caption: snap.map { Fmt.percent($0.diskFreeFraction) + " of " + Fmt.bytes($0.diskTotal) },
                     symbol: "internaldrive", colors: OptimizerCategory.network.colors)
            StatTile(title: "Uptime", value: days >= 1 ? "\(Int(days)) d" : Fmt.duration(snap?.uptime ?? SystemInfo.uptime),
                     caption: days > 14 ? "A restart is recommended" : "Since last restart",
                     symbol: "clock", colors: OptimizerCategory.cpu.colors)
        }
    }
}

private struct OptimizerMaintenanceCard: View {
    let task: OptimizerMaintenanceTask
    let run: () -> Void
    private let engine = OptimizerEngine.shared

    var body: some View {
        let status = engine.maintenanceStatus[task.id]
        let running = status == .running
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: task.symbol, colors: task.category.colors, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.callout.weight(.semibold))
                    HStack(spacing: 6) {
                        OptimizerBadge(text: task.category.title, color: .secondary)
                        if task.requiresAdmin { OptimizerBadge(text: "Password", symbol: "lock.fill", color: Color(hex: 0xF59E0B)) }
                        if task.longRunning { OptimizerBadge(text: "Takes a while", symbol: "hourglass", color: .secondary) }
                    }
                }
                Spacer()
            }
            Text(task.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let status, let msg = engine.maintenanceMessage[task.id], !msg.isEmpty {
                    OptimizerStatusIcon(status: status).scaleEffect(0.8).frame(width: 18, height: 18)
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let last = engine.lastRun(task.id) {
                    Text("Last run \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("Never run").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                Button(action: run) {
                    if running { ProgressView().controlSize(.small) } else { Text("Run") }
                }
                .controlSize(.regular)
                .disabled(running || engine.isApplying)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card()
    }
}

// MARK: - History tab

struct OptimizerHistoryTab: View {
    private let engine = OptimizerEngine.shared
    @State private var confirmClear = false

    var body: some View {
        let h = engine.history
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if h.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No optimizations yet",
                               message: "Runs from the Optimize tab and the menu bar will be listed here.")
                    .card()
            } else {
                let mem = h.compactMap(\.memoryFreed).reduce(0, +)
                let disk = h.compactMap(\.diskFreed).reduce(0, +)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.spacing)], spacing: Theme.spacing) {
                    StatTile(title: "Runs", value: "\(h.count)", caption: "Last 50 kept", symbol: "bolt.fill", colors: OptimizerGrade.colors(100))
                    StatTile(title: "Memory freed", value: Fmt.bytes(mem), caption: "Across all runs", symbol: "memorychip", colors: OptimizerCategory.memory.colors)
                    StatTile(title: "Disk recovered", value: Fmt.bytes(disk), caption: "Where measurable", symbol: "internaldrive", colors: OptimizerCategory.disk.colors)
                }
                OptimizerSectionCard(title: "History", symbol: "clock") {
                    VStack(spacing: 0) {
                        ForEach(Array(h.enumerated()), id: \.element.id) { i, e in
                            OptimizerHistoryRow(entry: e)
                            if i < h.count - 1 { Divider() }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear History", role: .destructive) { confirmClear = true }.controlSize(.small)
                }
            }
        }
        .confirmationDialog("Clear optimization history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { engine.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct OptimizerHistoryRow: View {
    let entry: OptimizerHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.semibold))
                    OptimizerBadge(text: sourceLabel, color: .secondary)
                }
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                if !entry.tasks.isEmpty {
                    Text(entry.tasks.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let a = entry.scoreAfter, let b = entry.scoreBefore {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(b) → \(a)").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("score").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var sourceLabel: String {
        switch entry.source {
        case "quick": "Quick optimize"
        case "memory": "Free memory"
        case "auto": "Auto"
        default: "Manual"
        }
    }
    private var symbol: String { entry.source == "memory" ? "wind" : entry.source == "quick" ? "bolt.fill" : "gauge.with.dots.needle.67percent" }
    private var colors: [Color] { entry.source == "memory" ? OptimizerCategory.memory.colors : OptimizerGrade.colors(100) }
}
