import Foundation
import SwiftUI
import Darwin

// MARK: - Kinds

enum DiskKind: Int, CaseIterable, Sendable {
    case folder, app, media, document, code, archive, system, other

    var title: String {
        switch self {
        case .folder: "Folders"
        case .app: "Apps"
        case .media: "Media"
        case .document: "Documents"
        case .code: "Developer"
        case .archive: "Archives & images"
        case .system: "System & libraries"
        case .other: "Other files"
        }
    }

    var color: Color {
        switch self {
        case .folder: Color(hex: 0x3B82F6)
        case .app: Color(hex: 0xA855F7)
        case .media: Color(hex: 0xEC4899)
        case .document: Color(hex: 0xF59E0B)
        case .code: Color(hex: 0x10B981)
        case .archive: Color(hex: 0xF97316)
        case .system: Color(hex: 0x64748B)
        case .other: Color(hex: 0x8B95A5)
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .app: "app.fill"
        case .media: "photo.fill"
        case .document: "doc.text.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox.fill"
        case .system: "gearshape.fill"
        case .other: "doc.fill"
        }
    }

    private static let mediaExt: Set<String> = [
        "mp4", "mov", "mkv", "avi", "m4v", "webm", "mp3", "wav", "aac", "flac", "m4a", "aiff", "jpg", "jpeg", "png", "heic",
        "gif", "tif", "tiff", "raw", "cr2", "dng", "psd", "webp", "svg", "ai", "prproj", "fcpbundle"]
    private static let docExt: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "csv", "epub", "odt"]
    private static let codeExt: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "rb", "php",
        "json", "html", "css", "o", "a", "dylib", "class", "jar", "pyc", "wasm", "map", "lock", "sh"]
    private static let archiveExt: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "xip", "vmdk", "vdi", "qcow2", "sparseimage",
        "sparsebundle", "img", "ipsw"]
    private static let devDirs: Set<String> = [
        "node_modules", ".git", "Pods", "DerivedData", ".build", "target", "venv", ".venv", ".gradle", ".next", ".cargo", ".npm",
        ".pnpm-store", "__pycache__", "build", "dist", "Carthage"]
    private static let mediaDirs: Set<String> = ["Movies", "Music", "Pictures"]

    static func classify(name: String, isDirectory: Bool) -> DiskKind {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if isDirectory {
            if ext == "app" { return .app }
            if ext == "photoslibrary" || ext == "fcpbundle" || mediaDirs.contains(name) { return .media }
            if ext == "sparsebundle" || ext == "xcarchive" { return .archive }
            if devDirs.contains(name) || ext == "xcodeproj" || ext == "xcworkspace" { return .code }
            if name == "Library" || name == "System" || name == "private" || name == "usr" || ext == "framework" { return .system }
            return .folder
        }
        if mediaExt.contains(ext) { return .media }
        if docExt.contains(ext) { return .document }
        if codeExt.contains(ext) { return .code }
        if archiveExt.contains(ext) { return .archive }
        if ext == "app" { return .app }
        return .other
    }
}

// MARK: - Node

/// A file or folder in the scanned tree. Built on a background thread, then owned by the main actor.
final class DiskNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    /// Empty for aggregate nodes ("Smaller items").
    let path: String
    let isDirectory: Bool
    let kind: DiskKind
    var size: Int64
    var fileCount: Int
    var children: [DiskNode] = []
    weak var parent: DiskNode?
    let isAggregate: Bool
    /// `.app` bundles and similar: counted, but their insides are not browsable.
    let isBundle: Bool

    init(name: String, path: String, isDirectory: Bool, kind: DiskKind, size: Int64, fileCount: Int = 1,
         isAggregate: Bool = false, isBundle: Bool = false) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.kind = kind
        self.size = size; self.fileCount = fileCount; self.isAggregate = isAggregate; self.isBundle = isBundle
    }

    var url: URL { URL(fileURLWithPath: path) }
    var canDrill: Bool { isDirectory && !isAggregate && !isBundle && !children.isEmpty }

    var ancestry: [DiskNode] {
        var out: [DiskNode] = [self]
        var n = self
        while let p = n.parent { out.append(p); n = p }
        return out.reversed()
    }

    /// Removes this node from its parent and shrinks every ancestor.
    func detach() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        var n: DiskNode? = p
        while let a = n {
            a.size = max(0, a.size - size)
            a.fileCount = max(0, a.fileCount - fileCount)
            n = a.parent
        }
        parent = nil
    }
}

