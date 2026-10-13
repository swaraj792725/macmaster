import SwiftUI
import AppKit

/// Fixed metrics shared by the SwiftUI layout and the panel sizing.
enum DropShelfLayout {
    static let width: CGFloat = 260
    static let header: CGFloat = 44
    static let footer: CGFloat = 92
    static let emptyBody: CGFloat = 132
    static let tile: CGFloat = 94
    static let gap: CGFloat = 8
    static let maxRows = 3

    static func gridHeight(count: Int) -> CGFloat {
        let rows = min(maxRows, (count + 1) / 2)
        return CGFloat(rows) * tile + CGFloat(max(0, rows - 1)) * gap + 20
    }

    static func height(count: Int) -> CGFloat {
        count == 0 ? header + emptyBody : header + gridHeight(count: count) + footer
    }
}

/// Floating, non-activating panel that never steals focus from the app being dragged from.
private final class DropShelfNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the shelf window and the file actions triggered from its UI.
@MainActor
final class DropShelfPanelController {
    let model: DropShelfModel
    private var panel: DropShelfNSPanel?
    private var noticeTask: Task<Void, Never>?
    private var generation = 0

    /// Shown by a drag gesture and still empty; closed when that drag ends without a drop.
    var openedByDrag = false
    var onClose: (() -> Void)?

    init(model: DropShelfModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Show / hide

    func show(_ placement: DropShelfPlacement) {
        model.pruneMissing()
        let panel = ensurePanel()
        generation += 1
        resize(animated: false)
        panel.setFrameOrigin(origin(for: placement, size: panel.frame.size))
        guard !panel.isVisible || panel.alphaValue < 1 else { panel.orderFrontRegardless(); return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        openedByDrag = false
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) { [weak self, weak panel] in
            MainActor.assumeIsolated { if self?.generation == token { panel?.orderOut(nil) } }
        }
        onClose?()
    }

    /// Keeps the panel height in step with the item count (top edge stays put).
    func resize(animated: Bool = true) {
        guard let panel else { return }
        let h = DropShelfLayout.height(count: model.items.count)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: animated && panel.isVisible)
    }

    private func ensurePanel() -> DropShelfNSPanel {
        if let panel { return panel }
        let size = NSSize(width: DropShelfLayout.width, height: DropShelfLayout.height(count: model.items.count))
        let p = DropShelfNSPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        let host = NSHostingView(rootView: DropShelfContentView(model: model, controller: self))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        p.contentView = glass
        panel = p
        return p
    }

    private func origin(for placement: DropShelfPlacement, size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 12
        var x: CGFloat
        switch placement {
        case .edge(.left): x = vis.minX + margin
        case .edge(.right): x = vis.maxX - size.width - margin
        default:
            x = mouse.x + 48
            if x + size.width > vis.maxX - margin { x = mouse.x - 48 - size.width }
        }
        var y = mouse.y + size.height / 2 - size.height   // vertically centred on the cursor
        y = min(max(y, vis.minY + margin), vis.maxY - size.height - margin)
        x = min(max(x, vis.minX + margin), vis.maxX - size.width - margin)
        return NSPoint(x: x, y: y)
    }

    // MARK: Actions

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(model.urls)
    }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(model.urls as [NSURL])
        flash("Copied \(model.urls.count) to clipboard")
    }

    func share() {
        guard let view = panel?.contentView, !model.urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: model.urls)
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.minY + 56, width: 2, height: 2)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    /// Asks for a folder, then moves or copies every item there.
    func transfer(move: Bool) {
        let urls = model.urls
        guard !urls.isEmpty else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = move ? "Move Here" : "Copy Here"
        open.message = move ? "Choose where to move \(urls.count) item(s)." : "Choose where to copy \(urls.count) item(s)."
        FrontAppTracker.markDeliberate()
        NSApp.activate()
        guard open.runModal() == .OK, let dest = open.url else { return }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DropShelfFileOps.transfer(urls, to: dest, move: move)
            }.value
            if move { model.remove(result.done) }
            if !result.failed.isEmpty {
                flash("\(result.failed.count) failed: \(result.failed[0])")
            } else {
                flash("\(move ? "Moved" : "Copied") \(result.done.count) to \(dest.lastPathComponent)")
            }
        }
    }

    func flash(_ text: String) {
        model.notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.model.notice = nil }
        }
    }
}

/// Move/copy with Finder-style unique names; runs off the main thread.
enum DropShelfFileOps {
    struct Result: Sendable { var done: [URL] = []; var failed: [String] = [] }

    static func transfer(_ urls: [URL], to dir: URL, move: Bool) -> Result {
        let fm = FileManager.default
        var out = Result()
        for src in urls {
            let target = uniqueURL(for: src.lastPathComponent, in: dir)
            do {
                if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
                out.done.append(src)
            } catch {
                out.failed.append(src.lastPathComponent)
            }
        }
        return out
    }

    private static func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}
