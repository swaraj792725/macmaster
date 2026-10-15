import SwiftUI
import AppKit

/// Status item showing the time, plus a transient popover. The title is only rewritten when the string changes,
/// and the timer fires once per minute (or second, if seconds are shown) exactly on the boundary.
@MainActor
final class ClockMenuBar: NSObject, NSPopoverDelegate {
    static let shared = ClockMenuBar()
    private var item: NSStatusItem?
    private var timer: Timer?
    private var lastTitle = ""
    private var observing = false
    private let popover = NSPopover()

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    // MARK: Lifecycle

    /// Creates or removes the status item to match the setting. Idempotent.
    func update() {
        if ClockSettings.shared.showInMenuBar && !AppleItemRedirect.shared.replacesClockIcon {
            if item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let b = it.button {
                    b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    b.imagePosition = .noImage
                    b.target = self
                    b.action = #selector(toggle)
                }
                item = it
                observe()
            }
            ClockNextEvent.shared.sync()
            refresh(force: true)
            schedule()
        } else if let it = item {
            popover.performClose(nil)
            timer?.invalidate(); timer = nil
            unobserve()
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            lastTitle = ""
        }
    }

    /// A setting that affects the title changed.
    func settingsChanged() {
        guard item != nil else { return }
        ClockNextEvent.shared.sync()
        refresh(force: true)
        schedule()
    }

    /// The cached next event changed; redraw the title.
    func titleChanged() {
        guard item != nil else { return }
        refresh(force: true)
    }

    // MARK: Title

    private func refresh(force: Bool = false) {
        guard let b = item?.button else { return }
        let s = ClockSettings.shared
        let now = Date()
        let title = ClockFormatter.shared.string(for: now, settings: s) + ClockNextEvent.shared.titleSuffix(now: now)
        guard force || title != lastTitle else { return }
        lastTitle = title
        b.title = title
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard item != nil else { return }
        let s = ClockSettings.shared
        let step: TimeInterval = ClockFormatter.patternShowsSeconds(ClockFormatter.pattern(s)) ? 1 : 60
        let now = Date().timeIntervalSince1970
        let next = (now / step).rounded(.down) * step + step + 0.05   // just past the boundary
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                ClockMenuBar.shared.refresh()
                ClockMenuBar.shared.schedule()
            }
        }
        t.tolerance = step > 1 ? 0.5 : 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: System notifications

    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        for n in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            nc.addObserver(self, selector: #selector(clockChanged), name: n, object: nil)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screenSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(clockChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(clockChanged), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func unobserve() {
        guard observing else { return }
        observing = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Notifications may arrive on any thread; hop to the main actor before touching UI.
    @objc private nonisolated func clockChanged() {
        Task { @MainActor in
            NSTimeZone.resetSystemTimeZone()
            ClockMenuBar.shared.refresh(force: true)
            ClockMenuBar.shared.schedule()
        }
    }

    @objc private nonisolated func screenSlept() {
        Task { @MainActor in ClockMenuBar.shared.timer?.invalidate(); ClockMenuBar.shared.timer = nil }
    }

    // MARK: Popover

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        showPopover(from: button)
    }

    var isPopoverShown: Bool { popover.isShown }

    /// Opens the popover under any view (used when Apple's own clock click is redirected here).
    func showPopover(from view: NSView) {
        NSTimeZone.resetSystemTimeZone()
        let host = NSHostingController(rootView: ClockPopoverView())
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: ClockPopoverView.width, height: ClockPopoverView.height)
        popover.contentViewController = host
        popover.showFromStatusItem(view)
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
