import SwiftUI
import AppKit

/// Owns one NSStatusItem per enabled module, redraws them each monitor tick and shows detail popovers.
@MainActor
final class StatsMenuBarController: NSObject, NSPopoverDelegate {
    static let shared = StatsMenuBarController()

    private var items: [StatsModule: NSStatusItem] = [:]
    private var signatures: [StatsModule: String] = [:]
    private var darkFlags: [StatsModule: Bool] = [:]
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var defaultsObserver: NSObjectProtocol?
    private var running = false

    private var popover: NSPopover?
    private var popoverModule: StatsModule?
    private var popoverHoldsProcesses = false

    private override init() { super.init() }

    // MARK: lifecycle

    func start() {
        guard !running else { return }
        running = true
        StatsSettings.applyStoredInterval()
        SystemMonitor.shared.start()
        BatteryMonitor.shared.start()
        BatteryAlerts.shared.start()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            // Never block the posting thread: a background defaults write would otherwise wait on main (deadlock).
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil
        timer?.invalidate(); timer = nil; timerInterval = 0
        closePopover()
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items.removeAll(); signatures.removeAll(); darkFlags.removeAll()
    }

    // MARK: updating

    private func scheduleTimerIfNeeded() {
        let interval = max(0.5, SystemMonitor.shared.interval)
        guard timer == nil || interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func wanted(_ m: StatsModule) -> Bool {
        guard StatsSettings.enabled(m) else { return false }
        if m == .battery { return BatteryMonitor.shared.reading.isPresent }
        return true
    }

    private func tick() {
        guard running else { return }
        scheduleTimerIfNeeded()

        // Add / remove items to match settings.
        for module in StatsModule.allCases {
            let want = wanted(module)
            if want, items[module] == nil {
                items[module] = makeItem(module)
            } else if !want, let item = items.removeValue(forKey: module) {
                if popoverModule == module { closePopover() }
                NSStatusBar.system.removeStatusItem(item)
                signatures[module] = nil; darkFlags[module] = nil
            }
        }

        // Redraw only items whose content changed.
        for (module, item) in items {
            guard let button = item.button else { continue }
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let model = StatsBarModel.make(module)
            let sig = model.signature
            if signatures[module] == sig, darkFlags[module] == dark { continue }
            signatures[module] = sig; darkFlags[module] = dark
            button.image = StatsBarRenderer.image(for: model, dark: dark)
        }
    }

    private func makeItem(_ module: StatsModule) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MacMaster.stats.\(module.rawValue)"
        if let b = item.button {
            b.target = self
            b.action = #selector(itemClicked(_:))
            b.identifier = NSUserInterfaceItemIdentifier(module.rawValue)
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel("MacMaster \(module.title)")
        }
        return item
    }

    // MARK: popover

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let module = StatsModule(rawValue: raw) else { return }
        if popover?.isShown == true, popoverModule == module {
            closePopover()
            return
        }
        closePopover()

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        let host = NSHostingController(rootView: StatsPopoverView(module: module, onOpen: { [weak self] in self?.closePopover() }))
        host.sizingOptions = [.preferredContentSize]
        pop.contentViewController = host
        popover = pop
        popoverModule = module
        SystemMonitor.shared.requestProcesses()
        popoverHoldsProcesses = true
        pop.showFromStatusItem(sender)
    }

    private func closePopover() {
        popover?.performClose(nil)
        releaseProcessesIfNeeded()
        popover = nil
        popoverModule = nil
    }

    private func releaseProcessesIfNeeded() {
        if popoverHoldsProcesses {
            popoverHoldsProcesses = false
            SystemMonitor.shared.releaseProcesses()
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        let closed = (notification.object as? NSPopover).map(ObjectIdentifier.init)
        Task { @MainActor in
            // Ignore stale callbacks from a popover we already replaced.
            guard closed == nil || closed == self.popover.map(ObjectIdentifier.init) else { return }
            self.releaseProcessesIfNeeded()
            self.popover = nil
            self.popoverModule = nil
        }
    }
}
