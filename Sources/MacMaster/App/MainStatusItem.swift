import AppKit
import SwiftUI

/// MacMaster's own menu bar icon with the quick panel popover.
/// AppKit-based on purpose: SwiftUI's MenuBarExtra re-renders the whole app scene graph.
@MainActor
final class MainStatusItem: NSObject, NSPopoverDelegate {
    static let shared = MainStatusItem()
    private var item: NSStatusItem?
    private let popover = NSPopover()

    func update() {
        let show = UserDefaults.standard.object(forKey: "mm.app.showMenuBarIcon") as? Bool ?? true
        if show, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = it.button { MenuBarIconUpdater.shared.attach(to: button, statusItem: it) }
            it.button?.target = self
            it.button?.action = #selector(toggle)
            item = it
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: MenuBarControlCenter())
        } else if !show, let it = item {
            MenuBarIconUpdater.shared.detach()
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.showFromStatusItem(button)
        }
    }

    func close() { popover.performClose(nil) }
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
