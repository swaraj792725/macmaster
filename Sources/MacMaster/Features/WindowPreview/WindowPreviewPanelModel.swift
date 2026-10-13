import AppKit
import SwiftUI

/// State shared by the dock panel, the switcher panel and the in-app demo grid.
@MainActor
final class WindowPreviewPanelModel: ObservableObject {
    @Published var windows: [WindowPreviewWindow] = []
    @Published var images: [UInt32: NSImage] = [:]
    @Published var visible = false
    @Published var selectedID: UInt32?
    @Published var hoveredID: UInt32?
    @Published var loading = false

    var icons: [pid_t: NSImage] = [:]
    var thumbSize = WindowPreviewThumbSize.medium.size
    var showTitles = true
    var hasScreenRecording = false
    var vertical = false
    var anchor: UnitPoint = .bottom
    var columns = 1

    var onActivate: (WindowPreviewWindow) -> Void = { WindowPreviewActions.focus($0) }
    var onClose: (WindowPreviewWindow) -> Void = { _ in }
    var onMinimize: (WindowPreviewWindow) -> Void = { _ in }

    private var loadTask: Task<Void, Never>?

    func setWindows(_ new: [WindowPreviewWindow]) {
        windows = new
        let pids = Set(new.map(\.pid))
        icons = icons.filter { pids.contains($0.key) }
        for pid in pids where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        let ids = Set(new.map(\.id))
        images = images.filter { ids.contains($0.key) }
        if let s = selectedID, !ids.contains(s) { selectedID = nil }
        hasScreenRecording = Permissions.isGranted(.screenRecording)
    }

    func remove(id: UInt32) {
        windows.removeAll { $0.id == id }
        images[id] = nil
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Show cached thumbnails immediately, then refresh them (up to 4 captures in flight).
    func loadThumbnails(maxAge: TimeInterval = 0.8) {
        cancelLoading()
        guard Permissions.isGranted(.screenRecording) else { hasScreenRecording = false; return }
        hasScreenRecording = true
        let wins = windows
        let box = CGSize(width: thumbSize.width * 2, height: thumbSize.height * 2)
        loadTask = Task { [weak self] in
            let thumbnailer = WindowPreviewThumbnailer.shared
            for w in wins {
                if let c = await thumbnailer.cached(w.id), let self, !Task.isCancelled, self.images[w.id] == nil {
                    self.images[w.id] = Self.nsImage(c)
                }
            }
            await withTaskGroup(of: (UInt32, CGImage?).self) { group in
                var iterator = wins.makeIterator()
                var inFlight = 0
                func addNext(_ g: inout TaskGroup<(UInt32, CGImage?)>) -> Bool {
                    guard let w = iterator.next() else { return false }
                    g.addTask { (w.id, await thumbnailer.capture(id: w.id, box: box, maxAge: maxAge)) }
                    return true
                }
                while inFlight < 4, addNext(&group) { inFlight += 1 }
                while let (id, img) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let img, let self { self.images[id] = Self.nsImage(img) }
                    _ = addNext(&group)
                }
            }
        }
    }

    private static func nsImage(_ c: CGImage) -> NSImage {
        NSImage(cgImage: c, size: NSSize(width: CGFloat(c.width) / 2, height: CGFloat(c.height) / 2))
    }
}
