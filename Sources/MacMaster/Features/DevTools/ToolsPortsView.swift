import SwiftUI
import AppKit
import Observation
import Darwin

// MARK: - Model

/// A kill that is waiting for the user's confirmation.
struct PortsPendingKill: Identifiable {
    enum Stage { case terminate, force, admin }
    let entry: PortEntry
    var stage: Stage
    var id: String { entry.id + "\(stage)" }
}

@Observable
@MainActor
final class PortsModel {
    private(set) var entries: [PortEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var updated: Date?
    var includeUDP: Bool {
        didSet { UserDefaults.standard.set(includeUDP, forKey: "ports.includeUDP"); Task { await refresh() } }
    }
    var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "ports.autoRefresh") }
    }
    var pending: PortsPendingKill?

    @ObservationIgnored private var icons: [Int32: NSImage] = [:]

    init() {
        let d = UserDefaults.standard
        includeUDP = d.bool(forKey: "ports.includeUDP")
        autoRefresh = d.object(forKey: "ports.autoRefresh") as? Bool ?? true
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let udp = includeUDP
        let result: (entries: [PortEntry], error: String?) = await Task.detached(priority: .userInitiated) {
            let tcp = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnLTuP"], timeout: 15)
            if tcp.status < 0 { return ([], "Could not run lsof: \(tcp.stderr)") }
            var all = PortsParser.parse(tcp.stdout, defaultProto: "TCP")
            if udp {
                let u = Shell.run("/usr/sbin/lsof", ["-nP", "-iUDP", "-FpcnLTuP"], timeout: 15)
                all += PortsParser.parse(u.stdout, defaultProto: "UDP")
            }
            all.sort { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
            return (all, nil)
        }.value
        error = result.error
        if result.error == nil, result.entries != entries { entries = result.entries }
        hasLoaded = true
        updated = Date()
        let live = Set(entries.map(\.pid))
        icons = icons.filter { live.contains($0.key) }
    }

    func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    func icon(for e: PortEntry) -> NSImage {
        if let i = icons[e.pid] { return i }
        let img: NSImage
        if let app = NSRunningApplication(processIdentifier: e.pid), let i = app.icon {
            img = i
        } else if let p = executablePath(e.pid) {
            img = NSWorkspace.shared.icon(forFile: p)
        } else {
            img = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[e.pid] = img
        return img
    }

    func canKill(_ e: PortEntry) -> Bool { e.pid > 1 && e.pid != getpid() }

    func ownedByMe(_ e: PortEntry) -> Bool { e.uid == getuid() }

    func open(_ e: PortEntry) {
        guard let url = URL(string: "http://localhost:\(e.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ e: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("localhost:\(e.port)", forType: .string)
        ToolsToastCenter.shared.show("Copied localhost:\(e.port)")
    }

    func reveal(_ e: PortEntry) {
        guard let p = executablePath(e.pid) else {
            ToolsToastCenter.shared.show("Could not find the program for \(e.command).", error: true)
            return
        }
        toolsReveal([URL(fileURLWithPath: p)])
    }

    /// Entry point for the Stop button.
    func requestKill(_ e: PortEntry) {
        guard canKill(e) else { return }
        pending = PortsPendingKill(entry: e, stage: ownedByMe(e) ? .terminate : .admin)
    }

    /// Runs the confirmed step.
    func confirm(_ p: PortsPendingKill) async {
        pending = nil
        let e = p.entry
        switch p.stage {
        case .terminate, .force:
            let sig = p.stage == .terminate ? SIGTERM : SIGKILL
            let rc = kill(e.pid, sig)
            let err = errno
            if rc != 0 && err == EPERM {
                pending = PortsPendingKill(entry: e, stage: .admin)
                return
            }
            if rc != 0 && err != ESRCH {
                ToolsToastCenter.shared.show("Could not stop \(e.command): \(String(cString: strerror(err)))", error: true)
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refresh()
            if entries.contains(where: { $0.pid == e.pid }) {
                if p.stage == .terminate {
                    pending = PortsPendingKill(entry: e, stage: .force)
                } else {
                    ToolsToastCenter.shared.show("\(e.command) is still running.", error: true)
                }
            } else {
                ToolsToastCenter.shared.show("Stopped \(e.command) (port \(e.port))")
            }
        case .admin:
            let r = await ToolsAdmin.run("/bin/kill", ["-9", String(e.pid)], prompt: "MacMaster needs administrator access to stop \(e.command).")
            if r.ok {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await refresh()
                ToolsToastCenter.shared.show("Stopped \(e.command) (port \(e.port))")
            } else if !ToolsAdmin.isCancelled(r) {
                ToolsToastCenter.shared.show("Could not stop \(e.command): \(r.stderr)", error: true)
            }
        }
    }
}

// MARK: - View

struct ToolsPortsView: View {
    @State private var model = PortsModel()
    @State private var query = ""

    private var shown: [PortEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter { e in
            String(e.port).contains(q) || e.command.lowercased().contains(q) || String(e.pid) == q
                || e.user.lowercased().contains(q) || (PortsParser.label(forPort: e.port)?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task(id: model.autoRefresh) {
            // Refreshes only while this view is on screen; the task is cancelled when it goes away.
            await model.refresh()
            while model.autoRefresh && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await model.refresh()
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
                            titleVisibility: .visible, presenting: model.pending) { p in
            Button(confirmLabel(p), role: .destructive) { Task { await model.confirm(p) } }
            Button("Cancel", role: .cancel) { model.pending = nil }
        } message: { p in Text(dialogMessage(p)) }
    }

    private var dialogTitle: String {
        guard let p = model.pending else { return "" }
        switch p.stage {
        case .terminate: return "Stop \(p.entry.command)?"
        case .force: return "\(p.entry.command) did not quit"
        case .admin: return "Administrator needed"
        }
    }

    private func confirmLabel(_ p: PortsPendingKill) -> String {
        switch p.stage {
        case .terminate: "Stop"
        case .force: "Force quit"
        case .admin: "Force quit as administrator"
        }
    }

    private func dialogMessage(_ p: PortsPendingKill) -> String {
        let e = p.entry
        switch p.stage {
        case .terminate: return "It uses port \(e.port) (pid \(e.pid)). The program is asked to quit. Unsaved work in it may be lost."
        case .force: return "Force quit ends it immediately. Unsaved work in it will be lost."
        case .admin: return "\(e.command) runs as \(e.user.isEmpty ? "another user" : e.user). Stopping it needs your administrator password and ends it immediately."
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search port, app or user", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 300)

            Toggle("UDP", isOn: $model.includeUDP).toggleStyle(.checkbox)
            Toggle("Auto refresh", isOn: $model.autoRefresh).toggleStyle(.checkbox)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .font(.callout)
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 10)
    }

    // MARK: Rows

    @ViewBuilder private var content: some View {
        if let err = model.error {
            ToolsEmptyHint(symbol: "exclamationmark.triangle", text: err)
            Spacer()
        } else if !model.hasLoaded {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if shown.isEmpty {
            ToolsEmptyHint(symbol: "network.slash",
                           text: query.isEmpty ? "Nothing is listening on a port." : "No ports match \"\(query)\".")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { e in
                        row(e)
                        Divider().padding(.leading, Theme.pagePadding)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(Fmt.count(shown.count, "port")) in use")
                let exposed = shown.filter(\.isExposed).count
                if exposed > 0 { Text("· \(exposed) reachable from the network").foregroundStyle(.orange) }
                Spacer()
                if let u = model.updated { Text("Updated \(u.formatted(date: .omitted, time: .standard))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 8)
        }
    }

    private func row(_ e: PortEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(e.port)).font(.system(.title3, design: .monospaced).weight(.semibold))
                if let l = PortsParser.label(forPort: e.port) {
                    Text(l).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 96, alignment: .leading)

            Image(nsImage: model.icon(for: e)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.command).font(.callout.weight(.medium)).lineLimit(1)
                Text("pid \(e.pid) · \(e.user.isEmpty ? "uid \(e.uid)" : e.user)\(model.ownedByMe(e) ? "" : " · admin needed to stop")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)

            Text(e.proto).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
            if e.isExposed {
                Label(e.addressSummary == "All interfaces" ? "Exposed to network" : "Exposed: \(e.addressSummary)", systemImage: "wifi")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("Other devices on your network can reach this port.")
            } else {
                Text("localhost").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 2) {
                if PortsParser.likelyHTTP(e) {
                    Button { model.open(e) } label: { Image(systemName: "safari") }.help("Open http://localhost:\(e.port)")
                }
                Button { model.copy(e) } label: { Image(systemName: "doc.on.doc") }.help("Copy localhost:\(e.port)")
                Button { model.reveal(e) } label: { Image(systemName: "folder") }.help("Reveal program in Finder")
                Button(role: .destructive) { model.requestKill(e) } label: { Image(systemName: "xmark.octagon") }
                    .help("Stop this process").disabled(!model.canKill(e))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if PortsParser.likelyHTTP(e) { Button("Open in browser") { model.open(e) } }
            Button("Copy localhost:\(e.port)") { model.copy(e) }
            Button("Reveal program in Finder") { model.reveal(e) }
            Divider()
            Button("Stop…", role: .destructive) { model.requestKill(e) }.disabled(!model.canKill(e))
        }
    }
}
