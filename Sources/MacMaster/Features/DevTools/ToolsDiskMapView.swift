import SwiftUI
import AppKit
import Observation

// MARK: - Model

/// One drawn block of the treemap.
struct DiskTile: Identifiable {
    let node: DiskNode
    let rect: CGRect
    var id: UUID { node.id }
}

@Observable
@MainActor
final class DiskMapModel {
    var target: URL = AppPaths.home
    private(set) var root: DiskNode?
    private(set) var current: DiskNode?
    private(set) var isScanning = false
    private(set) var files = 0
    private(set) var bytes: Int64 = 0
    private(set) var unreadable = 0
    private(set) var currentPath = ""
    private(set) var message: String?
    /// Bumped whenever the tree changes (scan finished, item trashed) so views and the layout cache refresh.
    private(set) var revision = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var counters = DiskScanCounters()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cacheKey = ""
    @ObservationIgnored private var cacheTiles: [DiskTile] = []

    var isWholeDisk: Bool { target.path == "/" }
    var targetTitle: String {
        if isWholeDisk { return "Whole disk" }
        if target.path == AppPaths.home.path { return "Home folder" }
        return (target.path as NSString).abbreviatingWithTildeInPath
    }

    func chooseFolder() {
        if let u = ToolsPicker.chooseFolder(start: target, message: "Choose a folder to map") { target = u }
    }

    func scan() {
        task?.cancel()
        generation += 1
        let gen = generation
        let c = DiskScanCounters()
        counters = c
        root = nil; current = nil; message = nil
        files = 0; bytes = 0; unreadable = 0; currentPath = ""
        isScanning = true
        revision += 1
        let url = target
        task = Task { [weak self] in
            let inner = Task.detached(priority: .userInitiated) { await DiskMapScanner.scan(root: url, counters: c) }
            let result = await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.pollProgress()
            self.isScanning = false
            if let r = result {
                self.root = r; self.current = r
                if r.size == 0 { self.message = "Nothing readable here. Try Full Disk Access or another folder." }
            } else {
                self.message = "Could not read this folder."
            }
            self.revision += 1
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        isScanning = false
        message = "Scan stopped."
    }

    /// Drops the tree and everything cached from it.
    func release() {
        generation += 1
        task?.cancel()
        isScanning = false
        root = nil; current = nil; message = nil
        cacheKey = ""; cacheTiles = []
    }

    func pollProgress() {
        let s = counters.snapshot()
        files = s.files; bytes = s.bytes; unreadable = s.unreadable; currentPath = s.path
    }

    func drill(into node: DiskNode) {
        guard node.canDrill else { return }
        current = node
    }

    func go(to node: DiskNode) { current = node }

    func up() { if let p = current?.parent { current = p } }

    /// Laid-out tiles for the current folder, cached per folder, tree revision and size.
    func tiles(in size: CGSize) -> [DiskTile] {
        guard let cur = current, size.width > 4, size.height > 4 else { return [] }
        let key = "\(cur.id)|\(revision)|\(Int(size.width))x\(Int(size.height))"
        if key == cacheKey { return cacheTiles }
        let kids = cur.children.filter { $0.size > 0 }
        let rects = DiskMapTreemap.layout(kids.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
        cacheTiles = zip(kids, rects).filter { $0.1.width > 0.5 && $0.1.height > 0.5 }.map { DiskTile(node: $0.0, rect: $0.1) }
        cacheKey = key
        return cacheTiles
    }

    func canTrash(_ node: DiskNode) -> Bool {
        guard !node.isAggregate, !node.path.isEmpty, node !== root else { return false }
        let parts = node.path.split(separator: "/")
        if parts.count < 2 { return false }
        if node.path == AppPaths.home.path || node.path == AppPaths.home.appendingPathComponent("Library").path { return false }
        return true
    }

    func trash(_ node: DiskNode) {
        guard canTrash(node) else { return }
        let url = node.url
        let name = node.name
        let size = node.size
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) { AppPaths.trash(url) }.value
            if let error {
                ToolsToastCenter.shared.show("Could not trash \(name): \(error)", error: true)
                return
            }
            node.detach()
            revision += 1
            ToolsToastCenter.shared.show("Moved \(name) to Trash · \(Fmt.bytes(size))")
        }
    }
}

// MARK: - View

