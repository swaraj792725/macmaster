import SwiftUI
import AppKit
import Observation

// MARK: - Settings

enum CleanerProjectSettings {
    static let roots = "mm.cleaner.projects.roots"
    static let recentDays = "mm.cleaner.projects.recentDays"

    static let defaultRootNames = ["Developer", "Projects", "Documents", "Code", "src", "dev", "GitHub"]

    static func defaultRoots() -> [URL] {
        defaultRootNames.map { AppPaths.home.appendingPathComponent($0, isDirectory: true) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
    }

    static func parse(_ raw: String) -> [URL] {
        raw.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
    static func encode(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: "\n") }
}

// MARK: - Rules

/// What can be regenerated in a project, keyed by marker files that prove which kind of project it is.
struct CleanerProjectRule: Sendable {
    let kind: String
    /// Exact file names, or suffixes starting with "." (for example ".xcodeproj").
    let markers: [String]
    let junk: [String]
    let rebuild: String

    static let all: [CleanerProjectRule] = [
        .init(kind: "Node", markers: ["package.json"],
              junk: ["node_modules", ".next", ".nuxt", ".parcel-cache", ".turbo", ".svelte-kit", ".angular"], rebuild: "npm install"),
        .init(kind: "Rust", markers: ["Cargo.toml"], junk: ["target"], rebuild: "cargo build"),
        .init(kind: "Swift package", markers: ["Package.swift"], junk: [".build"], rebuild: "swift build"),
        .init(kind: "Xcode", markers: [".xcodeproj", ".xcworkspace"], junk: ["build", "DerivedData"], rebuild: "Build in Xcode"),
        .init(kind: "CocoaPods", markers: ["Podfile"], junk: ["Pods"], rebuild: "pod install"),
        .init(kind: "Carthage", markers: ["Cartfile"], junk: ["Carthage/Build"], rebuild: "carthage build"),
        .init(kind: "Flutter", markers: ["pubspec.yaml"], junk: [".dart_tool", "build"], rebuild: "flutter pub get"),
        .init(kind: "Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              junk: ["build", ".gradle"], rebuild: "gradle build"),
        .init(kind: "Maven", markers: ["pom.xml"], junk: ["target"], rebuild: "mvn package"),
        .init(kind: "Python", markers: ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile"],
              junk: ["venv", ".venv", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache"], rebuild: "Recreate the environment"),
        .init(kind: "PHP", markers: ["composer.json"], junk: ["vendor"], rebuild: "composer install"),
        .init(kind: "Ruby", markers: ["Gemfile"], junk: ["vendor/bundle"], rebuild: "bundle install"),
        .init(kind: "Elixir", markers: ["mix.exs"], junk: ["_build", "deps"], rebuild: "mix deps.get"),
    ]
}

struct CleanerProjectJunk: Hashable, Sendable {
    let url: URL
    let size: Int64
    var name: String { url.lastPathComponent }
}

struct CleanerProject: Identifiable, Hashable, Sendable {
    let url: URL
    let kinds: [String]
    let rebuild: [String]
    let junk: [CleanerProjectJunk]
    let lastModified: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var size: Int64 { junk.reduce(0) { $0 + $1.size } }
}

// MARK: - Scanner

enum CleanerProjectScanner {
    private struct Found { let url: URL; let kinds: [String]; let rebuild: [String]; let junk: [URL]; let modified: Date }

    /// Directories never entered while looking for projects.
    private static let skipNames: Set<String> = [
        "node_modules", "Library", ".Trash", "Pods", "DerivedData", ".build", "target", "venv", ".venv", "vendor",
        "__pycache__", "build", ".git", "Applications",
    ]
    static let maxDepth = 5
    static let maxDirs = 60_000

    /// Finds projects and measures their regenerable folders. Projects changed within `recentDays` are counted, not listed.
    static func scan(roots: [URL], recentDays: Int, progress: @escaping @Sendable (String) -> Void) async -> (projects: [CleanerProject], skippedRecent: Int) {
        let cutoff = Date().addingTimeInterval(-Double(recentDays) * 86_400)
        var found: [Found] = []
        var visited = 0
        for root in roots {
            if Task.isCancelled { break }
            walk(root, depth: 0, visited: &visited, found: &found, progress: progress)
        }
        var seen = Set<URL>()
        found = found.filter { seen.insert($0.url).inserted }
        let old = found.filter { $0.modified < cutoff }
        let skipped = found.count - old.count

        // Measure junk folders a few at a time.
        let jobs = old.flatMap { f in f.junk.map { (f.url, $0) } }
        var sizes: [URL: Int64] = [:]
        var done = 0
        await withTaskGroup(of: (URL, Int64).self) { group in
            var it = jobs.makeIterator()
            var running = 0
            while running < 4, let j = it.next() { group.addTask { (j.1, AppPaths.allocatedSize(of: j.1)) }; running += 1 }
            while let (u, s) = await group.next() {
                sizes[u] = s
                done += 1
                if done % 3 == 0 || done == jobs.count { progress("Measuring \(done) of \(jobs.count)") }
                if Task.isCancelled { continue }
                if let j = it.next() { group.addTask { (j.1, AppPaths.allocatedSize(of: j.1)) } }
            }
        }
        let projects = old.compactMap { f -> CleanerProject? in
            let junk = f.junk.compactMap { u -> CleanerProjectJunk? in
                let s = sizes[u] ?? 0
                return s > 0 ? CleanerProjectJunk(url: u, size: s) : nil
            }
            guard !junk.isEmpty else { return nil }
            return CleanerProject(url: f.url, kinds: f.kinds, rebuild: f.rebuild, junk: junk, lastModified: f.modified)
        }
        .sorted { $0.size > $1.size }
        return (projects, skipped)
    }

    private static func walk(_ dir: URL, depth: Int, visited: inout Int, found: inout [Found], progress: @Sendable (String) -> Void) {
        if Task.isCancelled || visited > maxDirs { return }
        visited += 1
        if visited % 400 == 0 { progress("Looking in \((dir.path as NSString).abbreviatingWithTildeInPath)") }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return }
        let names = Set(entries.map(\.lastPathComponent))

        var kinds: [String] = [], rebuild: [String] = [], junkNames: [String] = []
        for rule in CleanerProjectRule.all {
            let hit = rule.markers.contains { m in m.hasPrefix(".") && m != ".git" ? names.contains { $0.hasSuffix(m) } : names.contains(m) }
            guard hit else { continue }
            let existing = rule.junk.filter { j in
                let first = j.split(separator: "/").first.map(String.init) ?? j
                return names.contains(first) && isRealDirectory(dir.appendingPathComponent(j))
            }
            guard !existing.isEmpty else { continue }
            kinds.append(rule.kind); rebuild.append(rule.rebuild)
            for j in existing where !junkNames.contains(j) { junkNames.append(j) }
        }
        if !junkNames.isEmpty {
            let skipTop = Set(junkNames.map { $0.split(separator: "/").first.map(String.init) ?? $0 })
            var latest = Date.distantPast
            for e in entries where !skipTop.contains(e.lastPathComponent) {
                if let d = (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > latest { latest = d }
            }
            for g in [".git/index", ".git/HEAD"] {
                let u = dir.appendingPathComponent(g)
                if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > latest { latest = d }
            }
            if latest == .distantPast { latest = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date() }
            found.append(Found(url: dir, kinds: kinds, rebuild: rebuild, junk: junkNames.map { dir.appendingPathComponent($0, isDirectory: true) }, modified: latest))
        }
        guard depth < maxDepth else { return }
        let junkTop = Set(junkNames.map { $0.split(separator: "/").first.map(String.init) ?? $0 })
        for e in entries {
            let name = e.lastPathComponent
            if name.hasPrefix(".") || skipNames.contains(name) || junkTop.contains(name) { continue }
            guard let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            if (e.pathExtension == "app") || e.pathExtension == "photoslibrary" { continue }
            walk(e, depth: depth + 1, visited: &visited, found: &found, progress: progress)
        }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return v.isDirectory == true && v.isSymbolicLink != true
    }
}

// MARK: - Model

@Observable
@MainActor
final class CleanerProjectsModel {
    private(set) var projects: [CleanerProject] = []
    private(set) var skippedRecent = 0
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var progress = ""
    private(set) var isTrashing = false
    private(set) var status: String?
    private(set) var statusIsError = false
    var selection: Set<URL> = []

    private(set) var simctlAvailable = false
    private(set) var isDeletingSims = false
    private(set) var dockerBytes: Int64?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastProgressAt = Date.distantPast

    var selectedProjects: [CleanerProject] { projects.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedProjects.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { projects.reduce(0) { $0 + $1.size } }

    func scan(roots: [URL], recentDays: Int) {
        task?.cancel()
        generation += 1
        let gen = generation
        isScanning = true; hasScanned = true; status = nil; progress = "Looking for projects…"
        projects = []; selection = []; skippedRecent = 0
        task = Task { [weak self] in
            let inner = Task.detached(priority: .utility) {
                await CleanerProjectScanner.scan(roots: roots, recentDays: recentDays) { text in
                    Task { @MainActor in self?.setProgress(text, gen: gen) }
                }
            }
            let result = await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.projects = result.projects
            self.skippedRecent = result.skippedRecent
            self.isScanning = false
        }
    }

    private func setProgress(_ text: String, gen: Int) {
        guard generation == gen, isScanning, Date().timeIntervalSince(lastProgressAt) > 0.1 else { return }
        lastProgressAt = Date()
        progress = text
    }

    func stop() {
        generation += 1
        task?.cancel()
        isScanning = false
        status = "Scan stopped."; statusIsError = false
    }

    func toggle(_ p: CleanerProject) {
        if selection.contains(p.url) { selection.remove(p.url) } else { selection.insert(p.url) }
    }

    /// Moves the selected projects' regenerable folders to the Trash.
    func trashSelected() {
        let items = selectedProjects
        guard !items.isEmpty, !isTrashing else { return }
        isTrashing = true; status = nil
        Task {
            let result: (freed: Int64, removed: Set<URL>, failures: [String]) = await Task.detached(priority: .utility) {
                var freed: Int64 = 0
                var removed = Set<URL>()
                var failures: [String] = []
                for p in items {
                    var allOK = true
                    for j in p.junk {
                        guard CleanerGuard.isAllowed(j.url) else {
                            failures.append("\(p.name)/\(j.name): outside folders MacMaster may clean")
                            allOK = false; continue
                        }
                        if let err = AppPaths.trash(j.url) {
                            failures.append("\(p.name)/\(j.name): \(err)")
                            allOK = false
                        } else { freed += j.size }
                    }
                    if allOK { removed.insert(p.url) }
                }
                return (freed, removed, failures)
            }.value
            projects.removeAll { result.removed.contains($0.url) }
            selection.subtract(result.removed)
            isTrashing = false
            if result.failures.isEmpty {
                status = "Moved \(Fmt.bytes(result.freed)) to the Trash. Rebuild a project when you open it again."
                statusIsError = false
            } else {
                status = "Moved \(Fmt.bytes(result.freed)) to the Trash. Could not remove: " + result.failures.prefix(2).joined(separator: "; ")
                statusIsError = true
            }
        }
    }

    // MARK: Simulators and Docker

    func probeTools() {
        Task {
            let (sim, docker): (Bool, Int64?) = await Task.detached(priority: .utility) {
                let sim = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
                    && Shell.run("/usr/bin/xcrun", ["--find", "simctl"], timeout: 15).ok
                let dockerURL = AppPaths.home.appendingPathComponent("Library/Containers/com.docker.docker")
                let docker: Int64? = FileManager.default.fileExists(atPath: dockerURL.path) ? AppPaths.allocatedSize(of: dockerURL) : nil
                return (sim, docker)
            }.value
            simctlAvailable = sim
            dockerBytes = docker
        }
    }

    func deleteUnavailableSimulators() {
        guard !isDeletingSims else { return }
        isDeletingSims = true; status = nil
        Task {
            let r: (ok: Bool, freed: Int64, err: String) = await Task.detached(priority: .utility) {
                let dir = AppPaths.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
                let before = AppPaths.allocatedSize(of: dir)
                let res = Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 180)
                let after = AppPaths.allocatedSize(of: dir)
                return (res.ok, max(0, before - after), res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }.value
            isDeletingSims = false
            if r.ok {
                status = r.freed > 0 ? "Deleted unavailable simulators and freed \(Fmt.bytes(r.freed))." : "No unavailable simulators to delete."
                statusIsError = false
            } else {
                status = "Could not delete simulators: " + (r.err.isEmpty ? "xcrun failed." : r.err)
                statusIsError = true
            }
        }
    }
}

// MARK: - View

struct CleanerProjectsView: View {
    @State private var model = CleanerProjectsModel()
    @AppStorage(CleanerProjectSettings.roots) private var rootsRaw = ""
    @AppStorage(CleanerProjectSettings.recentDays) private var recentDays = 14
    @State private var confirmTrash = false
    @State private var confirmSims = false

    private var customRoots: [URL] { CleanerProjectSettings.parse(rootsRaw) }
    private var roots: [URL] { customRoots.isEmpty ? CleanerProjectSettings.defaultRoots() : customRoots }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            projectsCard.searchAnchor("cleaner.projects")
            if model.simctlAvailable { simulatorsCard.searchAnchor("cleaner.simulators") }
            if let d = model.dockerBytes { dockerCard(d).searchAnchor("cleaner.docker") }
            if let s = model.status {
                Label(s, systemImage: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(model.statusIsError ? .orange : .green)
            }
        }
        .onAppear { model.probeTools() }
        .confirmationDialog("Move build folders of \(Fmt.count(model.selectedProjects.count, "project")) to the Trash?",
                            isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash (\(Fmt.bytes(model.selectedBytes)))", role: .destructive) { model.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only folders that tools can rebuild are moved. Your source files stay. You can restore from the Trash.") }
        .confirmationDialog("Delete unavailable simulators?", isPresented: $confirmSims, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteUnavailableSimulators() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Runs xcrun simctl delete unavailable. Simulators for Xcode versions you no longer have are removed. This does not go to the Trash.") }
    }

    // MARK: Projects

    private var projectsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "hammer.fill", colors: Theme.Palette.cleaner, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer projects").font(.title3.weight(.semibold))
                    Text("Folders like node_modules, target and build that a tool can recreate.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.stop() }
                } else {
                    Button { model.scan(roots: roots, recentDays: recentDays) } label: {
                        Text(model.hasScanned ? "Rescan" : "Scan projects")
                    }
                    .buttonStyle(.mmPrimary(tint: Theme.Palette.cleaner[1]))
                    .disabled(roots.isEmpty)
                }
            }
            rootsRow
            HStack {
                Picker("Skip projects changed in the last", selection: $recentDays) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("60 days").tag(60)
                }
                .frame(maxWidth: 320)
                Spacer()
            }
            .font(.callout)

            if model.isScanning {
                Text(model.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if model.hasScanned {
                if model.projects.isEmpty {
                    Text(model.skippedRecent > 0
                         ? "Nothing to clean. \(Fmt.count(model.skippedRecent, "recent project")) skipped."
                         : "No old build folders found in these locations.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Divider()
                    projectList
                    actionBar
                }
            }
        }
        .card()
    }

    private var rootsRow: some View {
        HStack(spacing: 8) {
            Text("Looking in").font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if roots.isEmpty { Text("No project folders found. Add one.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(roots, id: \.self) { r in
                        HStack(spacing: 4) {
                            Text((r.path as NSString).abbreviatingWithTildeInPath).font(.caption).lineLimit(1)
                            if !customRoots.isEmpty {
                                Button { removeRoot(r) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                    .help("Stop looking here")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
            Button("Add folder…") { addRoot() }.controlSize(.small)
            if !customRoots.isEmpty { Button("Use defaults") { rootsRaw = "" }.controlSize(.small) }
        }
    }

    private func addRoot() {
        guard let u = ToolsPicker.chooseFolder(start: AppPaths.home, message: "Choose a folder that holds your projects") else { return }
        var list = customRoots.isEmpty ? CleanerProjectSettings.defaultRoots() : customRoots
        if !list.contains(u) { list.append(u) }
        rootsRaw = CleanerProjectSettings.encode(list)
    }

    private func removeRoot(_ r: URL) {
        rootsRaw = CleanerProjectSettings.encode(customRoots.filter { $0 != r })
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.projects.prefix(200))) { p in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { model.selection.contains(p.url) }, set: { _ in model.toggle(p) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(p.kinds.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(p.junk.map(\.name).joined(separator: ", ") + " · rebuild with " + (p.rebuild.first ?? "your build tool"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\((p.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) · last changed \(ToolsFormat.relative(p.lastModified))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(Fmt.bytes(p.size)).font(.callout.weight(.semibold)).monospacedDigit()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(p) }
                Divider()
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Select all") { model.selection = Set(model.projects.map(\.url)) }.controlSize(.small)
            Button("None") { model.selection = [] }.controlSize(.small).disabled(model.selection.isEmpty)
            Text("\(Fmt.count(model.projects.count, "project")) · \(Fmt.bytes(model.totalBytes))" +
                 (model.skippedRecent > 0 ? " · \(model.skippedRecent) recent skipped" : ""))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isTrashing { ProgressView().controlSize(.small) }
            Button(role: .destructive) { confirmTrash = true } label: {
                Label(model.selection.isEmpty ? "Move to Trash" : "Move to Trash · \(Fmt.bytes(model.selectedBytes))", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty || model.isTrashing)
        }
    }

    // MARK: Simulators and Docker

    private var simulatorsCard: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "iphone.gen3", colors: Theme.Palette.indigo, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Xcode simulators").font(.title3.weight(.semibold))
                Text("Remove simulators left behind by old Xcode versions.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDeletingSims { ProgressView().controlSize(.small) }
            Button("Delete unavailable") { confirmSims = true }.disabled(model.isDeletingSims)
        }
        .card()
    }

    private func dockerCard(_ bytes: Int64) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: "shippingbox.fill", colors: Theme.Palette.blue, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Docker uses \(Fmt.bytes(bytes))").font(.title3.weight(.semibold))
                Text("Images, containers and volumes live there. To free space, run docker system prune in Terminal. MacMaster never runs Docker for you.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("docker system prune", forType: .string)
            }
        }
        .card()
    }
}
