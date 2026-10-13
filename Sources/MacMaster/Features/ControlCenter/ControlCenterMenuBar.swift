import SwiftUI
import AppKit

/// Status item + transient popover for the Control Center replacement.
@MainActor
final class ControlCenterMenuBar: NSObject, NSPopoverDelegate {
    static let shared = ControlCenterMenuBar()
    private var item: NSStatusItem?
    private var shownSymbol: String?
    private let popover = NSPopover()
    private let settings = ControlCenterSettings.shared

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Creates, updates or removes the status item to match the settings. Idempotent.
    func update() {
        AppleItemRedirect.shared.update()
        if settings.showInMenuBar {
            let it = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if item == nil {
                it.button?.target = self
                it.button?.action = #selector(toggle)
                item = it
            }
            if shownSymbol != settings.icon.symbol {
                let img = NSImage(systemSymbolName: settings.icon.symbol, accessibilityDescription: "Control Center")
                img?.isTemplate = true
                it.button?.image = img
                shownSymbol = settings.icon.symbol
            }
        } else if let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            shownSymbol = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        present(from: button)
    }

    var isPopoverShown: Bool { popover.isShown }

    /// Opens the popover under any view (our status item, or the anchor over Apple's Control Center icon).
    func present(from view: NSView) {
        ControlCenterModel.shared.opened()
        let host = NSHostingController(rootView: ControlCenterPopoverView())
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: ControlCenterPopoverView.width, height: ControlCenterPopoverView.estimatedHeight())
        popover.contentViewController = host
        popover.showFromStatusItem(view)
    }

    /// Closes it if open. Returns true when it was.
    @discardableResult
    func closeIfShown() -> Bool {
        guard popover.isShown else { return false }
        popover.performClose(nil)
        return true
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        ControlCenterModel.shared.closed()
        AppleItemRedirect.shared.anchorDone()
    }
}
