import SwiftUI
import AppKit

/// Non-activating panel that only takes keys when clicked, so it never steals focus from the app you present in.
final class PrompterPanel: NSPanel {
    var onKey: ((UInt16) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat || [125, 126].contains(event.keyCode), onKey?(event.keyCode) == true { return }
        super.sendEvent(event)
    }
}

/// Owns the teleprompter window. It exists only while the prompter is open.
@MainActor
final class TeleprompterOverlayController: NSObject, NSWindowDelegate {
    static let shared = TeleprompterOverlayController()
    private var panel: PrompterPanel?
    private var closing = false

    private override init() { super.init() }

    private var engine: TeleprompterEngine { .shared }
    private let pad = TeleprompterEngine.screenPadding

    // MARK: Show / hide

    /// Creates the panel for the current mode. Returns the text width the script should wrap at.
    @discardableResult
    func show() -> CGFloat {
        if let p = panel { p.orderFrontRegardless(); return p.frame.width - pad * 2 }
        let notch = engine.mode == .notch
        let frame = notch ? notchFrame() : floatingFrame()

        let p = PrompterPanel(contentRect: frame,
                              styleMask: notch ? [.borderless, .nonactivatingPanel] : [.borderless, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !notch
        p.level = notch ? .statusBar : .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.sharingType = .none            // hidden from screen sharing and recordings (where macOS honours it)
        p.isMovableByWindowBackground = !notch
        p.minSize = NSSize(width: 260, height: 140)
        p.delegate = self
        p.onKey = { [weak self] code in self?.handleKey(code) ?? false }
        let host = NSHostingView(rootView: PrompterRootView(notch: notch))
        host.sizingOptions = []
        p.contentView = host
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        panel = p
        return frame.width - pad * 2
    }

    func close() {
        guard let p = panel, !closing else { return }
        closing = true
        if engine.mode == .floating { saveFloatingFrame() }
        panel = nil
        p.delegate = nil
        p.onKey = nil
        p.orderOut(nil)
        // Release the view tree after the current event (a key or button press may be what closed us).
        DispatchQueue.main.async { p.contentView = nil }
        closing = false
    }

    /// Mode changed while open: rebuild the window, keep playback state.
    func reopen() {
        guard panel != nil else { return }
        let old = panel
        panel = nil
        old?.delegate = nil
        old?.onKey = nil
        old?.orderOut(nil)
        DispatchQueue.main.async { old?.contentView = nil }
        let w = show()
        engine.setLayoutWidth(w)
    }

    /// Width or height sliders moved while open.
    func applyGeometry() {
        guard let p = panel else { return }
        if engine.mode == .notch {
            let f = notchFrame()
            p.setFrame(f, display: true, animate: false)
            engine.setLayoutWidth(f.width - pad * 2)
        } else {
            var f = p.frame
            let w = CGFloat(engine.textWidth) + pad * 2
            f.origin.x -= (w - f.width) / 2
            f.size.width = w
            p.setFrame(f, display: true, animate: false)
            engine.setLayoutWidth(w - pad * 2)
        }
    }

    // MARK: Geometry

    private func targetScreen() -> NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private func notchFrame() -> NSRect {
        guard let s = targetScreen() else { return NSRect(x: 0, y: 0, width: 600, height: 200) }
        let w = min(CGFloat(engine.textWidth) + pad * 2, s.frame.width)
        let top = min(s.visibleFrame.maxY, s.frame.maxY - s.safeAreaInsets.top)
        let h = min(CGFloat(engine.notchHeight), top - s.frame.minY)
        return NSRect(x: s.frame.midX - w / 2, y: top - h, width: w, height: h)
    }

    private func floatingFrame() -> NSRect {
        if let s = UserDefaults.standard.string(forKey: TPPrefs.floatFrame) {
            let r = NSRectFromString(s)
            if r.width >= 260, r.height >= 140, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { return r }
        }
        guard let s = targetScreen() else { return NSRect(x: 100, y: 100, width: 620, height: 300) }
        let w = min(CGFloat(engine.textWidth) + pad * 2, s.visibleFrame.width)
        let h: CGFloat = 300
        return NSRect(x: s.visibleFrame.midX - w / 2, y: s.visibleFrame.maxY - h - 60, width: w, height: h)
    }

    private func saveFloatingFrame() {
        guard let p = panel, engine.mode == .floating else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: TPPrefs.floatFrame)
    }

    // MARK: Keys

    /// space = play/pause, up/down = speed, left/right = jump a line, esc = stop.
    private func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 49: engine.togglePlayPause()
        case 126: engine.nudgeSpeed(10)
        case 125: engine.nudgeSpeed(-10)
        case 123: engine.jump(lines: -1)
        case 124: engine.jump(lines: 1)
        case 53: engine.stop()
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFloatingFrame() }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let p = panel else { return }
        saveFloatingFrame()
        engine.setLayoutWidth(p.frame.width - pad * 2)
    }
}

