import AppKit

/// Where the shelf was asked to appear.
enum DropShelfPlacement {
    case nearCursor
    case edge(DropShelfEdge)
}

/// Detects file drags system-wide with two global event types and no timers.
/// Per event: an integer pasteboard compare plus a few float ops while a file drag is live.
@MainActor
final class DropShelfDragMonitor {
    var shakeEnabled = true
    var edge: DropShelfEdge = .off
    var onTrigger: ((DropShelfPlacement) -> Void)?
    var onDragEnded: (() -> Void)?

    private enum Phase { case idle, undecided, files, other, fired }

    private var global: Any?
    private var local: Any?
    private var phase = Phase.idle
    private var knownCount = 0
    private var shake = DropShelfShakeDetector()
    private let pasteboard = NSPasteboard(name: .drag)

    var isRunning: Bool { global != nil }

    func start() {
        guard global == nil else { return }
        knownCount = pasteboard.changeCount
        phase = .idle
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type, time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, time) }
        }
        // Mouse-ups inside our own windows (drops on the shelf) never reach the global monitor.
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.resync() }
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
        phase = .idle
        shake.reset()
    }

    /// Adopt the current drag pasteboard as "already seen".
    func resync() {
        knownCount = pasteboard.changeCount
        phase = .idle
        shake.reset()
    }

    private func handle(_ type: NSEvent.EventType, _ time: TimeInterval) {
        if type == .leftMouseUp {
            resync()
            onDragEnded?()
            return
        }
        switch phase {
        case .other, .fired: return
        case .idle: phase = .undecided; fallthrough
        case .undecided:
            let count = pasteboard.changeCount
            guard count != knownCount else { return }
            knownCount = count
            phase = hasFiles ? .files : .other
            if phase == .files { shake.reset() }
            if phase != .files { return }
        case .files: break
        }

        let p = NSEvent.mouseLocation
        if edge != .off, let placement = edgeHit(p) {
            phase = .fired; onTrigger?(placement); return
        }
        if shakeEnabled, shake.feed(x: p.x, time: time) {
            phase = .fired; onTrigger?(.nearCursor)
        }
    }

    private var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func edgeHit(_ p: NSPoint) -> DropShelfPlacement? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let zone: CGFloat = 6
        switch edge {
        case .left:
            let minX = screens.map(\.frame.minX).min() ?? 0
            return p.x <= minX + zone ? .edge(.left) : nil
        case .right:
            let maxX = screens.map(\.frame.maxX).max() ?? 0
            return p.x >= maxX - zone ? .edge(.right) : nil
        case .off: return nil
        }
    }
}

/// Counts horizontal direction reversals within a short window.
struct DropShelfShakeDetector {
    var minTravel: CGFloat = 40
    var reversalsNeeded = 3
    var window: TimeInterval = 0.7

    private var extreme: CGFloat = 0
    private var dir: CGFloat = 0
    private var started = false
    private var stamps: [TimeInterval] = []

    mutating func reset() {
        started = false; dir = 0; stamps.removeAll(keepingCapacity: true)
    }

    /// Returns true when the shake gesture completes.
    mutating func feed(x: CGFloat, time: TimeInterval) -> Bool {
        guard started else { started = true; extreme = x; return false }
        if dir == 0 {
            if abs(x - extreme) >= minTravel { dir = x > extreme ? 1 : -1; extreme = x }
            return false
        }
        if (x - extreme) * dir > 0 { extreme = x; return false }
        guard (extreme - x) * dir >= minTravel else { return false }
        dir = -dir; extreme = x
        stamps.append(time)
        stamps.removeAll { time - $0 > window }
        if stamps.count >= reversalsNeeded { reset(); return true }
        return false
    }
}
