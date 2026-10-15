import SwiftUI
import AppKit

// MARK: - Overlay window

/// Click-through, never-key panel used for every on-screen overlay of this feature.
final class KeyboardOverlayWindow: NSPanel {
    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func hosting<V: View>(_ view: V, frame: NSRect, level: NSWindow.Level) -> KeyboardOverlayWindow {
        let w = KeyboardOverlayWindow(frame: frame, level: level)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        return w
    }
}

struct KeyboardGlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }
}

@MainActor
func keyboardActiveScreen() -> NSScreen {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Cleaning mode

@MainActor
@Observable
final class KeyboardCleaningModel {
    var remaining = 0
    var total = 60
    var holdProgress = 0.0
    /// No countdown: stays locked until the unlock combo is held.
    var untilShortcut = false
}

struct KeyboardCleaningOverlayView: View {
    let model: KeyboardCleaningModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 22) {
                Image(systemName: "keyboard")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Keyboard, mouse & trackpad are locked")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Wipe away. Nothing you press will be sent to any app.")
                    .font(.title3).foregroundStyle(.white.opacity(0.7))
                if model.untilShortcut {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 64, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 170, height: 170)
                        .background(Circle().stroke(.white.opacity(0.12), lineWidth: 10))
                } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 10)
                    Circle().trim(from: 0, to: CGFloat(model.total > 0 ? Double(model.remaining) / Double(model.total) : 0))
                        .stroke(Color(hex: 0x30D158), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: model.remaining)
                    Text("\(model.remaining)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                .frame(width: 170, height: 170)
                }
                VStack(spacing: 8) {
                    Text(model.untilShortcut ? "To unlock, hold ⌘ ⌥ ⌃ together for 3 seconds"
                                             : "To exit early, hold ⌘ ⌥ ⌃ together for 3 seconds")
                        .font(.headline).foregroundStyle(.white.opacity(0.85))
                    ProgressView(value: model.holdProgress)
                        .progressViewStyle(.linear).tint(.white)
                        .frame(width: 260).opacity(model.holdProgress > 0 ? 1 : 0.25)
                }
                Text(model.untilShortcut ? "For safety it also unlocks by itself after 30 minutes."
                                         : "Cleaning mode ends automatically when the timer reaches zero.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
final class KeyboardCleaningController {
    let model = KeyboardCleaningModel()
    private(set) var isActive = false
    private var tap: KeyboardCleaningTap?
    private var windows: [KeyboardOverlayWindow] = []
    private var timer: Timer?
    private var deadline: UInt64 = 0
    var onChange: (() -> Void)?

    /// `seconds == 0`: locked until the combo is held (with a 30 min safety cap).
    func start(seconds: Int) -> Bool {
        guard !isActive else { return true }
        let untimed = seconds <= 0
        let span = untimed ? 30 * 60 : seconds
        let now = DispatchTime.now().uptimeNanoseconds
        deadline = now + UInt64(span) * 1_000_000_000
        let t = KeyboardCleaningTap(deadlineUptime: deadline)
        guard t.start() else { return false }
        tap = t
        isActive = true
        model.total = span
        model.remaining = span
        model.untilShortcut = untimed
        model.holdProgress = 0
        for screen in NSScreen.screens {
            let w = KeyboardOverlayWindow.hosting(KeyboardCleaningOverlayView(model: model), frame: screen.frame,
                                                  level: .screenSaver)
            w.orderFrontRegardless()
            windows.append(w)
        }
        let tm = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        // Freeze the pointer too (only honoured while MacMaster is the active app).
        NSApp.activate(ignoringOtherApps: true)
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        onChange?()
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        tap?.stop(); tap = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        onChange?()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { stop(); return }
        // Tap gone (permission revoked, system killed it): input is no longer blocked, so leave the overlay.
        if tap?.isEnabled != true { stop(); return }
        model.remaining = Int(((deadline - now) + 999_999_999) / 1_000_000_000)
        let hold = tap?.holdStart.withLock { $0 } ?? 0
        if hold != 0 {
            let p = Double(now &- hold) / 3_000_000_000
            model.holdProgress = min(1, p)
            if p >= 1 { stop() }
        } else {
            model.holdProgress = 0
        }
    }
}

// MARK: - Key press visualizer

@MainActor
@Observable
final class KeyboardVisualizerModel {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var plain: Bool
        var expires: Date
    }
    var items: [Item] = []
}

