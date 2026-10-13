import SwiftUI

// MARK: - Optimize tab

struct OptimizerOptimizeTab: View {
    @Bindable var flow: OptimizerFlow
    private let engine = OptimizerEngine.shared
    @State private var confirmFreeMemory = false
    @State private var forcePending: OptimizerRecommendation?

    private var stage: OptimizerStage {
        (engine.isApplying && flow.stage == .idle) ? .running : flow.stage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            switch stage {
            case .idle: idle
            case .analyzing: analyzing
            case .review: review
            case .running: running
            case .done: done
            }
        }
        .transition(.opacity)
        .animation(.smooth(duration: 0.35), value: stage)
        .confirmationDialog("Free inactive memory?", isPresented: $confirmFreeMemory, titleVisibility: .visible) {
            Button("Free Memory") { Task { await flow.freeMemory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs the built-in purge command to release cached memory. macOS will ask for your administrator password.")
        }
        .confirmationDialog("Force quit \(forcePending?.title.replacingOccurrences(of: "Quit ", with: "") ?? "process")?",
                            isPresented: Binding(get: { forcePending != nil }, set: { if !$0 { forcePending = nil } }),
                            titleVisibility: .visible, presenting: forcePending) { rec in
            Button("Force Quit", role: .destructive) { Task { await flow.force(rec) } }
            Button("Cancel", role: .cancel) {}
        } message: { rec in
            Text(rec.force?.confirm ?? "")
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            hero(compact: false, busy: false)
            if let notice = flow.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color(hex: 0x0EA5E9))
                    Text(notice).font(.callout)
                    Spacer()
                    Button { flow.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            OptimizerLiveGraphs()
            OptimizerFactorsCard()
            OptimizerAutoCard()
        }
    }

    private var analyzing: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            hero(compact: false, busy: true)
            OptimizerLiveGraphs()
        }
    }

    private func hero(compact: Bool, busy: Bool) -> some View {
        let colors = OptimizerGrade.colors(engine.score)
        return HStack(spacing: compact ? 20 : 32) {
            OptimizerScoreRing(score: engine.score, hasScore: engine.hasScore, busy: busy, size: compact ? 120 : 200)
            VStack(alignment: .leading, spacing: 10) {
                Text(headline(busy: busy))
                    .font(.system(size: compact ? 20 : 26, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text(subline(busy: busy))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    HStack(spacing: 10) {
                        Button {
                            Task { await flow.begin() }
                        } label: {
                            Label(busy ? "Analyzing…" : "Optimize", systemImage: busy ? "hourglass" : "bolt.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(minWidth: 120)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(colors.last ?? .accentColor)
                        .disabled(busy || engine.isApplying)
                        .keyboardShortcut(.defaultAction)

                        Button {
                            confirmFreeMemory = true
                        } label: {
                            if flow.isFreeingMemory { ProgressView().controlSize(.small) }
                            else { Label("Free Memory", systemImage: "wind") }
                        }
                        .controlSize(.large)
                        .disabled(busy || engine.isApplying || flow.isFreeingMemory)
                        .help("Releases inactive memory with purge (asks for your password)")
                    }
                    .padding(.top, 4)
                }
                if let last = engine.lastAnalyzed, !busy {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: compact ? 18 : 28)
        .background(alignment: .topLeading) {
            RadialGradient(colors: [(colors.first ?? .clear).opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private func headline(busy: Bool) -> String {
        if busy { return engine.analysisStep.isEmpty ? "Analyzing your Mac…" : engine.analysisStep }
        if flow.stage == .review {
            let n = engine.recommendations.count
            return n == 0 ? "Everything looks great" : "\(n) thing\(n == 1 ? "" : "s") can be improved"
        }
        guard engine.hasScore else { return "Let's tune up your Mac" }
        switch engine.score {
        case 90...: return "Your Mac is running great"
        case 75..<90: return "Your Mac is running well"
        case 55..<75: return "Your Mac could run better"
        default: return "Your Mac needs attention"
        }
    }

    private func subline(busy: Bool) -> String {
        if busy { return "Checking memory, CPU activity, disk, startup items and system health. This takes about ten seconds." }
        if flow.stage == .review { return "Review each item below. Nothing runs until you press Optimize." }
        if engine.hasScore {
            let n = engine.recommendations.count
            return n == 0 ? "No problems found. Run a full check any time for fresh CPU sampling."
                          : "\(n) recommendation\(n == 1 ? "" : "s") found. Run a full check to review and apply them."
        }
        return "Run a full check to see what's slowing your Mac down. You choose what to apply."
    }

    // MARK: Review

    private var review: some View {
        let groups = Dictionary(grouping: engine.recommendations, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
        return VStack(alignment: .leading, spacing: Theme.spacing) {
            hero(compact: true, busy: engine.isAnalyzing)
            if let m = flow.forceMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color(hex: 0x0EA5E9))
                    Text(m).font(.callout)
                    Spacer()
                    Button { flow.forceMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            if engine.recommendations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44))
                        .foregroundStyle(Theme.gradient(OptimizerGrade.colors(100)))
                    Text("Nothing to optimize").font(.title3.weight(.semibold))
                    Text("Memory, CPU, disk and startup all look healthy.").foregroundStyle(.secondary)
                    Button("Done") { flow.reset() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: .infinity).padding(36).card()
            } else {
                ForEach(groups, id: \.key) { category, recs in
                    OptimizerCategoryCard(category: category, recs: recs, flow: flow) { forcePending = $0 }
                }
                // Room for the floating action bar
                Color.clear.frame(height: 52)
            }
        }
    }

    // MARK: Running

    private var running: some View {
        let tasks = engine.tasks
        let finished = tasks.filter { $0.status != .pending && $0.status != .running }.count
        let fraction = tasks.isEmpty ? 0 : Double(finished) / Double(tasks.count)
        return VStack(alignment: .leading, spacing: Theme.spacing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.regular)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Optimizing…").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("\(finished) of \(tasks.count) tasks finished").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                }
                CapsuleBar(fraction: max(0.03, fraction), color: Color(hex: 0x0EA5E9), height: 8)
            }
            .card(padding: 20)

            OptimizerSectionCard(title: "Tasks", symbol: "checklist") {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in
                        OptimizerTaskRow(report: t)
                        if i < tasks.count - 1 { Divider() }
                    }
                }
            }
            OptimizerLiveGraphs()
        }
    }

    // MARK: Done

    @ViewBuilder
    private var done: some View {
        if let r = engine.lastResult {
            OptimizerResultView(result: r, onDone: { flow.reset() }, onAgain: { Task { await flow.begin() } })
        } else {
            EmptyStateView(symbol: "checkmark.circle", title: "All done")
        }
    }
}

// MARK: - Category card & rows

struct OptimizerCategoryCard: View {
    let category: OptimizerCategory
    let recs: [OptimizerRecommendation]
    @Bindable var flow: OptimizerFlow
    var onForce: (OptimizerRecommendation) -> Void

    var body: some View {
        let actionable = recs.filter(\.isActionable)
        let allOn = !actionable.isEmpty && actionable.allSatisfy { flow.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                IconTile(symbol: category.symbol, colors: category.colors, size: 26)
                Text(category.title).font(.headline)
                Text("\(recs.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                Spacer()
                if !actionable.isEmpty {
                    Button(allOn ? "Select None" : "Select All") { flow.setAll(actionable, on: !allOn) }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.bottom, 6)
            ForEach(Array(recs.enumerated()), id: \.element.id) { i, rec in
                if i > 0 { Divider() }
                OptimizerRecRow(rec: rec, selected: flow.selection.contains(rec.id),
                                toggle: { withAnimation(.snappy(duration: 0.2)) { flow.toggle(rec.id) } },
                                onForce: { onForce(rec) })
            }
        }
        .card()
    }
}

struct OptimizerRecRow: View {
    let rec: OptimizerRecommendation
    let selected: Bool
    let toggle: () -> Void
    let onForce: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(rec.title).font(.callout.weight(.semibold))
                    OptimizerBadge(text: rec.impact.title, color: rec.impact.color)
                    if rec.requiresAdmin { OptimizerBadge(text: "Password", symbol: "lock.fill", color: Color(hex: 0xF59E0B)) }
                    if rec.quitsApps { OptimizerBadge(text: "Quits app", symbol: "xmark.app", color: Color(hex: 0x8B5CF6)) }
                    if rec.irreversible { OptimizerBadge(text: "Permanent", symbol: "exclamationmark.triangle.fill", color: Color(hex: 0xEF4444)) }
                }
                Text(rec.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.circle.fill").font(.caption2)
                    Text(rec.gain).font(.caption.weight(.medium))
                }
                .foregroundStyle(Color(hex: 0x16A34A))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let link = rec.link {
                    Button(link.label) { link.open() }.controlSize(.small)
                }
                if rec.force != nil {
                    Button("Force Quit", role: .destructive, action: onForce).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if rec.isActionable { toggle() } }
    }

    @ViewBuilder
    private var leading: some View {
        if rec.isActionable {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel(selected ? "Deselect \(rec.title)" : "Select \(rec.title)")
        } else {
            Image(systemName: "info.circle")
                .font(.system(size: 20)).foregroundStyle(.tertiary).padding(.top, 1)
        }
    }
}

// MARK: - Factors

struct OptimizerFactorsCard: View {
    private let engine = OptimizerEngine.shared

    var body: some View {
        OptimizerSectionCard(title: "What affects your score", symbol: "list.bullet.below.rectangle",
                             trailing: engine.hasScore ? nil : "Run a check to fill this in") {
            if engine.scoreFactors.isEmpty {
                Text("Your score combines memory pressure, swap, CPU hogs, free disk space, startup items, uptime and sleep blockers.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(engine.scoreFactors) { f in
                        HStack(spacing: 10) {
                            IconTile(symbol: f.symbol, colors: f.colors, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.title).font(.callout.weight(.semibold))
                                Text(f.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if f.isGood {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x22C55E))
                            } else {
                                Text("-\(f.penalty)").font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(f.penalty >= 10 ? Color(hex: 0xEF4444) : Color(hex: 0xF59E0B))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Auto-optimize

struct OptimizerAutoCard: View {
    @Bindable private var engine = OptimizerEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "bell.badge", colors: [Color(hex: 0xFB923C), Color(hex: 0xEF4444)], size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-optimize").font(.headline)
                    Text("Watch in the background and notify you when memory pressure stays critical or a process hogs the CPU.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Auto-optimize", isOn: $engine.autoEnabled).labelsHidden().toggleStyle(.switch)
            }
            if engine.autoEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: $engine.autoMinutes, in: 1...60) {
                        Text("React after \(engine.autoMinutes) minute\(engine.autoMinutes == 1 ? "" : "s")").font(.callout)
                    }
                    Stepper(value: $engine.autoCPUPercent, in: 30...800, step: 10) {
                        Text("CPU hog threshold: \(engine.autoCPUPercent)% of a core").font(.callout)
                    }
                    Toggle(isOn: $engine.autoRunSafeTasks) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Also run safe tasks automatically").font(.callout)
                            Text("Only reversible, non-admin tasks. Apps are never quit and nothing is deleted.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
        .animation(.smooth, value: engine.autoEnabled)
    }
}

// MARK: - Result

struct OptimizerResultView: View {
    let result: OptimizerResult
    let onDone: () -> Void
    let onAgain: () -> Void

    var body: some View {
        let ok = result.failed == 0 && result.succeeded > 0
        let colors = ok ? OptimizerGrade.colors(100) : OptimizerGrade.colors(60)
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(spacing: 18) {
                IconTile(symbol: ok ? "checkmark" : "exclamationmark.triangle.fill", colors: colors, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ok ? "All optimized" : (result.succeeded > 0 ? "Optimized with some issues" : "Nothing was changed"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(result.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Again", action: onAgain).controlSize(.large)
                Button("Done", action: onDone).buttonStyle(.borderedProminent).controlSize(.large)
            }
            .card(padding: 22)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.spacing)], spacing: Theme.spacing) {
                OptimizerCompareTile(
                    title: "Memory used", symbol: "memorychip", colors: OptimizerCategory.memory.colors,
                    before: Fmt.bytes(result.before.memUsed), after: Fmt.bytes(result.after.memUsed),
                    delta: result.memoryFreed > 0 ? "\(Fmt.bytes(result.memoryFreed)) freed" : nil, improved: result.memoryFreed > 0)
                OptimizerCompareTile(
                    title: "Disk free", symbol: "internaldrive", colors: OptimizerCategory.disk.colors,
                    before: Fmt.bytes(result.before.diskFree), after: Fmt.bytes(result.after.diskFree),
                    delta: result.diskFreed > 1 << 20 ? "\(Fmt.bytes(result.diskFreed)) recovered" : nil, improved: result.diskFreed > 1 << 20)
                OptimizerCompareTile(
                    title: "Performance score", symbol: "gauge.with.dots.needle.67percent", colors: OptimizerGrade.colors(result.scoreAfter),
                    before: "\(result.scoreBefore)", after: "\(result.scoreAfter)",
                    delta: result.scoreAfter > result.scoreBefore ? "+\(result.scoreAfter - result.scoreBefore) points" : nil,
                    improved: result.scoreAfter > result.scoreBefore)
            }

            OptimizerSectionCard(title: "Tasks", symbol: "checklist") {
                VStack(spacing: 0) {
                    ForEach(Array(result.reports.enumerated()), id: \.element.id) { i, t in
                        OptimizerTaskRow(report: t)
                        if i < result.reports.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}
