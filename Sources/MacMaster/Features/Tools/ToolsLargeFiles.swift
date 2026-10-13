import SwiftUI
import AppKit
import Observation

struct ToolsFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    let kind: String
    let modified: Date
    var id: URL { url }
    var path: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

enum ToolsLargeFileScanner {
    struct Options: Sendable {
        var root: URL
        var minBytes: Int64
        var olderThan: Date?
        var packagesAsFiles: Bool
        var includeHiddenAndLibrary: Bool
    }

    private static let skipRootPaths = ["/System", "/Volumes", "/dev", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd", "/Library/Developer/CoreSimulator/Volumes"]

    /// Synchronous walk; call from a background task. Cooperative: honours Task cancellation.
    static func scan(_ o: Options, onBatch: @Sendable ([ToolsFileItem]) -> Void, onProgress: @Sendable (Int) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .isDirectoryKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
                                      .localizedTypeDescriptionKey]
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !o.includeHiddenAndLibrary { opts.insert(.skipsHiddenFiles) }
        if o.packagesAsFiles { opts.insert(.skipsPackageDescendants) }
        guard let e = FileManager.default.enumerator(at: o.root, includingPropertiesForKeys: keys, options: opts,
                                                     errorHandler: { _, _ in true }) else { return }
        let libraryPath = AppPaths.home.appendingPathComponent("Library").path
        let rootPath = o.root.standardizedFileURL.path
        let skips = skipRootPaths.filter { !(rootPath == $0 || rootPath.hasPrefix($0 + "/")) }
        let trashPath = AppPaths.home.appendingPathComponent(".Trash").path
        var batch: [ToolsFileItem] = []
        var scanned = 0
        var lastFlush = Date()

        while let url = e.nextObject() as? URL {
            if Task.isCancelled { break }
            let path = url.path
            if !o.includeHiddenAndLibrary && (path == libraryPath || path == trashPath) { e.skipDescendants(); continue }
            if skips.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            scanned += 1
            if scanned % 500 == 0 { onProgress(scanned) }

            var size: Int64 = 0
            if v.isRegularFile == true {
                size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            } else if v.isPackage == true && o.packagesAsFiles {
                size = AppPaths.allocatedSize(of: url)
            } else { continue }
            guard size >= o.minBytes else { continue }
            let modified = v.contentModificationDate ?? .distantPast
            if let cutoff = o.olderThan, modified > cutoff { continue }
            batch.append(ToolsFileItem(url: url, name: url.lastPathComponent, size: size,
                                       kind: v.localizedTypeDescription ?? "Document", modified: modified))
            if batch.count >= 20 || Date().timeIntervalSince(lastFlush) > 0.4 {
                onBatch(batch); batch = []; lastFlush = Date()
            }
        }
        if !batch.isEmpty { onBatch(batch) }
        onProgress(scanned)
    }
}

@Observable
@MainActor
final class ToolsLargeFilesModel {
    var folder: URL = AppPaths.home
    var minSizeMB: Double = 200
    var ageDays = 0
    var packagesAsFiles = true
    var includeHidden = false
    var sortOrder = [KeyPathComparator(\ToolsFileItem.size, order: .reverse)]
    var selection: Set<URL> = []

    private(set) var results: [ToolsFileItem] = []
    private(set) var isScanning = false
    private(set) var scanned = 0
    private(set) var hasScanned = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var totalSize: Int64 { results.reduce(0) { $0 + $1.size } }
    var selectedItems: [ToolsFileItem] { results.filter { selection.contains($0.url) } }

    func chooseFolder() {
        if let u = ToolsPicker.chooseFolder(start: folder, message: "Choose a folder to scan") { folder = u }
    }

    func scan() {
        task?.cancel()
        results = []; selection = []; scanned = 0; isScanning = true; hasScanned = true
        let o = ToolsLargeFileScanner.Options(
            root: folder, minBytes: Int64(minSizeMB) * 1_048_576,
            olderThan: ageDays > 0 ? Date().addingTimeInterval(-Double(ageDays) * 86_400) : nil,
            packagesAsFiles: packagesAsFiles, includeHiddenAndLibrary: includeHidden)
        let order = sortOrder
        task = Task {
            await Task.detached(priority: .userInitiated) {
                ToolsLargeFileScanner.scan(o, onBatch: { batch in
                    Task { @MainActor in
                        let m = ToolsLargeFilesModel.shared
                        m.results.append(contentsOf: batch)
                        m.results.sort(using: order)
                    }
                }, onProgress: { n in Task { @MainActor in ToolsLargeFilesModel.shared.scanned = n } })
            }.value
            isScanning = false
        }
    }

    func stop() { task?.cancel(); isScanning = false }

    func resort() { results.sort(using: sortOrder) }

