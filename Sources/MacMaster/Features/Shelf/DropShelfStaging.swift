import AppKit
import UniformTypeIdentifiers

/// Turns non-file content (clipboard text, images) into real files so the shelf can hold and drag them.
/// Files live in the temp folder, one subfolder each, and are purged at launch. The shelf itself never
/// copies or moves the user's own files.
enum DropShelfStaging {
    nonisolated static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("MacMasterShelf", isDirectory: true)
    }

    nonisolated static func purge() { try? FileManager.default.removeItem(at: root) }

    nonisolated private static func folder() -> URL? {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir }
        catch { return nil }
    }

    /// "Clipboard - first words of the text.txt"
    nonisolated static func writeText(_ text: String) -> URL? {
        guard let dir = folder() else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.unicodeScalars.map { "/:\\\0".unicodeScalars.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.isEmpty ? "Clipboard text" : "Clipboard - " + String(clean.prefix(32)).trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent(name + ".txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    /// Writes PNG data as-is, or converts TIFF/other image data to PNG.
    nonisolated static func writeImage(_ data: Data) -> URL? {
        guard let dir = folder() else { return nil }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent("Clipboard image.png")
        do { try png.write(to: url); return url } catch { return nil }
    }
}

extension DropShelf {
    /// Adds file URLs (already on disk) to the shelf.
    func add(_ urls: [URL]) { model.add(urls) }

    /// Adds what's on a pasteboard: files first, else an image (as PNG), else text (as .txt). False if nothing usable.
    @discardableResult
    func addFromPasteboard(_ pb: NSPasteboard = .general) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.add(urls)
            return true
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), data.count < 60_000_000 {
            stage { DropShelfStaging.writeImage(data) }
            return true
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stage { DropShelfStaging.writeText(s) }
            return true
        }
        return false
    }

    /// Adds a clipboard-history entry: text becomes a .txt file, images a .png, files go in as they are.
    func add(clipboard kind: ToolsClipboardItem.Kind) {
        switch kind {
        case .text(let s): stage { DropShelfStaging.writeText(s) }
        case .image(let d): stage { DropShelfStaging.writeImage(d) }
        case .files(let urls): model.add(urls)
        }
    }

    /// Writes the staged file off the main thread, then adds it.
    private func stage(_ make: @escaping @Sendable () -> URL?) {
        model.pendingLoads += 1
        Task {
            let url = await Task.detached(priority: .userInitiated, operation: make).value
            model.pendingLoads -= 1
            if let url { model.add([url]) }
        }
    }
}
