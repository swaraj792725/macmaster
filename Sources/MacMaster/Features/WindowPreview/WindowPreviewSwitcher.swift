import AppKit
import CoreGraphics
import SwiftUI
import os

// MARK: - Native ⌘Tab suppression

/// Belt and braces for ⌘Tab: besides consuming the keys in the event tap we switch off the system's
/// own symbolic hotkeys (⌘Tab, ⌘⇧Tab, ⌘`) through the private-but-stable CGS API, like AltTab does.
/// A defaults flag remembers that we did, so a crash can be healed on the next launch.
@MainActor
enum WindowPreviewNativeSwitcher {
    private typealias SetFn = @convention(c) (Int32, Bool) -> Int32
    private static let setFn: SetFn? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()
    private static let ids: [Int32] = [1, 2, 6]   // ⌘Tab, ⌘⇧Tab, ⌘`
    private static let flagKey = "mm.windows.nativeSwitcherSuppressed"
    private static var suppressed = false

    static func setSuppressed(_ on: Bool) {
        if on == suppressed { return }
        guard let fn = setFn else { return }
        suppressed = on
        for id in ids { _ = fn(id, !on) }
        UserDefaults.standard.set(on, forKey: flagKey)
    }

    /// Re-enable the system shortcuts if a previous run died while they were suppressed.
    static func healIfNeeded() {
        guard !suppressed, UserDefaults.standard.bool(forKey: flagKey), let fn = setFn else { return }
        for id in ids { _ = fn(id, true) }
        UserDefaults.standard.set(false, forKey: flagKey)
    }
}

// MARK: - Event tap (background thread)

enum WindowPreviewSwitcherCommand: Sendable {
    case begin(reverse: Bool, currentApp: Bool)
    case next, previous, up, down
    case commit, cancel
    case quitApp, closeWindow, minimizeWindow, hideApp, fullscreen
    /// Cmd+Shift+3/4/5/6 went through: keep the panel up (no commit) while the screenshot UI runs.
    case screenshot
}

private let switcherTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<WindowPreviewSwitcherTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

/// Consumes the switcher hotkey (⌘Tab, ⌘⇧Tab, ⌘`, or ⌥/⌃Tab) and every key while the switcher is open.
/// Runs a session-level active tap, which sits in front of the system's ⌘Tab handling.
final class WindowPreviewSwitcherTap: @unchecked Sendable {
    private let shortcut: OSAllocatedUnfairLock<WindowPreviewSwitcherShortcut>
    private let onCommand: @Sendable (WindowPreviewSwitcherCommand) -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private let activeFlag = OSAllocatedUnfairLock(initialState: false)
    /// Key codes whose keyDown we swallowed; their keyUp is swallowed too (tap thread only).
    private var swallowed = Set<Int64>()
    private let doneSem = DispatchSemaphore(value: 0)

    private var active: Bool {
        get { activeFlag.withLock { $0 } }
        set { activeFlag.withLock { $0 = newValue } }
    }

    init(shortcut: OSAllocatedUnfairLock<WindowPreviewSwitcherShortcut>,
         onCommand: @escaping @Sendable (WindowPreviewSwitcherCommand) -> Void) {
        self.shortcut = shortcut
        self.onCommand = onCommand
    }