    func trash(_ items: [ToolsFileItem]) {
        Task {
            let failed: [String] = await Task.detached {
                items.compactMap { AppPaths.trash($0.url) == nil ? nil : $0.name }
            }.value
            let gone = Set(items.map(\.url)).filter { !FileManager.default.fileExists(atPath: $0.path) }
            results.removeAll { gone.contains($0.url) }
            selection.subtract(gone)
            let freed = items.filter { gone.contains($0.url) }.reduce(Int64(0)) { $0 + $1.size }
            if failed.isEmpty {
                ToolsToastCenter.shared.show("Moved \(gone.count) item\(gone.count == 1 ? "" : "s") to Trash · \(Fmt.bytes(freed))")
            } else {
                ToolsToastCenter.shared.show("Could not trash: " + failed.prefix(3).joined(separator: ", "), error: true)
            }
        }
    }

    /// Single shared instance so scanner callbacks can reach the model.
    static let shared = ToolsLargeFilesModel()
}

struct ToolsLargeFilesView: View {
    private let model = ToolsLargeFilesModel.shared
    @State private var confirmTrash = false

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            controls(m: $m.minSizeMB, age: $m.ageDays, packages: $m.packagesAsFiles, hidden: $m.includeHidden)
            Divider()
            if !model.hasScanned {
                ToolsEmptyHint(symbol: "externaldrive.badge.minus", text: "Pick a folder and a minimum size, then scan.\nNothing is deleted until you choose Move to Trash.")
                Spacer()
            } else if model.results.isEmpty && !model.isScanning {
                ToolsEmptyHint(symbol: "checkmark.circle", text: "No files that large were found.")
                Spacer()
            } else {
                table($m.sortOrder, $m.selection)
                Divider()
                actionBar
            }
        }
        .confirmationDialog("Move \(model.selectedItems.count) item\(model.selectedItems.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash (\(Fmt.bytes(model.selectedItems.reduce(0) { $0 + $1.size })))", role: .destructive) {
                model.trash(model.selectedItems)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can restore them from the Trash.") }
    }

    private func controls(m: Binding<Double>, age: Binding<Int>, packages: Binding<Bool>, hidden: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { model.chooseFolder() } label: { Label((model.folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder") }
                    .lineLimit(1)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("\(model.scanned) scanned · \(model.results.count) found").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { model.stop() }
                } else {
                    Button { model.scan() } label: { Label("Scan", systemImage: "magnifyingglass").frame(minWidth: 60) }
                        .buttonStyle(.borderedProminent).tint(ToolsTool.largeFiles.colors[1])
                }
            }
            HStack(spacing: 16) {
                HStack {
                    Text("At least").foregroundStyle(.secondary)
                    Slider(value: m.snapped(50), in: 50...5000).frame(width: 200)
                    Text(m.wrappedValue >= 1000 ? String(format: "%.1f GB", m.wrappedValue / 1000) : "\(Int(m.wrappedValue)) MB")
                        .monospacedDigit().frame(width: 64, alignment: .leading)
                }
                Picker("Older than", selection: age) {
                    Text("Any age").tag(0); Text("30 days").tag(30); Text("90 days").tag(90)
                    Text("6 months").tag(180); Text("1 year").tag(365)
                }
                .frame(width: 190)
                Toggle("Apps as single files", isOn: packages).toggleStyle(.checkbox)
                Toggle("Include Library & hidden", isOn: hidden).toggleStyle(.checkbox)
            }
            .font(.callout)
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
    }

    private func table(_ order: Binding<[KeyPathComparator<ToolsFileItem>]>, _ selection: Binding<Set<URL>>) -> some View {
        Table(model.results, selection: selection, sortOrder: order) {
            TableColumn("Name", value: \.name) { f in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 18, height: 18)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Size", value: \.size) { f in Text(Fmt.bytes(f.size)).monospacedDigit() }.width(min: 70, ideal: 80, max: 110)
            TableColumn("Kind", value: \.kind) { f in Text(f.kind).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 120)
            TableColumn("Modified", value: \.modified) { f in
                Text(f.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }.width(min: 90, ideal: 110)
            TableColumn("Path", value: \.path) { f in
                Text(f.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Reveal in Finder") { toolsReveal(Array(urls)) }
            Button("Quick Look") { ToolsQuickLook.shared.show(Array(urls)) }
            Divider()
            Button("Move to Trash…", role: .destructive) { confirmTrash = true }
        } primaryAction: { urls in ToolsQuickLook.shared.show(Array(urls)) }
        .onChange(of: model.sortOrder) { _, _ in model.resort() }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("\(model.results.count) files · \(Fmt.bytes(model.totalSize))").foregroundStyle(.secondary)
            Spacer()
            let sel = model.selectedItems
            if !sel.isEmpty {
                Text("\(sel.count) selected · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))").font(.callout.weight(.medium))
            }
            Button("Reveal") { toolsReveal(sel.map(\.url)) }.disabled(sel.isEmpty)
            Button("Quick Look") { ToolsQuickLook.shared.show(sel.map(\.url)) }.disabled(sel.isEmpty)
            Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
                .disabled(sel.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 10)
    }
}
