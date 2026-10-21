import AppKit

/// Boxes a closure so it can ride on `NSMenuItem.representedObject`.
final class TimerMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// Status item with the soonest timer's remaining time. It only exists while a timer is running or paused.
/// The title is rewritten only when the text changes; the engine drives updates (no timer of its own).
@MainActor
final class TimerMenuBar: NSObject, NSMenuDelegate {
    static let shared = TimerMenuBar()
    private var item: NSStatusItem?
    private var lastTitle = ""
    private let menu = NSMenu()

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Creates, refreshes or removes the status item. Cheap and idempotent.
    func update() {
        let engine = TimerEngine.shared
        let show = TimerPrefs.bool(TimerPrefs.menuBar, true) && engine.hasActiveTimers && !Services.isSnapshotRun
        guard show else {
            if let it = item {
                NSStatusBar.system.removeStatusItem(it)
                item = nil
                lastTitle = ""
            }
            return
        }
        if item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let b = it.button {
                b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timer")
                img?.isTemplate = true
                b.image = img
                b.imagePosition = .imageLeading
            }
            it.menu = menu
            item = it
        }
        let title = Self.title(engine)
        guard title != lastTitle else { return }
        lastTitle = title
        item?.button?.title = " " + title
    }

    private static func title(_ e: TimerEngine) -> String {
        guard let t = e.soonest() else { return "" }
        let running = e.timers.filter { $0.status == .running }.count
        var s = TimerFormat.clock(t.remaining())
        if t.status == .paused { s = "‖ " + s }
        if running > 1 { s += " +\(running - 1)" }
        return s
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let e = TimerEngine.shared
        let now = Date()
        for t in e.timers {
            let value = t.status == .finished ? "Done" : TimerFormat.clock(t.remaining(at: now)) + (t.status == .paused ? " (paused)" : "")
            let row = NSMenuItem(title: "\(t.label)  \(value)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            switch t.status {
            case .running: sub.addItem(action("Pause") { e.pause(t.id) })
            case .paused: sub.addItem(action("Resume") { e.resume(t.id) })
            case .finished: sub.addItem(action("Restart") { e.restart(t.id) })
            }
            if t.status != .finished { sub.addItem(action("Add 1 minute") { e.addMinute(t.id) }) }
            sub.addItem(action(t.status == .finished ? "Remove" : "Cancel") { e.cancel(t.id) })
            row.submenu = sub
            menu.addItem(row)
        }
        if e.swHasTime {
            if !e.timers.isEmpty { menu.addItem(.separator()) }
            let row = NSMenuItem(title: "Stopwatch  \(TimerFormat.stopwatch(e.swElapsed()))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(action(e.swRunning ? "Stop" : "Start") { e.swStartStop() })
            if e.swRunning { sub.addItem(action("Lap") { e.swLap() }) }
            sub.addItem(action("Reset") { e.swReset() })
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let quick = NSMenuItem(title: "Start a timer", action: nil, keyEquivalent: "")
        let qsub = NSMenu()
        qsub.autoenablesItems = false
        for m in [1, 5, 10, 25] {
            qsub.addItem(action("\(m) min") { e.startTimer(duration: TimeInterval(m * 60)) })
        }
        quick.submenu = qsub
        menu.addItem(quick)
        menu.addItem(action("Open Timer…") { Self.openTool() })
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = TimerMenuAction(run)
        return it
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? TimerMenuAction)?.run()
    }

    static func openTool() {
        AppSearchRouter.shared.request(anchor: nil, tab: "timer")
        MainWindow.show(section: .tools)
    }
}
