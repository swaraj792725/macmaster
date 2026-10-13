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

    nonisolated static func folder() -> URL? {
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

    /// Copies a file (or folder) into its own staging subfolder, keeping its name. For temp files that vanish
    /// when a provider callback returns.
    nonisolated static func copyIn(_ url: URL) -> URL? {
        guard let dir = folder() else { return nil }
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
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

    /// Adds what's on a pasteboard: files first, then file promises (screenshot thumbnail, Photos, Mail), else an image (as PNG), else text (as .txt). False if nothing usable.
    @discardableResult
    func addFromPasteboard(_ pb: NSPasteboard = .general) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.add(urls)
            return true
        }
        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            receive(promises)
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

    /// UTIs the shelf's drop zones accept.
    /// File-promise pasteboard types (dragging the floating screenshot thumbnail, Photos, Mail attachments...).
    static let promiseTypes: [UTType] = NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }
    static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText, .data] + promiseTypes

    private static let promiseQueue = OperationQueue()

    /// Receives file promises into a staging folder (off the main thread), then adds each file as it lands.
    func receive(_ promises: [NSFilePromiseReceiver]) {
        for r in promises {
            guard let dir = DropShelfStaging.folder() else { continue }
            // The callback fires once per promised file, error or not.
            let count = max(1, r.fileNames.count)
            model.pendingLoads += count
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.model.pendingLoads -= 1
                        if error == nil { self.model.add([url]) }
                        self.noteShelfDrop()
                    }
                }
            }
        }
    }

    /// A provider type that is a plain file payload (a file promise or in-memory file), not text, a link or an image.
    private static func isFileType(_ id: String) -> Bool {
        guard let t = UTType(id), t.conforms(to: .data) else { return false }
        if t.conforms(to: .text) || t.conforms(to: .url) || t.conforms(to: .image) { return false }
        return !promiseTypes.contains(t) && t != .fileURL
    }

    /// Adds dropped item providers: file URLs as-is, images (and file promises) copied into staging, web links and text as .txt.
    /// True if at least one provider was usable. Loading finishes asynchronously.
    @discardableResult
    func addFromProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !model.internalDragActive else { return false }
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                load { done in
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        var url: URL?
                        if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let u = item as? URL { url = u }
                        else if let u = item as? NSURL { url = u as URL }
                        done(url)
                    }
                }
            } else if let id = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                accepted = true
                load { done in
                    // File first (keeps the name, e.g. "Screenshot ….png"); TIFF and failures go through PNG conversion.
                    _ = p.loadFileRepresentation(forTypeIdentifier: id) { url, _ in
                        if let url, !["tif", "tiff"].contains(url.pathExtension.lowercased()), let copy = DropShelfStaging.copyIn(url) {
                            done(copy)
                            return
                        }
                        p.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                            done(data.flatMap { DropShelfStaging.writeImage($0) })
                        }
                    }
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                accepted = true
                load { done in
                    _ = p.loadObject(ofClass: URL.self) { u, _ in done(u.flatMap { DropShelfStaging.writeText($0.absoluteString) }) }
                }
            } else if let id = p.registeredTypeIdentifiers.first(where: Self.isFileType) {
                // Non-image file promises / file payloads (PDFs, videos...).
                accepted = true
                load { done in
                    _ = p.loadFileRepresentation(forTypeIdentifier: id) { url, _ in done(url.flatMap { DropShelfStaging.copyIn($0) }) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                accepted = true
                load { done in
                    _ = p.loadObject(ofClass: String.self) { s, _ in
                        done(s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : DropShelfStaging.writeText($0) })
                    }
                }
            }
        }
        return accepted
    }

    /// Runs one async provider load; `done` hops back to the main actor and adds the resulting file.
    private func load(_ start: (@escaping @Sendable (URL?) -> Void) -> Void) {
        model.pendingLoads += 1
        start { url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.model.pendingLoads -= 1
                    if let url { self.model.add([url]) }
                    self.noteShelfDrop()
                }
            }
        }
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