// MARK: - Progress

final class DiskScanCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var unreadable = 0
    private var path = ""

    func add(files f: Int, bytes b: Int64, path p: String) {
        lock.lock(); files += f; bytes += b; path = p; lock.unlock()
    }
    func addUnreadable() { lock.lock(); unreadable += 1; lock.unlock() }
    func snapshot() -> (files: Int, bytes: Int64, unreadable: Int, path: String) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, unreadable, path)
    }
}

// MARK: - Scanner

enum DiskMapScanner {
    /// Files smaller than this are folded into a "Smaller items" node, which keeps whole-disk trees small.
    static let keepFileBytes: Int64 = 512 * 1024
    static let keepFolderBytes: Int64 = 128 * 1024
    static let maxFilesPerFolder = 150
    /// Folders scanned in parallel down to this depth; deeper levels run sequentially inside one task.
    static let parallelDepth = 2

    /// Paths never entered: firmlink duplicates, devices, other volumes (when scanning `/`), swap.
    private static let skipExact: Set<String> = [
        "/System/Volumes", "/dev", "/Volumes", "/private/var/vm", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
        "/.vol", "/Network", "/home", "/net",
    ]

    struct Context: Sendable {
        let rootPath: String
        let rootDevice: dev_t
        let stayOnDevice: Bool
        let counters: DiskScanCounters
    }

    static func scan(root url: URL, counters: DiskScanCounters) async -> DiskNode? {
        let path = url.standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        // The boot volume is reached through firmlinks, so device checks only make sense elsewhere.
        let ctx = Context(rootPath: path, rootDevice: st.st_dev, stayOnDevice: path != "/", counters: counters)
        let name = path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent
        return await scanParallel(path: path, name: name, depth: 0, ctx: ctx)
    }

    // MARK: Directory reading

    private struct Entry {
        let name: String
        let path: String
        let size: Int64
        let isDir: Bool
    }