    /// The main side ended the session (click, empty list...): stop swallowing keys.
    func deactivate() { active = false }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let ok = OSAllocatedUnfairLock(initialState: false)
        let th = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            ok.withLock { $0 = install() }
            ready.signal()
            if ok.withLock({ $0 }) { CFRunLoopRun() }
            doneSem.signal()
        }
        th.name = "MacMaster.SwitcherTap"
        th.qualityOfService = .userInteractive
        th.start()
        _ = ready.wait(timeout: .now() + 3)
        if !ok.withLock({ $0 }) {
            _ = doneSem.wait(timeout: .now() + 1)
            return false
        }
        return true
    }

    func stop() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let src = source { CFRunLoopRemoveSource(rl, src, .commonModes); CFRunLoopSourceInvalidate(src) }
            if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
            source = nil
            tap = nil
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
        _ = doneSem.wait(timeout: .now() + 1.5)
        runLoop = nil
        if active { active = false; onCommand(.cancel) }
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: switcherTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) else {
            CFMachPortInvalidate(t)
            return false
        }
        tap = t
        source = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    // Key codes (ANSI): Tab 48, ` 50 (ISO § 10), Esc 53, Return 36 / keypad Enter 76, arrows 123-126.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let flags = event.flags
        let current = shortcut.withLock { $0 }
        let mod = current.modifier

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turned the tap off (a callback took too long). Turn it back on right away;
            // events may have been lost meanwhile, so drop any open session.
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            swallowed.removeAll()
            if active { active = false; onCommand(.cancel) }
            return pass

        case .flagsChanged:
            if active, !flags.contains(mod) {
                active = false
                onCommand(.commit)
            }
            return pass

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if swallowed.remove(code) != nil { return nil }
            return active ? nil : pass

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let shift = flags.contains(.maskShift)
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let aboveTab = code == 50 || code == 10

            if !active {
                guard code == 48 || (aboveTab && current == .commandTab) else { return pass }
                let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
                guard flags.intersection(relevant) == mod else { return pass }
                active = true
                swallowed.insert(code)
                onCommand(.begin(reverse: shift, currentApp: aboveTab))
                return nil
            }

            // Modifier already released but we missed the flagsChanged: finish and let the key through.
            guard flags.contains(mod) else {
                active = false
                onCommand(.commit)
                return pass
            }
            // System screenshot shortcuts must reach macOS; stop tracking so releasing Cmd doesn't switch apps.
            if flags.contains([.maskCommand, .maskShift]), [20, 21, 22, 23].contains(code) {
                active = false
                onCommand(.screenshot)
                return pass
            }
            swallowed.insert(code)
            switch code {
            case 48, 50, 10: onCommand(shift ? .previous : .next)
            case 123: onCommand(.previous)
            case 124: onCommand(.next)
            case 125: onCommand(.down)
            case 126: onCommand(.up)
            case 53 where !repeating: active = false; onCommand(.cancel)
            case 36 where !repeating, 76 where !repeating: active = false; onCommand(.commit)
            case 12 where !repeating: onCommand(.quitApp)          // Q
            case 13 where !repeating: onCommand(.closeWindow)      // W
            case 46 where !repeating: onCommand(.minimizeWindow)   // M
            case 4 where !repeating: onCommand(.hideApp)           // H
            case 3 where !repeating: onCommand(.fullscreen)        // F
            default: break
            }
            return nil

        default:
            return pass
        }
    }
}

// MARK: - Switcher controller (main actor)

@MainActor
final class WindowPreviewSwitcher {
    private enum Mode { case allApps, currentApp }

    private let model = WindowPreviewSwitcherModel()
    private var panel: WindowPreviewPanel?
    private var tap: WindowPreviewSwitcherTap?
    private var terminateObserver: NSObjectProtocol?
    private var showObserver: NSObjectProtocol?
    private var stickyMonitors: [Any] = []
    private var screenshotWatch: Task<Void, Never>?

    private var session = 0
    private var sessionActive = false
    private var loading = false
    private var commitRequested = false
    private var pending: [WindowPreviewSwitcherCommand] = []
    private var pendingReverse = false
    private var mode = Mode.allApps
    private var frontPID: pid_t?
    private var panelShown = false

    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var revalidateTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var nearbyTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    var isRunning: Bool { tap != nil }

    // MARK: Lifecycle

