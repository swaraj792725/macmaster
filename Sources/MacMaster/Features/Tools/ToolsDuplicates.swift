import SwiftUI
import AppKit
import CryptoKit
import Observation

struct ToolsDupFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: URL { url }
}

struct ToolsDupGroup: Identifiable, Sendable {
    let id = UUID()
    let size: Int64
    var files: [ToolsDupFile]
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

enum ToolsDuplicateScanner {
    struct Options: Sendable {
        var root: URL
        var minBytes: Int64
        var packagesAsFiles: Bool
        var includeHidden: Bool
    }

    /// Stage 1 (sync): enumerate and bucket regular files by size. Hard links to one inode count once.
    private static func bucketBySize(_ o: Options, progress: @Sendable (String) -> Void) -> [Int64: [ToolsDupFile]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !o.includeHidden { opts.insert(.skipsHiddenFiles) }
        if o.packagesAsFiles { opts.insert(.skipsPackageDescendants) }
        guard let e = FileManager.default.enumerator(at: o.root, includingPropertiesForKeys: keys, options: opts,
                                                     errorHandler: { _, _ in true }) else { return [:] }
        var buckets: [Int64: [ToolsDupFile]] = [:]
        var seen = Set<AnyHashable>()
        var n = 0
        let libraryPath = AppPaths.home.appendingPathComponent("Library").path
        while let url = e.nextObject() as? URL {
            if Task.isCancelled { break }
            if !o.includeHidden && url.path == libraryPath { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                  let size = v.fileSize, Int64(size) >= o.minBytes, size > 0 else { continue }
            if let ident = v.fileResourceIdentifier as? AnyHashable {
                if !seen.insert(ident).inserted { continue }
            }
            buckets[Int64(size), default: []].append(ToolsDupFile(url: url, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
            n += 1
            if n % 1000 == 0 { progress("Indexed \(n) files…") }
        }
        return buckets.filter { $0.value.count > 1 }
    }

    /// Hash of the first `limit` bytes (nil = whole file), read in 1 MB chunks.
    static func hash(of url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            if Task.isCancelled { return nil }
            let chunk = autoreleasepool { () -> Data? in
                try? h.read(upToCount: min(1_048_576, remaining))
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashAll(_ files: [ToolsDupFile], limit: Int?, progress: @Sendable (Int) -> Void) async -> [(ToolsDupFile, String)] {
        await withTaskGroup(of: (ToolsDupFile, String?).self) { group in
            var it = files.makeIterator()
            var out: [(ToolsDupFile, String)] = []
            var done = 0
            for _ in 0..<4 { if let f = it.next() { group.addTask { (f, hash(of: f.url, limit: limit)) } } }
            while let r = await group.next() {
                if let h = r.1 { out.append((r.0, h)) }
                done += 1
                if done % 25 == 0 { progress(done) }
                if let f = it.next() { group.addTask { (f, hash(of: f.url, limit: limit)) } }
            }
            return out
        }
    }

    static func scan(_ o: Options, progress: @escaping @Sendable (String) -> Void) async -> [ToolsDupGroup] {
        // Task.detached doesn't inherit cancellation, so forward it explicitly.
        let walk = Task.detached(priority: .userInitiated) { bucketBySize(o, progress: progress) }
        let buckets = await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
        let total = buckets.values.reduce(0) { $0 + $1.count }
        if total == 0 || Task.isCancelled { return [] }

        // Stage 2: hash the first 64 KB of every same-size candidate.
        progress("Comparing \(total) candidates…")
        let candidates = buckets.values.flatMap { $0 }
        let partial = await hashAll(candidates, limit: 65_536) { progress("Comparing start of files: \($0) of \(total)") }
        var byPartial: [String: [ToolsDupFile]] = [:]
        for (f, h) in partial { byPartial["\(f.size)-\(h)", default: []].append(f) }
        let ties = byPartial.values.filter { $0.count > 1 }

        // Stage 3: full hash only where the size is larger than the partial window.
        var groups: [ToolsDupGroup] = []
        var fullNeeded: [ToolsDupFile] = []
        for g in ties {
            if g[0].size <= 65_536 { groups.append(ToolsDupGroup(size: g[0].size, files: g)) } else { fullNeeded += g }
        }
        if !fullNeeded.isEmpty && !Task.isCancelled {
            let count = fullNeeded.count
            let full = await hashAll(fullNeeded, limit: nil) { progress("Verifying full contents: \($0) of \(count)") }
            var byFull: [String: [ToolsDupFile]] = [:]
            for (f, h) in full { byFull["\(f.size)-\(h)", default: []].append(f) }
            for g in byFull.values where g.count > 1 { groups.append(ToolsDupGroup(size: g[0].size, files: g)) }
        }
        return groups.map { var g = $0; g.files.sort { $0.modified < $1.modified }; return g }
            .sorted { $0.wasted > $1.wasted }
    }
}

@Observable
@MainActor
final class ToolsDuplicatesModel {
    static let shared = ToolsDuplicatesModel()

    var folder: URL = AppPaths.home.appendingPathComponent("Documents")
    var minSizeKB: Double = 100
    var packagesAsFiles = true
    var includeHidden = false
    var keepOldest = true

    private(set) var groups: [ToolsDupGroup] = []
    var selected: Set<URL> = []
    private(set) var isScanning = false
    private(set) var status = ""
    private(set) var hasScanned = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped on every scan/stop so late results from an older scan are dropped.
    @ObservationIgnored private var generation = 0

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedBytes: Int64 { groups.flatMap(\.files).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func chooseFolder() {
        if let u = ToolsPicker.chooseFolder(start: folder, message: "Choose a folder to search for duplicates") { folder = u }
    }

    func scan() {
        task?.cancel()
        groups = []; selected = []; isScanning = true; hasScanned = true; status = "Indexing files…"
        let o = ToolsDuplicateScanner.Options(root: folder, minBytes: Int64(minSizeKB * 1024),
                                              packagesAsFiles: packagesAsFiles, includeHidden: includeHidden)
        generation += 1
        let gen = generation
        task = Task {
            let result = await ToolsDuplicateScanner.scan(o) { s in
                Task { @MainActor in
                    let m = ToolsDuplicatesModel.shared
                    if m.generation == gen { m.status = s }
                }
            }
            guard generation == gen else { return }
            if !Task.isCancelled {
                groups = result
                autoSelect()
            }
            isScanning = false
        }
    }

    func stop() { generation += 1; task?.cancel(); isScanning = false }

    /// Selects everything except one copy per group (oldest or newest).
    func autoSelect() {
        selected = []
        for g in groups {
            let keep = keepOldest ? g.files.first : g.files.last
            for f in g.files where f.url != keep?.url { selected.insert(f.url) }
        }
    }

    func clearSelection() { selected = [] }

    func toggle(_ file: ToolsDupFile, in group: ToolsDupGroup) {
        if selected.contains(file.url) { selected.remove(file.url); return }
        let selectedInGroup = group.files.filter { selected.contains($0.url) }.count
        if selectedInGroup + 1 >= group.files.count {
            ToolsToastCenter.shared.show("Keep at least one copy in each group", error: true)
            return
        }
        selected.insert(file.url)
    }

    func trashSelected() {
        let files = groups.flatMap(\.files).filter { selected.contains($0.url) }
        Task {
            let failed: [String] = await Task.detached {
                files.compactMap { AppPaths.trash($0.url) == nil ? nil : $0.url.lastPathComponent }
            }.value
            let gone = Set(files.map(\.url)).filter { !FileManager.default.fileExists(atPath: $0.path) }
            groups = groups.compactMap { g in
                var g = g
                g.files.removeAll { gone.contains($0.url) }
                return g.files.count > 1 ? g : nil
            }
            selected.subtract(gone)
            let freed = files.filter { gone.contains($0.url) }.reduce(Int64(0)) { $0 + $1.size }
            if failed.isEmpty {
                ToolsToastCenter.shared.show("Moved \(gone.count) duplicate\(gone.count == 1 ? "" : "s") to Trash · \(Fmt.bytes(freed))")
            } else {
                ToolsToastCenter.shared.show("Could not trash: " + failed.prefix(3).joined(separator: ", "), error: true)
            }
        }
    }
}

struct ToolsDuplicatesView: View {
    private let model = ToolsDuplicatesModel.shared
    @State private var confirm = false
    private let maxGroups = 250

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { model.chooseFolder() } label: { Label((model.folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder") }
                    Spacer()
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("Stop") { model.stop() }
                    } else {
                        Button { model.scan() } label: { Label("Find Duplicates", systemImage: "magnifyingglass") }
                            .buttonStyle(.borderedProminent).tint(ToolsTool.duplicates.colors[1])
                    }
                }
                HStack(spacing: 16) {
                    Picker("Ignore files smaller than", selection: $m.minSizeKB) {
                        Text("1 KB").tag(1.0); Text("100 KB").tag(100.0); Text("1 MB").tag(1024.0); Text("10 MB").tag(10_240.0)
                    }
                    .frame(width: 270)
                    Toggle("Apps as single files", isOn: $m.packagesAsFiles).toggleStyle(.checkbox)
                    Toggle("Include hidden", isOn: $m.includeHidden).toggleStyle(.checkbox)
                }
                .font(.callout)
            }
            .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
            Divider()

            if !model.hasScanned {
                ToolsEmptyHint(symbol: "square.on.square", text: "Duplicates are matched by size, then by the first 64 KB, then by a full SHA-256 hash — so only truly identical files are listed.")
                Spacer()
            } else if model.groups.isEmpty && !model.isScanning {
                ToolsEmptyHint(symbol: "checkmark.circle", text: "No duplicates found.")
                Spacer()
            } else {
                summaryBar
                Divider()
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.groups.prefix(maxGroups)) { g in ToolsDupGroupCard(group: g) }
                        if model.groups.count > maxGroups {
                            Text("Showing the \(maxGroups) groups with the most wasted space.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Theme.pagePadding)
                }
            }
        }
        .confirmationDialog("Move \(model.selected.count) duplicate file\(model.selected.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash (\(Fmt.bytes(model.selectedBytes)))", role: .destructive) { model.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("One copy of each file is always kept. You can restore items from the Trash.") }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Text("\(model.groups.count) groups · \(Fmt.bytes(model.wasted)) reclaimable").foregroundStyle(.secondary)
            Spacer()
            Picker("Keep", selection: Binding(get: { model.keepOldest }, set: { model.keepOldest = $0; model.autoSelect() })) {
                Text("Oldest").tag(true); Text("Newest").tag(false)
            }
            .pickerStyle(.segmented).frame(width: 190)
            Button("Clear") { model.clearSelection() }.disabled(model.selected.isEmpty)
            Button(role: .destructive) { confirm = true } label: {
                Label("Trash \(model.selected.count) (\(Fmt.bytes(model.selectedBytes)))", systemImage: "trash")
            }
            .disabled(model.selected.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 10)
    }
}

private struct ToolsDupGroupCard: View {
    let group: ToolsDupGroup
    private let model = ToolsDuplicatesModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files.first?.url.path ?? "")).resizable().frame(width: 22, height: 22)
                Text(group.files.first?.url.lastPathComponent ?? "").font(.headline).lineLimit(1)
                Spacer()
                Text("\(group.files.count) copies · \(Fmt.bytes(group.size)) each").font(.caption).foregroundStyle(.secondary)
                StatusPill(text: "\(Fmt.bytes(group.wasted)) wasted", color: .orange)
            }
            ForEach(group.files) { f in
                HStack(spacing: 10) {
                    ToolsDupCheck(on: model.selected.contains(f.url)) { model.toggle(f, in: group) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(f.url.lastPathComponent).font(.callout).lineLimit(1)
                        Text((f.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(f.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Button { ToolsQuickLook.shared.show([f.url]) } label: { Image(systemName: "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Quick Look")
                    Button { toolsReveal([f.url]) } label: { Image(systemName: "magnifyingglass.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                }
                .padding(.leading, 2)
            }
        }
        .card()
    }
}

private struct ToolsDupCheck: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 17))
                .foregroundStyle(on ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(on ? "Will be moved to Trash" : "Kept")
    }
}
