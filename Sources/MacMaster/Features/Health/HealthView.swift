import SwiftUI

/// Root screen of the Health feature.
struct HealthView: View {
    private let monitor = HealthMonitor.shared

    var body: some View {
        Page(jump: [PageJump("health.issues", "Issues"), PageJump("health.checklist", "Checklist"),
                    PageJump("health.activity", "Activity"), PageJump("health.log", "Event log"),
                    PageJump("health.settings", "Settings")]) {
            PageHeader(title: "Health",
                       subtitle: "An always-on watchdog that spots bad patterns on your Mac",
                       symbol: "waveform.path.ecg",
                       colors: Theme.Palette.health)

            if let msg = monitor.lastActionMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.green.opacity(0.12), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HealthHeroCard()
            HealthIssuesSection().searchAnchor("health.issues")
            PermissionBanner(permission: .accessibility,
                             reason: "Lets MacMaster detect apps that have stopped responding.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.spacing, alignment: .top)],
                      alignment: .leading, spacing: Theme.spacing) {
                HealthChecklistCard().searchAnchor("health.checklist")
                HealthActivityCard().searchAnchor("health.activity")
            }

            HealthLogCard().searchAnchor("health.log")
            HealthSettingsCard().searchAnchor("health.settings")
        }
        .animation(.smooth, value: monitor.lastActionMessage)
        .sheet(item: Bindable(monitor).presentedTopList) { kind in
            HealthTopListSheet(kind: kind)
        }
    }
}

// MARK: - Hero

private struct HealthScoreRing: View {
    let score: Int
    @State private var shown = 0.0

    var body: some View {
        let colors = HealthScoring.colors(score)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, shown / 100))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[1].opacity(0.45), radius: 8)
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score)))
                Text("of 100").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, height: 150)
        .onAppear { withAnimation(.easeOut(duration: 1.0)) { shown = Double(score) } }
        .onChange(of: score) { _, new in withAnimation(.smooth(duration: 0.8)) { shown = Double(new) } }
    }
}

private struct HealthHeroCard: View {
    private let monitor = HealthMonitor.shared

    var body: some View {
        let colors = HealthScoring.colors(monitor.score)
        HStack(alignment: .center, spacing: 28) {
            HealthScoreRing(score: monitor.score)

            VStack(alignment: .leading, spacing: 10) {
                Text(HealthScoring.label(monitor.score))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.gradient(colors))
                Text(monitor.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if monitor.isRunning, let since = monitor.startedAt {
                        StatusPill(text: "Active since \(since.formatted(date: .omitted, time: .shortened))", color: .green)
                    } else {
                        StatusPill(text: "Monitoring paused", color: .orange)
                    }
                    if !monitor.issues.isEmpty {
                        StatusPill(text: "\(monitor.issues.count) active issue\(monitor.issues.count == 1 ? "" : "s")",
                                   color: monitor.issues.first?.severity.color ?? .orange)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        monitor.runCheckup()
                    } label: {
                        HStack(spacing: 6) {
                            if monitor.isCheckingUp { ProgressView().controlSize(.small) }
                            else { Image(systemName: "stethoscope") }
                            Text(monitor.isCheckingUp ? "Checking…" : "Run full checkup now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors[1])
                    .disabled(monitor.isCheckingUp)

                    if !monitor.isRunning {
                        Button("Resume monitoring") { monitor.monitoringEnabled = true; monitor.start() }
                    }
                }
            }
            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Last hour").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if monitor.scoreHistory.count >= 2 {
                    Sparkline(values: monitor.scoreHistory.map { Double($0.score) }, color: colors[1], maxValue: 100)
                        .frame(width: 170, height: 70)
                } else {
                    Text("Collecting trend…").font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 170, height: 70)
                }
            }
        }
        .card(padding: 22)
    }
}

// MARK: - Layout helper

struct HealthFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
