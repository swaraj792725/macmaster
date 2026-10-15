import AppKit
import CoreServices
import Foundation

// MARK: - Snapshot + FSEvents

/// In-memory map of installed apps in /Applications and ~/Applications, diffed on each FSEvents batch.
/// Zero work while idle. All state is confined to `queue`.
private final class UninstallerDeletionIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mm.uninstaller.deletion", qos: .utility)
    private var apps: [String: UninstallerApp] = [:]
    private var pending: [String: (app: UninstallerApp, since: Date)] = [:]
    private var recheckScheduled = false
    private var stream: FSEventStreamRef?
    private let onDeleted: @Sendable (UninstallerApp) -> Void

    /// A vanished app must stay gone this long before it counts (updaters replace the bundle).
    private static let settle: TimeInterval = 4

    init(onDeleted: @escaping @Sendable (UninstallerApp) -> Void) { self.onDeleted = onDeleted }

    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications"), UninstallerPaths.home.appendingPathComponent("Applications")]
    }

    func start() {
        queue.async { [self] in
            apps = Dictionary(uniqueKeysWithValues: Self.listApps(reuse: [:]).map { ($0.url.path, $0) })
            let paths = Self.roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return }
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<UninstallerDeletionIndex>.fromOpaque(info).takeUnretainedValue().process()
            }
            guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                              FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Async so main never waits behind a long scan; `self` stays alive until the stream is torn down
    /// (the stream context holds it unretained). A later `start()` queues after this on the same serial queue.
    func stop() {
        queue.async { [self] in
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            pending = [:]
        }
    }

    /// Runs on `queue`.
    private func process() {
        let fresh = Self.listApps(reuse: apps)
        let freshByPath = Dictionary(uniqueKeysWithValues: fresh.map { ($0.url.path, $0) })
        let freshIDs = Set(fresh.map { $0.bundleID.lowercased() })

        for (path, app) in apps where freshByPath[path] == nil && pending[path] == nil {
            pending[path] = (app, Date())
        }
        apps = freshByPath

        let now = Date()
        for (path, entry) in pending {
            // Back again, or renamed/moved within the watched folders.
            if freshByPath[path] != nil || freshIDs.contains(entry.app.bundleID.lowercased()) {
                pending[path] = nil
            } else if now.timeIntervalSince(entry.since) >= Self.settle {
                pending[path] = nil
                if Self.shouldReport(entry.app) { onDeleted(entry.app) }
            }
        }
        if !pending.isEmpty, !recheckScheduled {
            recheckScheduled = true
            queue.asyncAfter(deadline: .now() + Self.settle + 0.5) { [self] in
                recheckScheduled = false
                process()
            }
        }
    }

    private static func shouldReport(_ app: UninstallerApp) -> Bool {
        if app.isSystem { return false }
        let id = app.bundleID.lowercased()
        if id == Bundle.main.bundleIdentifier?.lowercased() || app.url.lastPathComponent == "MacMaster.app" { return false }
        if id.hasPrefix("com.apple.") { return false }
        // Still installed somewhere else (e.g. Setapp, Utilities)?
        return !UninstallerAppCatalog.discover().contains { $0.bundleID.lowercased() == id }
    }

    /// Top level + one level of subfolders of each root. Reuses entries already read.
    private static func listApps(reuse: [String: UninstallerApp]) -> [UninstallerApp] {
        var out: [UninstallerApp] = []
        func add(_ url: URL, _ source: String) {
            if let known = reuse[url.path] { out.append(known) }
            else if let app = UninstallerAppCatalog.makeApp(at: url, source: source) { out.append(app) }
        }
        for root in roots {
            let source = root.path == "/Applications" ? "Applications" : "~/Applications"
            for child in UninstallerPaths.children(root) {
                if child.pathExtension.lowercased() == "app" { add(child, source) }
                else if UninstallerPaths.isDirectory(child) {
                    for sub in UninstallerPaths.children(child) where sub.pathExtension.lowercased() == "app" { add(sub, source) }
                }
            }
        }
        return out
    }
}

// MARK: - Watcher

