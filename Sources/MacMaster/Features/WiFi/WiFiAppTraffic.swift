import SwiftUI
import AppKit
import Darwin
import Observation

// MARK: - Rows

struct WiFiAppTrafficRow: Identifiable, Equatable, Sendable {
    let id: String             // app bundle path, or process name
    var name: String
    var path: String?          // .app bundle, for the icon
    var pid: Int32
    var downRate = 0.0         // bytes/s
    var upRate = 0.0
    var totalDown: UInt64 = 0  // since the page opened
    var totalUp: UInt64 = 0
    var connections = 0
    var rate: Double { downRate + upRate }
    var total: UInt64 { totalDown + totalUp }
}

enum WiFiTrafficSource: String, Sendable {
    case nstat = "Live per-app bytes"
    case nettop = "Live per-app bytes (nettop)"
    case connections = "Connections per app"
    var hasBytes: Bool { self != .connections }
}

// MARK: - Process naming

enum WiFiProcessNames {
    /// Outermost `.app` bundle of a running process, so helpers roll up into their app ("Chrome Helper" → "Google Chrome").
    static func appBundle(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    static func displayName(bundle: String) -> String {
        let n = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
        return Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? n
    }
}

// MARK: - NetworkStatistics (private framework)

/// Per-process byte counters from the private NetworkStatistics framework (what `nettop` is built on).
/// Verified from an unsigned process on macOS 27: each TCP/UDP source reports `processName`, `processID`, `rxBytes`, `txBytes`.
/// Everything is resolved with dlsym; if anything is missing `start` returns false and the caller falls back.
final class WiFiNStatSampler: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void) -> UnsafeMutableRawPointer?
    private typealias AddAll = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias SetDesc = @convention(c) (UnsafeRawPointer, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias SetRemoved = @convention(c) (UnsafeRawPointer, @escaping @convention(block) () -> Void) -> Void
    private typealias Query = @convention(c) (UnsafeMutableRawPointer, @escaping @convention(block) () -> Void) -> Void
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct Entry { var pid: Int32; var name: String; var rx: UInt64; var tx: UInt64 }

    private let queue = DispatchQueue(label: "macmaster.wifi.nstat", qos: .utility)
    private var manager: UnsafeMutableRawPointer?
    private var destroy: Destroy?
    private var query: Query?
    private var timer: DispatchSourceTimer?
    private var sources: [Int: Entry] = [:]      // latest counters per socket
    private var previous: [Int: Entry] = [:]     // counters at the last sample
    private var primed = false
    private var lastSample = Date()
    private var totals: [String: (down: UInt64, up: UInt64)] = [:]
    private var bundles: [Int32: String?] = [:]
    private var onRows: (@Sendable ([WiFiAppTrafficRow]) -> Void)?

    /// Returns false when the private API isn't usable here.
    func start(interval: TimeInterval, onRows: @escaping @Sendable ([WiFiAppTrafficRow]) -> Void) -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW),
              let c = dlsym(h, "NStatManagerCreate"), let t = dlsym(h, "NStatManagerAddAllTCP"),
              let u = dlsym(h, "NStatManagerAddAllUDP"), let d = dlsym(h, "NStatSourceSetDescriptionBlock"),
              let r = dlsym(h, "NStatSourceSetRemovedBlock"), let q = dlsym(h, "NStatManagerQueryAllSourcesDescriptions"),
              let x = dlsym(h, "NStatManagerDestroy") else { return false }
        let create = unsafeBitCast(c, to: Create.self), addTCP = unsafeBitCast(t, to: AddAll.self)
        let addUDP = unsafeBitCast(u, to: AddAll.self), setDesc = unsafeBitCast(d, to: SetDesc.self)
        let setRemoved = unsafeBitCast(r, to: SetRemoved.self)
        query = unsafeBitCast(q, to: Query.self); destroy = unsafeBitCast(x, to: Destroy.self)
        self.onRows = onRows
        lastSample = Date(); primed = false
        guard let m = create(nil, queue, { [unowned self] src, _ in
            guard let src else { return }
            let key = Int(bitPattern: src)
            setDesc(src) { [unowned self] dict in
                guard let dict = dict as? [String: Any] else { return }
                let pid = (dict["processID"] as? NSNumber)?.int32Value ?? 0
                let name = dict["processName"] as? String ?? "?"
                let rx = (dict["rxBytes"] as? NSNumber)?.uint64Value ?? 0
                let tx = (dict["txBytes"] as? NSNumber)?.uint64Value ?? 0
                // Skip loopback-only traffic (interface index 1): it isn't network usage.
                if (dict["interface"] as? NSNumber)?.intValue == 1 { return }
                self.sources[key] = Entry(pid: pid, name: name, rx: rx, tx: tx)
            }
            setRemoved(src) { [unowned self] in
                // Keep the final counters in `previous` so the next sample still sees the last delta.
                if let e = self.sources.removeValue(forKey: key) { self.finished.append((key, e)) }
            }
        }) else { return false }
        manager = m
        _ = addTCP(m); _ = addUDP(m)
        let tm = DispatchSource.makeTimerSource(queue: queue)
        tm.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(300))
        tm.setEventHandler { [unowned self] in self.sample() }
        timer = tm
        tm.resume()
        return true
    }

    private var finished: [(Int, Entry)] = []

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            if let m = manager { destroy?(m) }
            manager = nil; onRows = nil
            sources = [:]; previous = [:]; finished = []; totals = [:]; bundles = [:]
        }
    }

    private func sample() {
        guard let m = manager, let query else { return }
        query(m) { [unowned self] in self.finishSample() }
    }

    private func finishSample() {
        let now = Date()
        let dt = max(0.2, now.timeIntervalSince(lastSample))
        lastSample = now
        var down: [String: Double] = [:], up: [String: Double] = [:], pids: [String: Int32] = [:]
        var names: [String: String] = [:], paths: [String: String?] = [:]
        func add(_ key: Int, _ e: Entry) {
            let prev = previous[key]
            // A socket we haven't seen before counts in full, except on the very first sample (unknown baseline).
            let dRx = primed ? (e.rx >= (prev?.rx ?? 0) ? e.rx - (prev?.rx ?? 0) : 0) : 0
            let dTx = primed ? (e.tx >= (prev?.tx ?? 0) ? e.tx - (prev?.tx ?? 0) : 0) : 0
            guard dRx > 0 || dTx > 0 || prev == nil else { return }
            let bundle = bundleFor(e.pid)
            let id = bundle ?? e.name
            names[id] = bundle.map(WiFiProcessNames.displayName(bundle:)) ?? e.name
            paths[id] = bundle
            pids[id] = pids[id] ?? e.pid
            down[id, default: 0] += Double(dRx) / dt
            up[id, default: 0] += Double(dTx) / dt
            var t = totals[id] ?? (0, 0); t.down += dRx; t.up += dTx; totals[id] = t
        }
        for (k, e) in sources { add(k, e) }
        for (k, e) in finished { add(k, e) }
        finished.removeAll()
        previous = sources
        primed = true
        if bundles.count > 2000 { bundles = [:] }
        let rows = totals.keys.map { id -> WiFiAppTrafficRow in
            var r = WiFiAppTrafficRow(id: id, name: names[id] ?? id, path: (paths[id] ?? nil), pid: pids[id] ?? 0)
            r.downRate = down[id] ?? 0; r.upRate = up[id] ?? 0
            r.totalDown = totals[id]?.down ?? 0; r.totalUp = totals[id]?.up ?? 0
            return r
        }
        onRows?(rows)
    }

    private func bundleFor(_ pid: Int32) -> String? {
        if let b = bundles[pid] { return b }
        let b = WiFiProcessNames.appBundle(pid: pid)
        bundles[pid] = b
        return b
    }
}

