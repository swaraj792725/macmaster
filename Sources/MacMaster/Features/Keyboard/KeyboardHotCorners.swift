import SwiftUI
import AppKit

/// Hot corners with dwell time, per-corner modifier requirement and many actions.
@MainActor
final class KeyboardHotCorners {
    static let shared = KeyboardHotCorners()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var evalPending = false
    private var current: KeyboardCorner?
    private var currentScreen: NSScreen?
    private var dwell: DispatchWorkItem?
    private let flash = KeyboardCornerFlash()

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.scheduleEvaluation() }
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
        dwell?.cancel(); dwell = nil
        current = nil; currentScreen = nil
        evalPending = false
    }

    // Throttle: at most one evaluation per ~30 ms, always on the latest position.
    private func scheduleEvaluation() {
        guard !evalPending else { return }
        evalPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.evalPending = false
                self?.evaluate()
            }
        }
    }

    private func evaluate() {
        guard globalMonitor != nil else { return }
        let hit = Self.corner(at: NSEvent.mouseLocation)
        if hit?.0 == current, hit?.1 === currentScreen { return }
        dwell?.cancel(); dwell = nil
        current = hit?.0
        currentScreen = hit?.1
        guard let (corner, screen) = hit else { return }
        guard KeyboardStore.shared.corners[corner].action != .none else { return }
        scheduleDwell(corner: corner, screen: screen)
    }

    private func scheduleDwell(corner: KeyboardCorner, screen: NSScreen) {
        let delay = max(0.05, KeyboardPrefs.double(KeyboardPrefs.cornerDelay, default: 0.25))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dwellElapsed(corner: corner, screen: screen) }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dwellElapsed(corner: KeyboardCorner, screen: NSScreen) {
        guard current == corner, currentScreen === screen,
              Self.corner(at: NSEvent.mouseLocation)?.0 == corner else { return }
        let cfg = KeyboardStore.shared.corners[corner]
        guard cfg.action != .none else { return }
        // Dragging something into a corner is not a hot-corner gesture.
        if NSEvent.pressedMouseButtons != 0 { scheduleDwell(corner: corner, screen: screen); return }
        if let flag = cfg.modifier.flag, !NSEvent.modifierFlags.contains(flag) {
            // Wait for the modifier while the cursor stays here.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.dwellElapsed(corner: corner, screen: screen) }
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        dwell = nil
        if KeyboardPrefs.bool(KeyboardPrefs.cornerFlash, default: true) { flash.show(corner: corner, on: screen) }
        KeyboardSystemActions.perform(cfg.action, appPath: cfg.appPath)
        // `current` stays set, so the corner cannot retrigger until the cursor leaves it.
    }

    /// The outer screen corner (2 px) containing `p`, if any.
    static func corner(at p: NSPoint) -> (KeyboardCorner, NSScreen)? {
        let screens = NSScreen.screens
        for s in screens {
            let f = s.frame
            guard p.x >= f.minX - 1, p.x <= f.maxX + 1, p.y >= f.minY - 1, p.y <= f.maxY + 1 else { continue }
            let left = p.x <= f.minX + 2.5, right = p.x >= f.maxX - 2.5
            let top = p.y >= f.maxY - 2.5, bottom = p.y <= f.minY + 2.5
            guard (left || right) && (top || bottom) else { continue }
            // A corner that touches another display is just a seam, not a trap.
            let probes = [NSPoint(x: left ? f.minX - 6 : f.maxX + 6, y: top ? f.maxY - 6 : f.minY + 6),
                          NSPoint(x: left ? f.minX + 6 : f.maxX - 6, y: top ? f.maxY + 6 : f.minY - 6)]
            if screens.contains(where: { $0 !== s && probes.contains(where: $0.frame.contains) }) { continue }
            let corner: KeyboardCorner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
            return (corner, s)
        }
        return nil
    }

    /// Native macOS hot corners that are set (action > 1 means active; 1 is "disabled").
    static func nativeCornersInUse() -> [KeyboardCorner] {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return [] }
        return KeyboardCorner.allCases.filter { dock.integer(forKey: $0.dockKey) > 1 }
    }
}

// MARK: - Flash

@MainActor
final class KeyboardCornerFlash {
    private var window: KeyboardOverlayWindow?

    func show(corner: KeyboardCorner, on screen: NSScreen) {
        window?.orderOut(nil)
        let size: CGFloat = 260
        let f = screen.frame
        let x = (corner == .topLeft || corner == .bottomLeft) ? f.minX : f.maxX - size
        let y = (corner == .topLeft || corner == .topRight) ? f.maxY - size : f.minY
        let w = KeyboardOverlayWindow.hosting(KeyboardCornerFlashView(corner: corner),
                                              frame: NSRect(x: x, y: y, width: size, height: size),
                                              level: .screenSaver)
        window = w
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak w] in
            MainActor.assumeIsolated {
                w?.orderOut(nil)
                if self?.window === w { self?.window = nil }
            }
        }
    }
}

struct KeyboardCornerFlashView: View {
    let corner: KeyboardCorner
    @State private var phase = false

    private var anchor: UnitPoint {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    var body: some View {
        RadialGradient(colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.18), .clear],
                       center: anchor, startRadius: 0, endRadius: 240)
            .scaleEffect(phase ? 1 : 0.15, anchor: anchor)
            .opacity(phase ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { phase = true } }
    }
}