/// Offers to remove leftover files when an app is deleted (like AppCleaner's SmartDelete).
@MainActor
final class UninstallerDeletionWatcher {
    static let shared = UninstallerDeletionWatcher()
    private var index: UninstallerDeletionIndex?
    private var handling: Set<String> = []
    private var testRan = false
    private let panels = UninstallerDeletionPanelController()

    private init() {}

    /// Honours `mm.uninstaller.watchDeletions` (default on). Idempotent.
    func start() {
        if !testRan, let t = ProcessInfo.processInfo.environment["MM_DELETION_TEST"], !t.isEmpty {
            testRan = true
            runTest(t)
        }
        guard UninstallerSettings.watchDeletions, index == nil else { return }
        let idx = UninstallerDeletionIndex { app in
            Task { @MainActor in UninstallerDeletionWatcher.shared.handle(app, test: false) }
        }
        idx.start()
        index = idx
    }

    func stop() {
        index?.stop()
        index = nil
    }

    // MARK: Handling

    private func handle(_ app: UninstallerApp, test: Bool) {
        // The in-app uninstaller is already showing this app's removal.
        if !test, let plan = UninstallerModel.shared.plan, plan.source == .app, plan.app?.bundleID == app.bundleID { return }
        guard handling.insert(app.bundleID).inserted else { return }
        let includeSystem = UninstallerSettings.scanSystem
        let includeLow = UninstallerSettings.includeLow
        Task {
            let (found, trashed) = await Task.detached(priority: .utility) { () -> ([UninstallerItem], URL?) in
                let trashed = Self.trashedCopy(of: app)
                // Scan from the Trash copy when there is one: gives team ID + embedded helper ids.
                var target = app
                if let t = trashed {
                    target = UninstallerApp(url: t, name: app.name, bundleID: app.bundleID, version: app.version,
                                            executable: app.executable, aliases: app.aliases, isSystem: false, source: app.source)
                }
                let installed = UninstallerAppCatalog.discover()
                let items = await UninstallerDeepScanner.scan(app: target, installed: installed, includeSystem: includeSystem) { _ in }
                return (items.filter { $0.category != .application && (includeLow || $0.confidence != .low) }, trashed)
            }.value
            handling.remove(app.bundleID)
            if found.isEmpty && !test { return }
            let size = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.size }, countStyle: .file)
            if !test {
                Notifier.post(title: "\(app.name) was moved to the Trash",
                              body: "Found \(found.count) leftover file\(found.count == 1 ? "" : "s") (\(size)).",
                              id: "mm.deletion.\(app.bundleID)", sound: false)
            }
            panels.show(app: app, iconPath: trashed?.path, items: found, test: test)
        }
    }

    /// Looks for the deleted bundle in ~/.Trash (needs Full Disk Access; fine when unavailable).
    nonisolated private static func trashedCopy(of app: UninstallerApp) -> URL? {
        let trash = UninstallerPaths.home.appendingPathComponent(".Trash")
        return UninstallerPaths.children(trash).first {
            $0.pathExtension.lowercased() == "app" && UninstallerAppCatalog.bundleID(of: $0) == app.bundleID
        }
    }

    // MARK: Dev aid

    /// MM_DELETION_TEST=<path-to-.app | bundle-id>: show the panel without deleting anything.
    private func runTest(_ spec: String) {
        Task {
            let app = await Task.detached(priority: .utility) { () -> UninstallerApp? in
                if spec.contains("/") || spec.hasSuffix(".app") {
                    return UninstallerAppCatalog.makeApp(at: URL(fileURLWithPath: (spec as NSString).expandingTildeInPath), source: "Test")
                }
                let id = spec.lowercased()
                if let a = UninstallerAppCatalog.discover().first(where: { $0.bundleID.lowercased() == id }) { return a }
                // Not installed: scan by bundle id alone.
                let name = spec.split(separator: ".").last.map(String.init) ?? spec
                return UninstallerApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: spec,
                                      version: "", executable: name, aliases: [name], isSystem: false, source: "Test")
            }.value
            if let app { handle(app, test: true) }
        }
    }
}