// MARK: - Content

struct PrompterRootView: View {
    let notch: Bool
    private let engine = TeleprompterEngine.shared
    @State private var hover = false

    var body: some View {
        ZStack {
            background
            PrompterContent(layout: engine.layout, fontSize: CGFloat(engine.fontSize),
                            mirror: engine.mirror, highlight: engine.highlight, scroll: engine.scroll)
                .equatable()
            if let c = engine.countdown {
                Text("\(c)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .id(c)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
            }
            if engine.state == .paused, engine.countdown == nil {
                VStack {
                    Spacer()
                    Text(engine.atEnd ? "End of script" : "Paused")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, hover ? 54 : 10)
                }
                .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                if hover { PrompterControlStrip().transition(.opacity) }
            }
            .padding(.bottom, 8)
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.2), value: engine.countdown)
        .onHover { hover = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var background: some View {
        let fill = Color.black.opacity(engine.opacity)
        if notch {
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20).fill(fill)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill)
        }
    }
}

/// Scrolling text. Re-evaluated only when the layout or style changes; the offset is applied by `ScrollingLines`.
private struct PrompterContent: View, Equatable {
    let layout: PromptLayout
    let fontSize: CGFloat
    let mirror: Bool
    let highlight: Bool
    let scroll: TeleprompterScroll

    static func == (l: PrompterContent, r: PrompterContent) -> Bool {
        l.layout.stamp == r.layout.stamp && l.fontSize == r.fontSize && l.mirror == r.mirror && l.highlight == r.highlight
    }

    var body: some View {
        GeometryReader { geo in
            ScrollingLines(layout: layout, fontSize: fontSize, highlight: highlight, scroll: scroll, size: geo.size)
        }
        .scaleEffect(x: mirror ? -1 : 1, y: 1)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                   .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct ScrollingLines: View {
    let layout: PromptLayout
    let fontSize: CGFloat
    let highlight: Bool
    let scroll: TeleprompterScroll
    let size: CGSize

    var body: some View {
        // Only this body re-runs at 60 Hz; the line stacks below are skipped by `.equatable()`.
        let markerY = size.height * 0.3
        let y = markerY - scroll.offset
        let band = fontSize * 1.7
        ZStack(alignment: .topLeading) {
            LinesStack(layout: layout, fontSize: fontSize, width: size.width, color: .white.opacity(highlight ? 0.42 : 1))
                .equatable()
                .frame(width: size.width, height: size.height, alignment: .top)
                .offset(y: y)
            if highlight {
                ZStack(alignment: .topLeading) {
                    LinesStack(layout: layout, fontSize: fontSize, width: size.width, color: .white)
                        .equatable()
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .offset(y: y)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: size.width, height: band).offset(y: markerY - band / 2)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

private struct LinesStack: View, Equatable {
    let layout: PromptLayout
    let fontSize: CGFloat
    let width: CGFloat
    let color: Color

    static func == (l: LinesStack, r: LinesStack) -> Bool {
        l.layout.stamp == r.layout.stamp && l.fontSize == r.fontSize && l.width == r.width && l.color == r.color
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(layout.lines) { line in
                Text(line.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: width, height: line.height, alignment: .center)
            }
        }
    }
}

/// Appears on hover: line back, play/pause, line forward, speed, mirror, stop.
private struct PrompterControlStrip: View {
    private let engine = TeleprompterEngine.shared

    var body: some View {
        HStack(spacing: 14) {
            button("backward.frame.fill", help: "Previous line (Left)") { engine.jump(lines: -1) }
            button(engine.state == .playing || engine.state == .countdown ? "pause.fill" : "play.fill",
                   help: "Play / pause (Space)") { engine.togglePlayPause() }
            button("forward.frame.fill", help: "Next line (Right)") { engine.jump(lines: 1) }
            Divider().frame(height: 14)
            button("minus", help: "Slower (Down)") { engine.nudgeSpeed(-10) }
            Text("\(Int(engine.wpm)) wpm")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: 52)
            button("plus", help: "Faster (Up)") { engine.nudgeSpeed(10) }
            Divider().frame(height: 14)
            button("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Mirror text") { engine.mirror.toggle() }
            button("xmark", help: "Stop (Esc)") { engine.stop() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.white.opacity(0.14), in: Capsule())
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