struct KeyboardVisualizerView: View {
    let model: KeyboardVisualizerModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ForEach(model.items) { item in
                    Text(item.text)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .modifier(KeyboardGlassPill())
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.18), value: model.items)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class KeyboardVisualizerController {
    let model = KeyboardVisualizerModel()
    private var window: KeyboardOverlayWindow?
    private var timer: Timer?
    private(set) var enabled = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { clear() }
    }

    func push(code: UInt16, flags: UInt64, char: UInt16) {
        guard enabled else { return }
        let cg = CGEventFlags(rawValue: flags)
        var mods = ""
        if cg.contains(.maskControl) { mods += "⌃" }
        if cg.contains(.maskAlternate) { mods += "⌥" }
        if cg.contains(.maskShift) { mods += "⇧" }
        if cg.contains(.maskCommand) { mods += "⌘" }
        let hasCommandish = cg.contains(.maskControl) || cg.contains(.maskCommand) || cg.contains(.maskAlternate)
        let named = KeyboardKeyNames.label(for: Int(code))
        let now = Date()
        let typed: String? = {
            guard !hasCommandish, char >= 32, let s = Unicode.Scalar(char) else { return nil }
            return String(Character(s))
        }()

        if let typed {
            let text = typed == " " ? "␣" : typed
            if var last = model.items.last, last.plain, last.expires > now, last.text.count < 14 {
                last.text += text
                last.expires = now.addingTimeInterval(1.6)
                model.items[model.items.count - 1] = last
            } else {
                append(.init(text: text, plain: true, expires: now.addingTimeInterval(1.6)))
            }
        } else {
            let key = named.isEmpty ? (Unicode.Scalar(char).map { String(Character($0)).uppercased() } ?? "?") : named
            append(.init(text: mods + key, plain: false, expires: now.addingTimeInterval(1.8)))
        }
        showWindow()
    }

    private func append(_ item: KeyboardVisualizerModel.Item) {
        model.items.append(item)
        if model.items.count > 5 { model.items.removeFirst(model.items.count - 5) }
    }

    private func showWindow() {
        let screen = keyboardActiveScreen()
        let size = CGSize(width: min(900, screen.visibleFrame.width - 40), height: 110)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 36,
                           width: size.width, height: size.height)
        if window == nil {
            window = KeyboardOverlayWindow.hosting(KeyboardVisualizerView(model: model), frame: frame,
                                                   level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        } else {
            window?.setFrame(frame, display: false)
        }
        window?.orderFrontRegardless()
        if timer == nil {
            let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.prune() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func prune() {
        let now = Date()
        let kept = model.items.filter { $0.expires > now }
        if kept.count != model.items.count { model.items = kept }
        if kept.isEmpty {
            timer?.invalidate(); timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.items.isEmpty else { return }
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    func clear() {
        timer?.invalidate(); timer = nil
        model.items = []
        window?.orderOut(nil)
    }
}

// MARK: - ⌘Q hint

@MainActor
@Observable
final class KeyboardQuitHintModel {
    var appName = ""
    var filled = false
    var visible = false
}

struct KeyboardQuitHintView: View {
    let model: KeyboardQuitHintModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "command").font(.system(size: 18, weight: .semibold))
                    Text(model.appName.isEmpty ? "Hold ⌘Q to quit" : "Hold ⌘Q to quit \(model.appName)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.accentColor)
                            .frame(width: model.filled ? geo.size.width : 0)
                            .animation(model.filled ? .linear(duration: 0.6) : .easeOut(duration: 0.12), value: model.filled)
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
            .frame(width: 330)
            .modifier(KeyboardGlassPill())
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible ? 1 : 0.94)
            .animation(.smooth(duration: 0.18), value: model.visible)
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class KeyboardQuitHintController {
    let model = KeyboardQuitHintModel()
    private var window: KeyboardOverlayWindow?
    private var hideWork: DispatchWorkItem?

    func show(appName: String) {
        hideWork?.cancel()
        let screen = keyboardActiveScreen()
        let size = CGSize(width: 420, height: 400)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY, width: size.width, height: size.height)
        if window == nil {
            window = KeyboardOverlayWindow.hosting(KeyboardQuitHintView(model: model), frame: frame,
                                                   level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        } else {
            window?.setFrame(frame, display: false)
        }
        model.appName = appName
        model.filled = false
        model.visible = true
        window?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.filled = true }
        }
    }

    func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.visible = false
                self.model.filled = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.model.visible == false { self?.window?.orderOut(nil) }
                    }
                }
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
