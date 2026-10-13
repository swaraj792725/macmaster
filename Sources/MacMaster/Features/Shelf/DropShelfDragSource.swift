import SwiftUI
import AppKit

/// Transparent AppKit overlay that starts a real multi-file drag session
/// (SwiftUI `onDrag` can only carry one item).
struct DropShelfDragSource: NSViewRepresentable {
    var items: () -> [DropShelfItem]
    var onBegan: () -> Void = {}
    var onEnded: ([DropShelfItem], Bool) -> Void
    var onOpen: (() -> Void)? = nil

    func makeNSView(context: Context) -> DropShelfDragNSView { DropShelfDragNSView() }

    func updateNSView(_ v: DropShelfDragNSView, context: Context) {
        v.items = items; v.onBegan = onBegan; v.onEnded = onEnded; v.onOpen = onOpen
    }
}

final class DropShelfDragNSView: NSView, NSDraggingSource {
    var items: () -> [DropShelfItem] = { [] }
    var onBegan: () -> Void = {}
    var onEnded: ([DropShelfItem], Bool) -> Void = { _, _ in }
    var onOpen: (() -> Void)?

    private var downPoint: NSPoint = .zero
    private var dragging = false
    private var active: [DropShelfItem] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        if event.clickCount == 2 { onOpen?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
        let list = items()
        guard !list.isEmpty else { return }
        dragging = true
        active = list
        let size: CGFloat = 48
        let dragItems = list.prefix(6).enumerated().map { i, item -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let o = CGFloat(i) * 4
            d.setDraggingFrame(NSRect(x: p.x - size / 2 + o, y: p.y - size / 2 - o, width: size, height: size),
                               contents: item.icon)
            return d
        }
        onBegan()
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        let done = active
        active = []
        onEnded(done, !operation.isEmpty)
    }
}
