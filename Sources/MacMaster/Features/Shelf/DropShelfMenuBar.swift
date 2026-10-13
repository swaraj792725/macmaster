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
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// A mouse-down outside our windows is pending; it only closes the popover if it ends without a drag.
    private var outsidePressed = false
    private var outsideDragged = false
    /// Drag-pasteboard change count at the outside mouse-down: a new drag (another app's file or screenshot
    /// thumbnail) bumps it even if no dragged events reach us, so the press still counts as a drag.
    private var pressDragCount = 0
    private let dragPasteboard = NSPasteboard(name: .drag)

    var isOpen: Bool { popover.isShown }

    private override init() {
        super.init()
        // .transient would close the moment the user clicks in Finder to start a drag; closing is handled below.
        popover.behavior = .applicationDefined
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
                    drop.onTargeted = { [weak self] in self?.setTargeted($0) }
                    drop.onDrop = { pb in DropShelf.shared.addFromPasteboard(pb) }
                    drop.onClick = { [weak self] right in self?.handleClick(right: right) }
                    b.addSubview(drop)
                    // The button has no size yet; pin the overlay to its edges so it always covers it.
                    drop.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        drop.leadingAnchor.constraint(equalTo: b.leadingAnchor),
                        drop.trailingAnchor.constraint(equalTo: b.trailingAnchor),
                        drop.topAnchor.constraint(equalTo: b.topAnchor),
                        drop.bottomAnchor.constraint(equalTo: b.bottomAnchor),
                    ])
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

    /// Fallback for the button's own action (accessibility press); real clicks arrive via the overlay.
    @objc private func clicked() {
        handleClick(right: NSApp.currentEvent?.type == .rightMouseUp)
    }

    private func handleClick(right: Bool) {
        guard let button = item?.button else { return }
        if right {
            close()
            showMenu(from: button)
            return
        }
        if popover.isShown { close(); return }
        let host = NSHostingController(rootView: DropShelfPopoverView(model: DropShelf.shared.model, onClose: { [weak self] in self?.close() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        DropShelf.shared.model.pruneMissing()
        popover.showFromStatusItem(button)
        installMonitors()
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    private func showMenu(from button: NSView) {
        let count = DropShelf.shared.model.items.count
        let menu = NSMenu()
        menu.autoenablesItems = false
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
        removeMonitors()
        popover.contentViewController = nil
    }

    // MARK: Closing rules

    /// Closes on Esc, on a click in another window of ours, or on a plain click elsewhere. A press that turns
    /// into a drag (the user grabbing a file in Finder) leaves the popover open so it can be dropped onto.
    /// Monitors exist only while the popover is shown.
    private func installMonitors() {
        removeMonitors()
        outsidePressed = false; outsideDragged = false
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.outsideEvent(type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let type = event.type, code = event.keyCode, window = event.window
            let swallow = MainActor.assumeIsolated { self.localEvent(type, code, window) }
            return swallow ? nil : event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        outsidePressed = false; outsideDragged = false
    }

    private func outsideEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: outsidePressed = true; outsideDragged = false; pressDragCount = dragPasteboard.changeCount
        case .leftMouseDragged: if outsidePressed { outsideDragged = true }
        case .leftMouseUp:
            if outsidePressed && !outsideDragged && dragPasteboard.changeCount == pressDragCount { close() }
            outsidePressed = false
        default: close()
        }
    }

    /// True if the event is consumed.
    private func localEvent(_ type: NSEvent.EventType, _ keyCode: UInt16, _ window: NSWindow?) -> Bool {
        if type == .keyDown {
            guard keyCode == 53, popover.isShown else { return false }
            close()
            return true
        }
        if window == nil || window === popover.contentViewController?.view.window || window === item?.button?.window { return false }
        close()
        return false
    }
}

/// Transparent overlay covering the status button. It takes the drops and also handles the clicks itself
/// (left toggles the popover, right or control-click opens the menu), so nothing depends on how the
/// button would forward events.
final class DropShelfStatusDropView: NSView {
    var onDrop: (NSPasteboard) -> Bool = { _ in false }
    var onTargeted: (Bool) -> Void = { _ in }
    var onClick: (_ right: Bool) -> Void = { _ in }

    /// Includes file promises (the floating screenshot thumbnail, Photos, Mail).
    private static let dragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.dragTypes)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var button: NSStatusBarButton? { superview as? NSStatusBarButton }

    override func mouseDown(with event: NSEvent) { button?.isHighlighted = true }
    override func rightMouseDown(with event: NSEvent) { button?.isHighlighted = true }

    override func mouseUp(with event: NSEvent) { finish(event, right: event.modifierFlags.contains(.control)) }
    override func rightMouseUp(with event: NSEvent) { finish(event, right: true) }

    private func finish(_ event: NSEvent, right: Bool) {
        button?.isHighlighted = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        MainActor.assumeIsolated { onClick(right) }
    }

    private func accepts(_ pb: NSPasteboard) -> Bool {
        let types = Set(pb.types ?? [])
        return !types.isDisjoint(with: Self.dragTypes)
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
