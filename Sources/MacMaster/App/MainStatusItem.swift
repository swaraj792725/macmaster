import AppKit
import SwiftUI

/// MacMaster's own menu bar icon with the quick panel popover.
/// AppKit-based on purpose: SwiftUI's MenuBarExtra re-renders the whole app scene graph.
@MainActor
final class MainStatusItem: NSObject, NSPopoverDelegate {
    static let shared = MainStatusItem()
    private var item: NSStatusItem?
    private let popover = NSPopover()

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// The dropdown is MacMaster's Control Center: one popover, whichever icon opened it.
    var isShown: Bool { popover.isShown }

    func update() {
        let show = UserDefaults.standard.object(forKey: "mm.app.showMenuBarIcon") as? Bool ?? true
        if show, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = it.button { MenuBarIconUpdater.shared.attach(to: button, statusItem: it) }
            it.button?.target = self
            it.button?.action = #selector(buttonClicked)
            item = it
        } else if !show, let it = item {
            popover.performClose(nil)
            MenuBarIconUpdater.shared.detach()
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc private func buttonClicked() {
        guard let button = item?.button else { return }
        toggle(from: button)
    }

    /// Opens or closes the dropdown under `view` (this item's button, the optional extra icon, or the
    /// anchor window over Apple's Control Center icon).
    func toggle(from view: NSView) {
        if popover.isShown { popover.performClose(nil) } else { present(from: view) }
    }

    func present(from view: NSView) {
        // A fresh hosting controller per open: the view resets (edit mode off) and appear/disappear fire reliably.
        let host = NSHostingController(rootView: MenuBarControlCenter())
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: MenuBarControlCenter.width, height: MenuBarControlCenter.initialHeight)
        popover.contentViewController = host
        popover.showFromStatusItem(view)
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        ControlCenterModel.shared.closed()
        AppleItemRedirect.shared.anchorDone()
    }
}

/// Opens / focuses the main window from AppKit code.
@MainActor
enum MainWindow {
    static func show(section: AppSection? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "MacMaster" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
        if let section { NotificationCenter.default.post(name: .openSection, object: section.rawValue) }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("MacMaster.openMainWindow")
}
