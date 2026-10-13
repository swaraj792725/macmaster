import SwiftUI
import AppKit

/// Optional extra menu bar icon. It opens the same dropdown as MacMaster's main icon (there is no second popover).
/// Off by default; also owns the Apple click-redirect lifecycle so it follows the settings.
@MainActor
final class ControlCenterMenuBar: NSObject {
    static let shared = ControlCenterMenuBar()
    private var item: NSStatusItem?
    private var shownSymbol: String?
    private let settings = ControlCenterSettings.shared

    private override init() { super.init() }

    /// Creates, updates or removes the extra status item to match the settings. Idempotent.
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
                let img = NSImage(systemSymbolName: settings.icon.symbol, accessibilityDescription: "MacMaster Control Center")
                img?.isTemplate = true
                it.button?.image = img
                shownSymbol = settings.icon.symbol
            }
        } else if let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            shownSymbol = nil
        }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        MainStatusItem.shared.toggle(from: button)
    }

    func close() { MainStatusItem.shared.close() }
}