// MARK: - Fallbacks

extension WiFiTools {
    /// Per-process bytes over ~1 s from `nettop` (second sample is the delta). Blocks for about a second.
    static func nettopRates() -> [WiFiAppTrafficRow]? {
        let r = Shell.run("/usr/bin/nettop", ["-P", "-L", "2", "-s", "1", "-d", "-x", "-J", "bytes_in,bytes_out"], timeout: 6)
        guard r.ok else { return nil }
        var rows: [String: WiFiAppTrafficRow] = [:]
        var header = 0
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix(",bytes_in") { header += 1; continue }
            guard header >= 2 else { continue }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = Int32(f[0][f[0].index(after: dot)...]),
                  let rx = Double(f[1]), let tx = Double(f[2]) else { continue }
            let bundle = WiFiProcessNames.appBundle(pid: pid)
            let proc = String(f[0][..<dot])
            let id = bundle ?? proc
            var row = rows[id] ?? WiFiAppTrafficRow(id: id, name: bundle.map(WiFiProcessNames.displayName(bundle:)) ?? proc, path: bundle, pid: pid)
            row.downRate += rx; row.upRate += tx
            rows[id] = row
        }
        return rows.isEmpty ? nil : Array(rows.values)
    }

    /// Established TCP connections per app, via libproc. Works anywhere, but says nothing about volume.
    static func connectionsByProcess() -> [WiFiAppTrafficRow] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var rows: [String: WiFiAppTrafficRow] = [:]
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            var mine = 0
            for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP),
                      info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
                mine += 1
            }
            guard mine > 0 else { continue }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let proc = String(cString: nameBuf)
            let bundle = WiFiProcessNames.appBundle(pid: pid)
            let id = bundle ?? proc
            var row = rows[id] ?? WiFiAppTrafficRow(id: id, name: bundle.map(WiFiProcessNames.displayName(bundle:)) ?? proc, path: bundle, pid: pid)
            row.connections += mine
            rows[id] = row
        }
        return rows.values.sorted { $0.connections > $1.connections }
    }
}

// MARK: - Model