    /// Reads one directory with `readdir` + `fstatat` (no symlink following). Returns nil when unreadable.
    private static func read(_ path: String, ctx: Context) -> [Entry]? {
        guard let dir = opendir(path) else {
            ctx.counters.addUnreadable()
            return nil
        }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var out: [Entry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let full = path == "/" ? "/" + name : path + "/" + name
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                out.append(Entry(name: name, path: full, size: Int64(st.st_blocks) * 512, isDir: false))
            case S_IFDIR:
                if skipExact.contains(full) { continue }
                if ctx.stayOnDevice && st.st_dev != ctx.rootDevice { continue }
                out.append(Entry(name: name, path: full, size: 0, isDir: true))
            default:
                continue   // symlinks, sockets, devices: not followed, not counted
            }
        }
        return out
    }

    private static func isBundleName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "photoslibrary", "xcarchive", "fcpbundle", "framework", "bundle", "plugin", "appex"].contains(ext)
    }

    // MARK: Assembly

    /// Builds a folder node from its direct files and already-scanned subfolders.
    private static func assemble(name: String, path: String, files: [Entry], subfolders: [DiskNode], isBundle: Bool) -> DiskNode {
        var kept: [DiskNode] = []
        var smallSize: Int64 = 0, smallCount = 0
        var total: Int64 = 0, count = 0

        let bigFiles = files.filter { $0.size >= keepFileBytes }.sorted { $0.size > $1.size }
        for (i, f) in bigFiles.enumerated() {
            if i < maxFilesPerFolder {
                kept.append(DiskNode(name: f.name, path: f.path, isDirectory: false,
                                     kind: DiskKind.classify(name: f.name, isDirectory: false), size: f.size))
            } else { smallSize += f.size; smallCount += 1 }
        }
        for f in files where f.size < keepFileBytes { smallSize += f.size; smallCount += 1 }
        for f in files { total += f.size; count += 1 }

        for sub in subfolders {
            total += sub.size; count += sub.fileCount
            if sub.size >= keepFolderBytes { kept.append(sub) } else { smallSize += sub.size; smallCount += sub.fileCount }
        }
        if smallSize > 0 {
            kept.append(DiskNode(name: "Smaller items (\(smallCount))", path: "", isDirectory: false, kind: .other,
                                 size: smallSize, fileCount: smallCount, isAggregate: true))
        }
        kept.sort { $0.size > $1.size }
        let node = DiskNode(name: name, path: path, isDirectory: true,
                            kind: DiskKind.classify(name: name, isDirectory: true), size: total, fileCount: count,
                            isBundle: isBundle)
        node.children = isBundle ? [] : kept
        for c in node.children { c.parent = node }
        return node
    }

    private static func scanParallel(path: String, name: String, depth: Int, ctx: Context) async -> DiskNode {
        if Task.isCancelled { return DiskNode(name: name, path: path, isDirectory: true, kind: .folder, size: 0, fileCount: 0) }
        guard let entries = read(path, ctx: ctx) else {
            return DiskNode(name: name, path: path, isDirectory: true,
                            kind: DiskKind.classify(name: name, isDirectory: true), size: 0, fileCount: 0)
        }
        let files = entries.filter { !$0.isDir }
        ctx.counters.add(files: files.count, bytes: files.reduce(0) { $0 + $1.size }, path: path)
        let dirs = entries.filter(\.isDir)
        let subs: [DiskNode] = await withTaskGroup(of: DiskNode.self) { group in
            var it = dirs.makeIterator()
            var running = 0
            var out: [DiskNode] = []
            let width = max(4, ProcessInfo.processInfo.activeProcessorCount)
            func addNext(_ g: inout TaskGroup<DiskNode>) -> Bool {
                guard let d = it.next() else { return false }
                let deeper = depth + 1
                g.addTask {
                    if isBundleName(d.name) { return bundleNode(d, ctx: ctx) }
                    return deeper < parallelDepth
                        ? await scanParallel(path: d.path, name: d.name, depth: deeper, ctx: ctx)
                        : scanSequential(path: d.path, name: d.name, ctx: ctx)
                }
                return true
            }
            while running < width, addNext(&group) { running += 1 }
            while let node = await group.next() {
                out.append(node)
                if addNext(&group) { continue } else { running -= 1 }
            }
            return out
        }
        return assemble(name: name, path: path, files: files, subfolders: subs, isBundle: false)
    }

    private static func scanSequential(path: String, name: String, ctx: Context) -> DiskNode {
        guard !Task.isCancelled, let entries = read(path, ctx: ctx) else {
            return DiskNode(name: name, path: path, isDirectory: true,
                            kind: DiskKind.classify(name: name, isDirectory: true), size: 0, fileCount: 0)
        }
        let files = entries.filter { !$0.isDir }
        ctx.counters.add(files: files.count, bytes: files.reduce(0) { $0 + $1.size }, path: path)
        var subs: [DiskNode] = []
        for d in entries where d.isDir {
            if Task.isCancelled { break }
            subs.append(isBundleName(d.name) ? bundleNode(d, ctx: ctx) : scanSequential(path: d.path, name: d.name, ctx: ctx))
        }
        return assemble(name: name, path: path, files: files, subfolders: subs, isBundle: false)
    }

    /// Bundles count toward totals but are shown as a single block.
    private static func bundleNode(_ e: Entry, ctx: Context) -> DiskNode {
        let size = Task.isCancelled ? 0 : AppPaths.allocatedSize(of: URL(fileURLWithPath: e.path))
        ctx.counters.add(files: 1, bytes: size, path: e.path)
        return DiskNode(name: e.name, path: e.path, isDirectory: true,
                        kind: DiskKind.classify(name: e.name, isDirectory: true), size: size, fileCount: 1, isBundle: true)
    }
}