struct ToolsDiskMapView: View {
    @State private var model = DiskMapModel()
    @State private var hoverID: UUID?
    @State private var hoverPoint: CGPoint = .zero
    @State private var pendingTrash: DiskNode?
    @State private var fdaGranted = Permissions.isGranted(.fullDiskAccess)

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !fdaGranted && !model.isScanning {
                fdaNote
            }
            Divider()
            content
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let n = pendingTrash { model.trash(n) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { Text("You can restore it from the Trash.") }
        .task(id: model.isScanning) {
            // Progress polling runs only while a scan is active.
            while model.isScanning && !Task.isCancelled {
                model.pollProgress()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        .onAppear { fdaGranted = Permissions.isGranted(.fullDiskAccess) }
        .onDisappear { model.release() }
    }

    private var trashTitle: String {
        guard let n = pendingTrash else { return "Move to Trash?" }
        return "Move \(n.name) (\(Fmt.bytes(n.size))) to the Trash?"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Home folder") { model.target = AppPaths.home }
                Button("Whole disk") { model.target = URL(fileURLWithPath: "/") }
                let vols = mountedVolumes
                if !vols.isEmpty {
                    Divider()
                    ForEach(vols, id: \.self) { v in Button(v.lastPathComponent) { model.target = v } }
                }
                Divider()
                Button("Choose folder…") { model.chooseFolder() }
            } label: {
                Label(model.targetTitle, systemImage: model.isWholeDisk ? "internaldrive" : "folder")
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.isScanning)

            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("\(model.files.formatted()) files · \(Fmt.bytes(model.bytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { model.stop() }
            } else {
                Button { model.scan() } label: {
                    Label(model.root == nil ? "Scan" : "Rescan", systemImage: "magnifyingglass").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent).tint(ToolsTool.diskMap.colors[1])
            }
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 12)
    }

