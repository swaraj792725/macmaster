import SwiftUI

struct HealthIssuesSection: View {
    private let monitor = HealthMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Active issues", symbol: "exclamationmark.bubble")
            if monitor.issues.isEmpty {
                HStack(spacing: 14) {
                    IconTile(symbol: "checkmark.seal.fill", colors: Theme.Palette.cleaner, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No problems detected").font(.headline)
                        Text(monitor.isRunning
                             ? "The watchdog is checking every 10 seconds and will alert you if something looks wrong."
                             : "Monitoring is paused. Resume it to get alerts.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .card()
            } else {
                ForEach(monitor.issues) { issue in
                    HealthIssueCard(issue: issue)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .animation(.smooth, value: monitor.issues.map(\.key))
    }
}

struct HealthIssueCard: View {
    let issue: HealthIssue
    private let monitor = HealthMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: issue.severity.symbol, colors: [issue.severity.color.opacity(0.85), issue.severity.color], size: 40)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(issue.title).font(.headline)
                    Text(issue.severity.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(issue.severity.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(issue.severity.color)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Detected")
                        Text(issue.detectedAt, style: .relative)
                        Text("ago")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text(issue.detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HealthFlowLayout(spacing: 8) {
                    ForEach(issue.actions.filter { if case .ignoreApp = $0 { return false } else { return true } }, id: \.self) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            monitor.perform(action, for: issue)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Menu {
                        Button("Snooze for 24 hours") { monitor.snooze(issue) }
                        if let app = issue.appName {
                            Button("Never alert for \(app)") { monitor.ignoreApp(app) }
                        }
                    } label: {
                        Label("Ignore", systemImage: "bell.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .card()
        .overlay(alignment: .leading) {
            Capsule().fill(issue.severity.color).frame(width: 3).padding(.vertical, 14)
        }
    }
}

// MARK: - Top processes sheet ("show top CPU/memory apps")

struct HealthTopListSheet: View {
    let kind: HealthTopKind
    @Environment(\.dismiss) private var dismiss
    private let sys = SystemMonitor.shared
    private let monitor = HealthMonitor.shared

    private var list: [ProcessSample] {
        let sorted = kind == .cpu ? sys.processes.sorted { $0.cpu > $1.cpu } : sys.processes.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                IconTile(symbol: kind == .cpu ? "cpu" : "memorychip",
                         colors: [kind == .cpu ? Theme.Palette.cpu : Theme.Palette.memory], size: 34)
                Text(kind == .cpu ? "Top CPU apps" : "Top memory apps").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if list.isEmpty {
                EmptyStateView(symbol: "hourglass", title: "Sampling…", message: "Process data will appear in a moment.")
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { p in
                        HStack(spacing: 10) {
                            Text(p.name).lineLimit(1)
                            Spacer()
                            Text(kind == .cpu ? Fmt.percent(p.cpu, digits: 0) : Fmt.bytes(p.memory))
                                .monospacedDigit().foregroundStyle(.secondary)
                            if HealthSafety.canQuit(pid: p.pid) {
                                Button("Quit") { monitor.perform(.quit(pid: p.pid, name: p.name)) }
                                    .controlSize(.small)
                            } else {
                                Color.clear.frame(width: 44, height: 1)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 440, height: 480, alignment: .topLeading)
    }
}