    func start() -> Bool {
        guard tap == nil else { return true }
        WindowPreviewNativeSwitcher.healIfNeeded()
        WindowPreviewWindowCache.shared.start()
        let t = WindowPreviewSwitcherTap(shortcut: WindowPreviewSettings.shared.shortcutBox) { [weak self] cmd in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(cmd) } }
        }
        guard t.start() else {
            WindowPreviewWindowCache.shared.stop()
            return false
        }
        tap = t
        wireModel()
        _ = ensurePanel()   // pre-warm the SwiftUI hosting view so the first show is instant
        syncSettings()
        if showObserver == nil {
            // Opened without a held modifier (e.g. a hot corner): stays open until click, Return or Esc.
            showObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("MacMaster.showSwitcher"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginSticky() }
            }
        }
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowPreviewNativeSwitcher.setSuppressed(false) }
            }
        }
        return true
    }

    func stop() {
        tap?.stop()
        tap = nil
        WindowPreviewNativeSwitcher.setSuppressed(false)
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        terminateObserver = nil
        if let o = showObserver { NotificationCenter.default.removeObserver(o) }
        showObserver = nil
        endSession(hide: false)
        hidePanel(immediately: true)
        WindowPreviewWindowCache.shared.stop()
    }

    /// Settings changed while running (shortcut etc.).
    func syncSettings() {
        guard tap != nil else { return }
        WindowPreviewNativeSwitcher.setSuppressed(WindowPreviewSettings.shared.switcherShortcut == .commandTab)
    }

    private func wireModel() {
        model.onCommit = { [weak self] item in
            guard let self else { return }
            self.model.selectedID = item.id
            self.commitSelection()
        }
        model.onClose = { [weak self] item in self?.close(item) }
        model.onMinimize = { [weak self] item in self?.minimize(item) }
        model.onQuit = { [weak self] item in self?.quit(item.window.pid) }
    }

    // MARK: Commands

    private func handle(_ cmd: WindowPreviewSwitcherCommand) {
        switch cmd {
        case .begin(let reverse, let currentApp):
            begin(reverse: reverse, currentApp: currentApp)
        case .cancel:
            endSession(hide: true)
        case .screenshot:
            holdForScreenshot()
        case .commit:
            guard sessionActive else { return }
            if loading { commitRequested = true; return }
            commitSelection()
        default:
            guard sessionActive else { return }
            if loading { pending.append(cmd); return }
            apply(cmd)
        }
    }

    private func begin(reverse: Bool, currentApp: Bool) {
        session += 1
        let s = session
        sessionActive = true
        commitRequested = false
        pending = []
        pendingReverse = reverse
        mode = currentApp ? .currentApp : .allApps
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hideWork?.cancel(); hideWork = nil
        showWork?.cancel(); showWork = nil
        revalidateTask?.cancel()
        model.hasScreenRecording = Permissions.isGranted(.screenRecording)
        model.noteKeyboard()
        model.hoveredID = nil

        // Stale-while-revalidate: paint from the cached list right away, then re-read the windows.
        let cache = WindowPreviewWindowCache.shared
        loading = true
        if cache.hasData {
            let items = buildItems(cache.windows)
            if !items.isEmpty { present(items, delay: 0.04) }
        }
        revalidateTask = Task { [weak self] in
            let wins = await cache.refresh()
            self?.revalidated(wins, session: s)
        }
    }

    /// First presentation of a session.
    private func present(_ items: [WindowPreviewSwitcherItem], delay: TimeInterval) {
        loading = false
        model.setItems(items)
        var index = items.count > 1 ? 1 : 0
        if pendingReverse { index = items.count - 1 }
        model.selectedID = items[index].id
        let queued = pending
        pending = []
        for c in queued { apply(c) }
        guard sessionActive else { return }
        if commitRequested { commitSelection(); return }
        layoutPanel()
        scheduleShow(delay: delay)
        loadImages()
        startLiveRefresh()
    }

    private func revalidated(_ wins: [WindowPreviewWindow], session s: Int) {
        guard s == session, sessionActive else { return }
        let items = buildItems(wins)
        if items.isEmpty { endSession(hide: true); return }
        if loading || model.items.isEmpty {
            present(items, delay: 0)
            return
        }
        // Merge fresh data without disturbing the user's selection.
        let oldIndex = model.selectedIndex ?? 0
        let sel = model.selectedID
        model.setItems(items)
        if sel == nil || !items.contains(where: { $0.id == sel }) {
            model.selectedID = items[min(oldIndex, items.count - 1)].id
        }
        layoutPanel()
        loadImages()
    }

    // MARK: Items

    private func buildItems(_ all: [WindowPreviewWindow]) -> [WindowPreviewSwitcherItem] {
        let s = WindowPreviewSettings.shared
        let rec = WindowPreviewRecency.shared
        var hiddenCache: [pid_t: Bool] = [:]
        func isHidden(_ pid: pid_t) -> Bool {
            if let h = hiddenCache[pid] { return h }
            let h = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            hiddenCache[pid] = h
            return h
        }

        let pidsWithWindows = Set(all.map(\.pid))
        var list = all
        if !s.switcherIncludeHidden { list = list.filter { !$0.isMinimized && !isHidden($0.pid) } }
        if s.switcherCurrentSpaceOnly { list = list.filter { !$0.onOtherSpace } }
        if mode == .currentApp, let fp = frontPID { list = list.filter { $0.pid == fp } }

        var counts: [pid_t: Int] = [:]
        for w in list { counts[w.pid, default: 0] += 1 }

        var scored: [(item: WindowPreviewSwitcherItem, score: Double, order: Int)] = list.map { w in
            (WindowPreviewSwitcherItem(id: w.id, window: w, appWindowCount: counts[w.pid] ?? 1,
                                       appHidden: isHidden(w.pid), appOnly: false),
             rec.score(w), w.order)
        }

        if s.switcherShowAppsWithoutWindows, mode == .allApps {
            for app in WindowPreviewEnumerator.runningApps() where !pidsWithWindows.contains(app.pid) {
                let id = WindowPreviewSwitcherItem.appOnlyID(app.pid)
                let w = WindowPreviewWindow(id: id, pid: app.pid, title: app.name, appName: app.name, bundleID: app.bundleID,
                                            frame: .zero, isMinimized: false, isOnScreen: false, onOtherSpace: false,
                                            order: 30_000, ax: nil)
                scored.append((WindowPreviewSwitcherItem(id: id, window: w, appWindowCount: 1,
                                                         appHidden: isHidden(app.pid), appOnly: true),
                               rec.appScore(app.pid) - 1, 30_000))
            }
        }

        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        var items = scored.map(\.item)

        // The topmost on-screen window of the frontmost app is "current": always first.
        if let fp = frontPID {
            let candidates = items.indices.filter { items[$0].window.pid == fp && !items[$0].appOnly && items[$0].window.isOnScreen }
            if let i = candidates.min(by: { items[$0].window.order < items[$1].window.order }), i != 0 {
                items.insert(items.remove(at: i), at: 0)
            }
        }
        return items
    }

    // MARK: Apply

    private func apply(_ cmd: WindowPreviewSwitcherCommand) {
        let n = model.items.count
        guard n > 0 else { return }
        model.noteKeyboard()
        let i = model.selectedIndex ?? 0
        let cols = max(1, model.layout.columns)
        switch cmd {
        case .next: select(model.items[(i + 1) % n].id)
        case .previous: select(model.items[(i - 1 + n) % n].id)
        case .down:
            let j = i + cols
            select(model.items[j < n ? j : i % cols].id)
        case .up:
            let j = i - cols
            if j >= 0 { select(model.items[j].id) } else {
                let rows = (n + cols - 1) / cols
                var k = (rows - 1) * cols + i
                if k >= n { k -= cols }
                select(model.items[max(0, k)].id)
            }
        case .quitApp:
            if let it = model.selectedItem { quit(it.window.pid) }
        case .closeWindow:
            if let it = model.selectedItem { close(it) }
        case .minimizeWindow:
            if let it = model.selectedItem { minimize(it) }
        case .hideApp:
            if let it = model.selectedItem { toggleHide(it.window.pid) }
        case .fullscreen:
            fullscreenSelected()
        default: break
        }
    }

    private func select(_ id: UInt32) {
        guard model.selectedID != id else { return }
        model.selectedID = id
        refreshNearby()
    }

    private func close(_ item: WindowPreviewSwitcherItem) {
        guard !item.appOnly else { return }
        WindowPreviewActions.close(item.window)
        remove { $0.id == item.id }
    }

    private func quit(_ pid: pid_t) {
        WindowPreviewActions.quitApp(pid: pid)
        remove { $0.window.pid == pid }
    }

    private func minimize(_ item: WindowPreviewSwitcherItem) {
        guard !item.appOnly else { return }
        let now = WindowPreviewActions.toggleMinimize(item.window)
        var items = model.items
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].window.isMinimized = now
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.items = items }
        }
    }

    private func toggleHide(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let hide = !app.isHidden
        if hide { app.hide() } else { app.unhide() }
        var items = model.items
        for i in items.indices where items[i].window.pid == pid { items[i].appHidden = hide }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.items = items }
    }

    private func fullscreenSelected() {
        guard let target = model.selectedItem, !target.appOnly else { return }
        endSession(hide: true)
        WindowPreviewActions.focus(target.window)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            WindowPreviewActions.toggleFullscreen(target.window)
        }
    }

    private func remove(where match: (WindowPreviewSwitcherItem) -> Bool) {
        let oldIndex = model.selectedIndex ?? 0
        let wasSelected = model.selectedItem.map(match) ?? false
        let items = model.items.filter { !match($0) }
        if items.isEmpty { endSession(hide: true); return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            model.setItems(items)
            if wasSelected || model.selectedID == nil { model.selectedID = items[min(oldIndex, items.count - 1)].id }
        }
        layoutPanel()
    }

    private func commitSelection() {
        let target = model.selectedItem
        endSession(hide: true)
        if let target { WindowPreviewActions.focus(target.window) }
    }

    /// Ends the open session. `hide` fades the panel out.
    private func beginSticky() {
        guard !sessionActive else { return }
        begin(reverse: false, currentApp: false)
        let keys: (NSEvent) -> Bool = { [weak self] e in
            guard let self, self.sessionActive else { return false }
            let cmd: WindowPreviewSwitcherCommand?
            switch e.keyCode {
            case 53: cmd = .cancel
            case 36, 76, 49: cmd = .commit
            case 48: cmd = e.modifierFlags.contains(.shift) ? .previous : .next
            case 123: cmd = .previous
            case 124: cmd = .next
            case 125: cmd = .down
            case 126: cmd = .up
            default: cmd = nil
            }
            guard let cmd else { return false }
            self.handle(cmd)
            return true
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in _ = keys(e) }) { stickyMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in keys(e) ? nil : e }) { stickyMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.sessionActive else { return }
            self.handle(.cancel)
        }) { stickyMonitors.append(m) }
    }

    /// Keeps the panel on screen while the screenshot UI is up, then closes it without switching.
    private func holdForScreenshot() {
        guard sessionActive else { return }
        let s = session
        screenshotWatch?.cancel()
        screenshotWatch = Task { @MainActor [weak self] in
            var seen = false, idle = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.sessionActive, self.session == s else { return }
                if Self.screenshotUIVisible() { seen = true; idle = 0 } else { idle += 1 }
                // Gone after showing (capture done or Esc), or never showed up (instant capture, no thumbnail).
                if (seen && idle >= 2) || (!seen && idle >= 10) { self.endSession(hide: true); return }
            }
        }
    }

    private static func screenshotUIVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "screencaptureui" }
    }

    private func endSession(hide: Bool) {
        screenshotWatch?.cancel(); screenshotWatch = nil
        stickyMonitors.forEach { NSEvent.removeMonitor($0) }
        stickyMonitors = []
        sessionActive = false
        loading = false
        commitRequested = false
        pending = []
        revalidateTask?.cancel(); revalidateTask = nil
        imageTask?.cancel(); imageTask = nil
        nearbyTask?.cancel(); nearbyTask = nil
        liveTask?.cancel(); liveTask = nil
        showWork?.cancel(); showWork = nil
        tap?.deactivate()
        if hide { hidePanel(immediately: false) }
    }

    // MARK: Thumbnails

    /// Cached thumbnails first (instant), then fresh ones: the selected tile and its neighbours at
    /// full resolution, the rest at low resolution.
    private func loadImages() {
        imageTask?.cancel()
        guard model.hasScreenRecording else { return }
        let ids = model.items.filter { !$0.appOnly }.map(\.id)
        imageTask = Task { [weak self] in
            let cached = await WindowPreviewThumbnailer.shared.peekAll(ids)
            guard !Task.isCancelled, let self else { return }
            var fill: [UInt32: NSImage] = [:]
            for (id, c) in cached where self.model.images[id] == nil { fill[id] = WindowPreviewSwitcherModel.nsImage(c) }
            self.model.mergeImages(fill)
            await self.captureAround(full: true)
        }
    }

    private func refreshNearby() {
        nearbyTask?.cancel()
        guard model.hasScreenRecording else { return }
        nearbyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.captureAround(full: true)
        }
    }

    private func captureAround(full: Bool) async {
        let items = model.items.filter { !$0.appOnly && !$0.window.isMinimized && !$0.appHidden }
        guard let sel = model.selectedID, !items.isEmpty else { return }
        let center = items.firstIndex { $0.id == sel } ?? 0
        let ordered = items.enumerated().sorted { abs($0.offset - center) < abs($1.offset - center) }.map(\.element)
        let base = WindowPreviewSettings.shared.switcherSize.switcherSize
        let fullBox = CGSize(width: base.width * 2, height: base.height * 2)
        let lowBox = CGSize(width: base.width * 1.5, height: base.height * 1.5)
        let thumbs = WindowPreviewThumbnailer.shared

        await withTaskGroup(of: (UInt32, CGImage?).self) { group in
            var it = ordered.enumerated().makeIterator()
            func add(_ g: inout TaskGroup<(UInt32, CGImage?)>) -> Bool {
                guard let (rank, item) = it.next() else { return false }
                let near = rank < 3
                g.addTask { (item.id, await thumbs.capture(id: item.id, box: near ? fullBox : lowBox, maxAge: near ? 1.2 : 120)) }
                return true
            }
            var running = 0
            while running < 3, add(&group) { running += 1 }
            while let (id, img) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let img, model.items.contains(where: { $0.id == id }) {
                    model.mergeImages([id: WindowPreviewSwitcherModel.nsImage(img)])
                }
                _ = add(&group)
            }
        }
    }

    /// Keep the selected tile fresh while the switcher stays open.
    private func startLiveRefresh() {
        liveTask?.cancel()
        guard WindowPreviewSettings.shared.liveRefresh, model.hasScreenRecording else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, self.sessionActive, !Task.isCancelled else { return }
                guard let it = self.model.selectedItem, !it.appOnly, !it.window.isMinimized else { continue }
                let base = WindowPreviewSettings.shared.switcherSize.switcherSize
                if let img = await WindowPreviewThumbnailer.shared.capture(
                    id: it.id, box: CGSize(width: base.width * 2, height: base.height * 2), maxAge: 1.0) {
                    self.model.mergeImages([it.id: WindowPreviewSwitcherModel.nsImage(img)])
                }
            }
        }
    }

    // MARK: Panel

    private func mouseScreen() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layoutPanel() {
        let scr = mouseScreen()
        let l = WindowPreviewSwitcherLayout.compute(
            count: model.items.count, base: WindowPreviewSettings.shared.switcherSize.switcherSize,
            screen: scr.visibleFrame, footer: model.hasScreenRecording ? 0 : 30)
        if l != model.layout { model.layout = l }
        guard panelShown, let panel else { return }
        panel.setFrame(frame(for: l, on: scr), display: true)
    }

    private func frame(for l: WindowPreviewSwitcherLayout, on scr: NSScreen) -> NSRect {
        let vis = scr.visibleFrame
        let size = l.panelSize
        return NSRect(x: (vis.midX - size.width / 2).rounded(), y: (vis.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private func scheduleShow(delay: TimeInterval) {
        guard !panelShown, showWork == nil else { return }
        if delay <= 0 { showNow(); return }
        // A tiny delay avoids a flash when the user just taps ⌘Tab and lets go.
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showNow() } }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func showNow() {
        showWork = nil
        guard sessionActive, !model.items.isEmpty else { return }
        let p = ensurePanel()
        let scr = mouseScreen()
        let l = WindowPreviewSwitcherLayout.compute(
            count: model.items.count, base: WindowPreviewSettings.shared.switcherSize.switcherSize,
            screen: scr.visibleFrame, footer: model.hasScreenRecording ? 0 : 30)
        model.layout = l
        p.setFrame(frame(for: l, on: scr), display: true)
        panelShown = true
        p.orderFrontRegardless()
        if !model.visible { model.visible = true }
    }

    private func ensurePanel() -> WindowPreviewPanel {
        if let p = panel { return p }
        let p = WindowPreviewPanel()
        p.setContent(WindowPreviewSwitcherPanelView(model: model))
        p.onMiddleClick = { [weak self] in
            guard let self, let id = self.model.hoveredID,
                  let it = self.model.items.first(where: { $0.id == id }) else { return }
            self.close(it)
        }
        panel = p
        return p
    }

    private func hidePanel(immediately: Bool) {
        model.visible = false
        model.hoveredID = nil
        panelShown = false
        hideWork?.cancel()
        guard let panel else { return }
        if immediately {
            panel.orderOut(nil)
            model.reset()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.visible, !self.sessionActive else { return }
                self.panel?.orderOut(nil)
                self.model.reset()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }
}
