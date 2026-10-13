import SwiftUI
import AppKit

struct StatsProcessExplorer: View {
    private var m: SystemMonitor { .shared }
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpu, order: .reverse)]
    @State private var selection = Set<pid_t>()
    @State private var pending: PendingKill?

    private struct PendingKill: Identifiable {
        let pid: pid_t
        let name: String
        let force: Bool
        var id: pid_t { pid }
    }

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = m.processes
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || String($0.pid) == q }
            .sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "list.bullet.rectangle.fill", colors: Theme.Palette.stats, size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Process explorer").font(.headline)
                    Text("\(Fmt.count(rows.count, "process", plural: "processes")) · right-click to quit").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search name or PID", text: $search).textFieldStyle(.plain).frame(width: 170)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { p in
                    HStack(spacing: 8) {
                        StatsAppIcon(pid: p.pid, size: 18)
                        Text(p.name).lineLimit(1)
                    }
                }
                TableColumn("PID", value: \.pid) { p in
                    Text(String(p.pid)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64, max: 90)
                TableColumn("CPU", value: \.cpu) { p in
                    Text(String(format: "%.1f%%", p.cpu * 100)).monospacedDigit()
                        .foregroundStyle(p.cpu > 1 ? Color.orange : Color.primary)
                }
                .width(min: 60, ideal: 80, max: 110)
                TableColumn("Memory", value: \.memory) { p in
                    Text(Fmt.bytes(p.memory)).monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 130)
            }
            .contextMenu(forSelectionType: pid_t.self) { ids in
                if let pid = ids.first, let p = m.processes.first(where: { $0.pid == pid }) {
                    Button("Quit \(p.name)") { pending = PendingKill(pid: pid, name: p.name, force: false) }
                    Button("Force Quit \(p.name)", role: .destructive) { pending = PendingKill(pid: pid, name: p.name, force: true) }
                    Divider()
                    Button("Copy PID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(pid), forType: .string)
                    }
                }
            }
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
        .card()
        .onAppear { m.requestProcesses() }
        .onDisappear { m.releaseProcesses() }
        .confirmationDialog(pending.map { ($0.force ? "Force quit " : "Quit ") + "“\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.force ? "Force Quit" : "Quit", role: .destructive) { Self.terminate(p.pid, force: p.force) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.force ? "The process is killed immediately; unsaved work will be lost."
                         : "The process is asked to quit (SIGTERM). Unsaved work may be lost.")
        }
    }

    private static func terminate(_ pid: pid_t, force: Bool) {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
    }
}