/// Top apps by network use. Samples only between `begin()` and `end()` (while a Wi-Fi surface shows the card).
@Observable
@MainActor
final class WiFiAppTrafficModel {
    static let shared = WiFiAppTrafficModel()

    private(set) var rows: [WiFiAppTrafficRow] = []
    private(set) var source: WiFiTrafficSource = .nstat
    private(set) var ready = false

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var sampler: WiFiNStatSampler?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nettopTotals: [String: (UInt64, UInt64)] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    private init() {}

    func begin() {
        users += 1
        guard users == 1 else { return }
        rows = []; ready = false; nettopTotals = [:]
        startNStat()
    }

    func end() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        sampler?.stop(); sampler = nil
        task?.cancel(); task = nil
    }

    private func startNStat() {
        let s = WiFiNStatSampler()
        let ok = s.start(interval: 2) { list in
            Task { @MainActor in WiFiAppTrafficModel.shared.received(list) }
        }
        if ok {
            sampler = s; source = .nstat
            // If it never produces anything within a few seconds, drop to nettop.
            task = Task {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled, !ready { sampler?.stop(); sampler = nil; startPolling() }
            }
        } else {
            startPolling()
        }
    }

    /// nettop first (bytes), connection counts when even that isn't available.
    private func startPolling() {
        task?.cancel()
        task = Task { [weak self] in
            var useNettop = true
            while !Task.isCancelled {
                if useNettop {
                    let list = await Task.detached(priority: .utility) { WiFiTools.nettopRates() }.value
                    if let list { self?.receivedNettop(list) } else { useNettop = false }
                } else {
                    let list = await Task.detached(priority: .utility) { WiFiTools.connectionsByProcess() }.value
                    self?.receivedConnections(list)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func received(_ list: [WiFiAppTrafficRow]) {
        guard users > 0 else { return }
        ready = true
        rows = list.filter { $0.total > 0 || $0.rate > 0 }
            .sorted { ($0.rate, $0.total) > ($1.rate, $1.total) }
    }

    private func receivedNettop(_ list: [WiFiAppTrafficRow]) {
        guard users > 0 else { return }
        source = .nettop; ready = true
        var out = list
        for i in out.indices {
            var t = nettopTotals[out[i].id] ?? (0, 0)
            t.0 += UInt64(out[i].downRate); t.1 += UInt64(out[i].upRate)
            nettopTotals[out[i].id] = t
            out[i].totalDown = t.0; out[i].totalUp = t.1
        }
        rows = out.filter { $0.total > 0 }.sorted { ($0.rate, $0.total) > ($1.rate, $1.total) }
    }

    private func receivedConnections(_ list: [WiFiAppTrafficRow]) {
        guard users > 0 else { return }
        source = .connections; ready = true
        rows = list
    }

    func icon(for row: WiFiAppTrafficRow) -> NSImage? {
        guard let path = row.path else { return nil }
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 24, height: 24)
        icons[path] = i
        return i
    }
}

// MARK: - Card

struct WiFiAppTrafficCard: View {
    var limit = 5
    @State private var model = WiFiAppTrafficModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Color.accentColor)
                Text("Top apps by network").font(.headline)
                Spacer()
                if model.ready { Text(model.source == .connections ? "connections" : "now").font(.caption2).foregroundStyle(.tertiary) }
            }
            if !model.ready {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Measuring…").font(.callout).foregroundStyle(.secondary) }
            } else if model.rows.isEmpty {
                Text("Nothing is using the network right now.").font(.callout).foregroundStyle(.secondary)
            } else {
                let shown = Array(model.rows.prefix(limit))
                let peak = max(shown.map { model.source.hasBytes ? $0.rate : Double($0.connections) }.max() ?? 1, 1)
                ForEach(shown) { row in appRow(row, peak: peak) }
            }
            Text(footnote).font(.caption2).foregroundStyle(.tertiary)
        }
        .card()
        .onAppear { model.begin() }
        .onDisappear { model.end() }
    }

    private var footnote: String {
        switch model.source {
        case .nstat: "Measured from this Mac's network statistics while this is open. Totals count since you opened it."
        case .nettop: "Measured with nettop while this is open. Totals count since you opened it."
        case .connections: "Byte counters aren't available here, so this shows open connections per app."
        }
    }

    private func appRow(_ row: WiFiAppTrafficRow, peak: Double) -> some View {
        let value = model.source.hasBytes ? row.rate : Double(row.connections)
        return HStack(spacing: 10) {
            Group {
                if let icon = model.icon(for: row) { Image(nsImage: icon).resizable() }
                else { Image(systemName: "gearshape.2").foregroundStyle(.secondary) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 6)
                    if model.source.hasBytes {
                        Text("\u{2193} \(Fmt.rate(row.downRate))  \u{2191} \(Fmt.rate(row.upRate))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("\(row.connections)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(3, g.size.width * value / peak))
                    }
                }
                .frame(height: 4)
                if model.source.hasBytes, row.total > 0 {
                    Text("\(Fmt.bytes(row.total)) since opened").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
