import SwiftUI
import AppKit

/// Wi-Fi menu bar item that can stand in for Apple's. Click opens the popover; right-click opens a quick menu.
/// Redraws only when the rendered picture would change, and only reads the link on a slow timer / link events.
@MainActor
final class WiFiMenuBar: NSObject, NSPopoverDelegate {
    static let shared = WiFiMenuBar()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var signature = ""
    private var darkFlag: Bool?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Creates, updates or removes the status item to match settings. Idempotent; call on launch and after any setting change.
    func update() {
        let model = WiFiModel.shared
        if WiFiSettings.enabled {
            if item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                it.autosaveName = "MacMaster.wifi"
                if let b = it.button {
                    b.target = self
                    b.action = #selector(clicked)
                    b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    b.imagePosition = .imageOnly
                    b.setAccessibilityLabel("MacMaster Wi-Fi")
                }
                item = it
                model.onUpdate = { [weak self] in self?.redraw() }
            }
            if WiFiSettings.style.showsSpeed { SystemMonitor.shared.start() }
            model.setBarActive(true)
            redraw(force: true)
        } else if let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            signature = ""
            darkFlag = nil
            model.onUpdate = nil
            model.setBarActive(false)
        }
    }

    private func redraw(force: Bool = false) {
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let state = WiFiBarState.make(link: WiFiModel.shared.link, style: WiFiSettings.style)
        let sig = state.signature
        if !force, sig == signature, darkFlag == dark { return }
        signature = sig
        darkFlag = dark
        button.image = WiFiBarRenderer.image(for: state, dark: dark)
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
        let height = min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
        popover.contentSize = NSSize(width: 384, height: height)
        popover.contentViewController = NSHostingController(rootView: WiFiPopoverView(onClose: { [weak self] in self?.close() }))
        popover.showFromStatusItem(button)
    }

    func close() { popover.performClose(nil) }

    private func showMenu() {
        guard let it = item else { return }
        let l = WiFiModel.shared.link
        let menu = NSMenu()
        let head = NSMenuItem(title: l.isConnected ? (l.ssid ?? "Wi-Fi") + " · " + l.quality : l.quality, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(menuItem(l.powerOn ? "Turn Wi-Fi Off" : "Turn Wi-Fi On", #selector(togglePower)))
        menu.addItem(menuItem("Open Wi-Fi Settings…", #selector(openSettings)))
        menu.addItem(menuItem("Network Diagnostics…", #selector(openDiagnostics)))
        let dark = it.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let styles = NSMenu()
        for st in WiFiIconStyle.allCases {
            let m = NSMenuItem(title: st.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = st.rawValue
            m.state = st == WiFiSettings.style ? .on : .off
            if let img = WiFiBarRenderer.image(for: WiFiBarState.sample(style: st), dark: dark) {
                // Preview at menu text height; template previews tint themselves, colored ones keep their colors.
                let h: CGFloat = 14
                img.size = NSSize(width: img.size.width * h / max(img.size.height, 1), height: h)
                m.image = img
            }
            styles.addItem(m)
        }
        let styleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styles
        menu.addItem(.separator())
        menu.addItem(styleItem)
        it.menu = menu
        it.button?.performClick(nil)
        it.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: WiFiSettings.styleKey)
        update()
    }
    @objc private func togglePower() { WiFiModel.shared.setPower(!WiFiModel.shared.link.powerOn) }
    @objc private func openSettings() { WiFiModel.openWiFiSettings() }
    @objc private func openDiagnostics() { WiFiModel.openDiagnostics() }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
