import AppKit
import SwiftUI

// MARK: - Item

/// One tile in the switcher: a window, or (optionally) a running app that has no windows.
struct WindowPreviewSwitcherItem: Identifiable {
    let id: UInt32
    var window: WindowPreviewWindow
    var appWindowCount: Int
    var appHidden: Bool
    var appOnly: Bool

    var dimmed: Bool { window.isMinimized || appHidden }

    /// Synthetic id for an app without windows (high bits never collide with CGWindowIDs).
    static func appOnlyID(_ pid: pid_t) -> UInt32 { 0xC000_0000 | UInt32(truncatingIfNeeded: pid) }
}

// MARK: - Layout

/// Grid geometry for the HUD, computed from the item count and the target screen.
struct WindowPreviewSwitcherLayout: Equatable {
    var columns = 1
    var tile = CGSize(width: 250, height: 158)
    var gap: CGFloat = 16
    var padding: CGFloat = 24
    var titleHeight: CGFloat = 26
    /// Transparent room around the HUD for its shadow.
    var inset: CGFloat = 24
    var footer: CGFloat = 0
    var content = CGSize(width: 300, height: 240)
    var scrolls = false

    var panelSize: CGSize { CGSize(width: content.width + inset * 2, height: content.height + inset * 2) }

    static func compute(count: Int, base: CGSize, screen: CGRect, footer: CGFloat) -> WindowPreviewSwitcherLayout {
        var l = WindowPreviewSwitcherLayout()
        l.footer = footer
        let n = max(1, count)
        let maxW = screen.width * 0.92 - l.inset * 2
        let maxH = screen.height * 0.82 - l.inset * 2
        let scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.62]
        for (i, s) in scales.enumerated() {
            let tile = CGSize(width: (base.width * s).rounded(), height: (base.height * s).rounded())
            var cols = max(1, min(n, Int((maxW - l.padding * 2 + l.gap) / (tile.width + l.gap))))
            let rows = (n + cols - 1) / cols
            cols = (n + rows - 1) / rows            // balance the last row
            let h = CGFloat(rows) * (tile.height + l.titleHeight) + CGFloat(rows - 1) * l.gap + l.padding * 2 + footer
            let w = CGFloat(cols) * tile.width + CGFloat(cols - 1) * l.gap + l.padding * 2
            l.tile = tile
            l.columns = cols
            l.content = CGSize(width: w, height: min(h, maxH))
            l.scrolls = h > maxH
            if !l.scrolls || i == scales.count - 1 { break }
        }
        return l
    }
}

// MARK: - Model

@MainActor
final class WindowPreviewSwitcherModel: ObservableObject {
    @Published var items: [WindowPreviewSwitcherItem] = []
    @Published var images: [UInt32: NSImage] = [:]
    @Published var selectedID: UInt32?
    @Published var hoveredID: UInt32?
    @Published var visible = false
    @Published var layout = WindowPreviewSwitcherLayout()
    @Published var hasScreenRecording = true

    var icons: [pid_t: NSImage] = [:]
    private var lastMouse = NSEvent.mouseLocation

    var onCommit: (WindowPreviewSwitcherItem) -> Void = { _ in }
    var onClose: (WindowPreviewSwitcherItem) -> Void = { _ in }
    var onMinimize: (WindowPreviewSwitcherItem) -> Void = { _ in }
    var onQuit: (WindowPreviewSwitcherItem) -> Void = { _ in }

    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return items.firstIndex { $0.id == id }
    }

    var selectedItem: WindowPreviewSwitcherItem? { selectedIndex.map { items[$0] } }

    func setItems(_ new: [WindowPreviewSwitcherItem]) {
        items = new
        let pids = Set(new.map(\.window.pid))
        icons = icons.filter { pids.contains($0.key) }
        for pid in pids where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        let ids = Set(new.map(\.id))
        if images.keys.contains(where: { !ids.contains($0) }) { images = images.filter { ids.contains($0.key) } }
        if let s = selectedID, !ids.contains(s) { selectedID = nil }
        if let h = hoveredID, !ids.contains(h) { hoveredID = nil }
    }

    func reset() {
        items = []
        images = [:]
        selectedID = nil
        hoveredID = nil
    }

    func mergeImages(_ new: [UInt32: NSImage]) {
        guard !new.isEmpty else { return }
        images.merge(new) { _, n in n }
    }

    /// Remember where the mouse is, so tiles scrolling under a still pointer don't steal the selection.
    func noteKeyboard() { lastMouse = NSEvent.mouseLocation }

    func hover(_ id: UInt32, inside: Bool) {
        guard inside else {
            if hoveredID == id { hoveredID = nil }
            return
        }
        let m = NSEvent.mouseLocation
        guard hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 2 else { return }
        lastMouse = m
        if hoveredID != id { hoveredID = id }
        if selectedID != id { selectedID = id }
    }

    static func nsImage(_ c: CGImage) -> NSImage {
        NSImage(cgImage: c, size: NSSize(width: CGFloat(c.width) / 2, height: CGFloat(c.height) / 2))
    }
}
