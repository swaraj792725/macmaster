import SwiftUI
import AppKit

/// Drop Shelf menu bar item. Shows the item count, opens a popover on click, and accepts drops
/// (files, images, text) straight onto the icon. Redraws only when the count or drop-target state changes.
@MainActor
final class DropShelfMenuBar: NSObject, NSPopoverDelegate {
    static let shared = DropShelfMenuBar()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var drawnCount = -1
    private var targeted = false

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Creates or removes the status item to match the setting. Idempotent.
    func update() {
        if DropShelfSettings.shared.showInMenuBar {
            if item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                it.autosaveName = "MacMaster.shelf"
                if let b = it.button {
                    b.target = self
                    b.action = #selector(clicked)
                    b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    b.setAccessibilityLabel("MacMaster Drop Shelf")
                    let drop = DropShelfStatusDropView(frame: b.bounds)
                    drop.autoresizingMask = [.width, .height]
                    drop.onTargeted = { [weak self] in self?.setTargeted($0) }
                    drop.onDrop = { pb in DropShelf.shared.addFromPasteboard(pb) }
                    b.addSubview(drop)
                }
                item = it
            }
            refresh(force: true)
        } else if let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            drawnCount = -1
            targeted = false
        }
    }

    /// Item count changed (called from the shelf's change hook).
    func refresh(force: Bool = false) {
        guard let b = item?.button else { return }
        let count = DropShelf.shared.model.items.count
        guard force || count != drawnCount else { return }
        drawnCount = count
        draw(b, count: count)
    }

    private func draw(_ b: NSStatusBarButton, count: Int) {
        let name = targeted ? "tray.and.arrow.down.fill" : (count > 0 ? "tray.full.fill" : "tray")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Drop Shelf")
        img?.isTemplate = true
        b.image = img
        if count > 0 {
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            b.title = " \(count)"
            b.imagePosition = .imageLeading
        } else {
            b.title = ""
            b.imagePosition = .imageOnly
        }
    }

    private func setTargeted(_ on: Bool) {
        guard targeted != on, let b = item?.button else { return }
        targeted = on
        b.isHighlighted = on
        draw(b, count: DropShelf.shared.model.items.count)
    }

    // MARK: Click handling

    @objc private func clicked() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            showMenu()
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        let host = NSHostingController(rootView: DropShelfPopoverView(model: DropShelf.shared.model, onClose: { [weak self] in self?.close() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        DropShelf.shared.model.pruneMissing()
        popover.showFromStatusItem(button)
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    private func showMenu() {
        guard let it = item else { return }
        let count = DropShelf.shared.model.items.count
        let menu = NSMenu()
        let head = NSMenuItem(title: count == 0 ? "Shelf is empty" : "\(count) item\(count == 1 ? "" : "s") on the shelf", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Shelf", #selector(openShelf)))
        menu.addItem(menuItem("Paste from Clipboard", #selector(pasteClipboard)))
        let clear = menuItem("Clear Shelf", #selector(clearShelf))
        clear.isEnabled = count > 0
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(menuItem("Hide Menu Bar Icon", #selector(hideIcon)))
        it.menu = menu
        it.button?.performClick(nil)
        it.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func openShelf() { DropShelf.shared.openNow() }
    @objc private func pasteClipboard() { if !DropShelf.shared.addFromPasteboard() { NSSound.beep() } }
    @objc private func clearShelf() { DropShelf.shared.model.clear() }
    @objc private func hideIcon() { DropShelfSettings.shared.showInMenuBar = false }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

/// Transparent overlay on the status button that receives drops. Mouse events are handed to the button
/// so clicks and right-clicks behave exactly as before.
final class DropShelfStatusDropView: NSView {
    var onDrop: (NSPasteboard) -> Bool = { _ in false }
    var onTargeted: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func isAccessibilityElement() -> Bool { false }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }

    private func accepts(_ pb: NSPasteboard) -> Bool {
        let types = Set(pb.types ?? [])
        return !types.isDisjoint(with: [.fileURL, .png, .tiff, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started on the shelf itself.
        let internal_ = MainActor.assumeIsolated { DropShelf.shared.model.internalDragActive }
        guard !internal_, accepts(sender.draggingPasteboard) else { return [] }
        MainActor.assumeIsolated { onTargeted(true) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { onTargeted(false) } }
    override func draggingEnded(_ sender: NSDraggingInfo) { MainActor.assumeIsolated { onTargeted(false) } }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return MainActor.assumeIsolated {
            onTargeted(false)
            let ok = onDrop(pb)
            DropShelf.shared.noteShelfDrop()
            return ok
        }
    }
}