    private var mountedVolumes: [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path.hasPrefix("/Volumes/") && !$0.path.hasPrefix("/Volumes/Macintosh") }
    }

    private var fdaNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Without Full Disk Access some protected folders are skipped, so totals may be low.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Recheck") { fdaGranted = Permissions.isGranted(.fullDiskAccess) }
            Button("Grant access") { Permissions.request(.fullDiskAccess) }
        }
        .padding(.horizontal, Theme.pagePadding).padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.isScanning {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Scanning \((model.currentPath as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, Theme.pagePadding)
                Spacer()
            }.frame(maxWidth: .infinity)
        } else if let cur = model.current {
            VStack(spacing: 0) {
                breadcrumb(cur)
                Divider()
                HStack(spacing: 0) {
                    treemap(cur).padding(Theme.Space.m)
                    Divider()
                    sideList(cur).frame(width: 270)
                }
                Divider()
                footer(cur)
            }
        } else {
            VStack(spacing: 0) {
                ToolsEmptyHint(symbol: "square.grid.3x3.square",
                               text: model.message ?? "Pick a folder and scan.\nBlocks show what takes space. Click one to look inside.")
                Spacer()
            }
        }
    }

    private func breadcrumb(_ cur: DiskNode) -> some View {
        HStack(spacing: 4) {
            Button { model.up() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(cur.parent == nil).help("Up one level")
            ForEach(Array(cur.ancestry.enumerated()), id: \.element.id) { i, n in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                if n === cur {
                    Text(n.name).font(.callout.weight(.semibold)).lineLimit(1)
                } else {
                    Button(n.name) { model.go(to: n) }.buttonStyle(.borderless).font(.callout).lineLimit(1)
                }
            }
            Spacer()
            Text(Fmt.bytes(cur.size)).font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 8)
    }

    private func footer(_ cur: DiskNode) -> some View {
        HStack(spacing: 14) {
            Text("\(cur.fileCount.formatted()) files")
            if model.unreadable > 0 { Text("\(model.unreadable) folders could not be read") }
            Spacer()
            ForEach(DiskKind.allCases, id: \.self) { k in
                if kindPresent(k, in: cur) {
                    HStack(spacing: 4) {
                        Circle().fill(k.color).frame(width: 8, height: 8)
                        Text(k.title)
                    }
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Theme.pagePadding).padding(.vertical, 8)
    }

    private func kindPresent(_ k: DiskKind, in cur: DiskNode) -> Bool {
        cur.children.contains { $0.kind == k && !$0.isAggregate }
    }

    // MARK: Treemap

    private func treemap(_ cur: DiskNode) -> some View {
        GeometryReader { geo in
            let tiles = model.tiles(in: geo.size)
            let hovered = tiles.first { $0.id == hoverID }
            Canvas { ctx, size in
                for t in tiles { draw(t, hovered: t.id == hoverID, in: &ctx) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverPoint = p
                    let id = tiles.first { $0.rect.contains(p) }?.id
                    if id != hoverID { hoverID = id }
                case .ended:
                    hoverID = nil
                }
            }
            .onTapGesture { location in
                if let t = tiles.first(where: { $0.rect.contains(location) }) { model.drill(into: t.node) }
            }
            .contextMenu {
                if let n = hovered?.node { nodeMenu(n) }
            }
            .overlay(alignment: .topLeading) {
                if let h = hovered {
                    tooltip(h.node, total: cur.size)
                        .offset(x: min(hoverPoint.x + 14, max(0, geo.size.width - 210)),
                                y: min(hoverPoint.y + 18, max(0, geo.size.height - 70)))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func draw(_ t: DiskTile, hovered: Bool, in ctx: inout GraphicsContext) {
        let r = t.rect.insetBy(dx: 1, dy: 1)
        guard r.width > 1, r.height > 1 else { return }
        let base = t.node.isAggregate ? Color.gray : t.node.kind.color
        let shape = Path(roundedRect: r, cornerRadius: 3, style: .continuous)
        ctx.fill(shape, with: .linearGradient(
            Gradient(colors: [base.opacity(hovered ? 1 : 0.92), base.opacity(hovered ? 0.85 : 0.68)]),
            startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        if hovered { ctx.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 2) }
        guard r.width > 54, r.height > 30 else { return }
        var inner = ctx
        inner.clip(to: Path(r.insetBy(dx: 4, dy: 3)))
        let title = Text(t.node.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
        inner.draw(inner.resolve(title), at: CGPoint(x: r.minX + 6, y: r.minY + 5), anchor: .topLeading)
        if r.height > 46 {
            let sub = Text(Fmt.bytes(t.node.size)).font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
            inner.draw(inner.resolve(sub), at: CGPoint(x: r.minX + 6, y: r.minY + 20), anchor: .topLeading)
        }
    }

    private func tooltip(_ n: DiskNode, total: Int64) -> some View {
        let pct = total > 0 ? Double(n.size) / Double(total) * 100 : 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(n.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(Fmt.bytes(n.size)) · \(pct < 0.1 ? "<0.1" : String(format: "%.1f", pct))%").font(.caption).monospacedDigit()
            if n.isDirectory && !n.isAggregate {
                Text(n.canDrill ? "\(n.fileCount.formatted()) files · click to open" : "\(n.fileCount.formatted()) files")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(radius: 4, y: 2)
    }

    // MARK: Side list

    private func sideList(_ cur: DiskNode) -> some View {
        let items = Array(cur.children.prefix(60))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Largest in this folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            if items.isEmpty {
                Text("Nothing large here.").font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { n in sideRow(n, total: cur.size) }
                }
            }
        }
    }

    private func sideRow(_ n: DiskNode, total: Int64) -> some View {
        let frac = total > 0 ? Double(n.size) / Double(total) : 0
        return Button {
            model.drill(into: n)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: n.isAggregate ? "ellipsis.circle.fill" : n.kind.symbol)
                    .foregroundStyle(n.isAggregate ? Color.gray : n.kind.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    CapsuleBar(fraction: frac, color: n.isAggregate ? .gray : n.kind.color, height: 4)
                }
                Text(Fmt.bytes(n.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(hoverID == n.id ? Color.primary.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoverID = n.id } else if hoverID == n.id { hoverID = nil }
        }
        .contextMenu { nodeMenu(n) }
    }

    @ViewBuilder private func nodeMenu(_ n: DiskNode) -> some View {
        if n.canDrill { Button("Open") { model.drill(into: n) } }
        if !n.isAggregate && !n.path.isEmpty {
            Button("Reveal in Finder") { toolsReveal([n.url]) }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(n.path, forType: .string)
            }
        }
        if model.canTrash(n) {
            Divider()
            Button("Move to Trash…", role: .destructive) { pendingTrash = n }
        }
    }
}
