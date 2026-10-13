import Foundation
import os
import SwiftUI

// MARK: - Daily stats

struct MouseStatsSnapshot: Codable, Equatable, Sendable {
    var dayStart: Double = 0
    var clicks = 0
    var scrollPixels = 0.0
    var scrollEvents = 0
    var buttonPresses: [Int: Int] = [:]

    /// Fun conversion: assume ~127 points per inch → 0.2 mm per point.
    var scrollMeters: Double { scrollPixels * 0.0002 }
}

/// Thread-safe counters fed from the event-tap thread, read by the UI.
final class MouseStatsStore: @unchecked Sendable {
    static let shared = MouseStatsStore()
    private static let key = "mm.mouse.stats"

    private let state: OSAllocatedUnfairLock<(snap: MouseStatsSnapshot, dirty: Bool, nextDay: Double)>
    /// Main, not a background queue: writing defaults off-main posts didChangeNotification on that thread,
    /// which deadlocked against SwiftUI when an observer hopped to main synchronously.
    private let flushQueue = DispatchQueue.main
    private var flushTimer: DispatchSourceTimer?

    private init() {
        var snap = MouseStatsSnapshot()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(MouseStatsSnapshot.self, from: data) { snap = s }
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if snap.dayStart != start { snap = MouseStatsSnapshot(dayStart: start) }
        state = OSAllocatedUnfairLock(initialState: (snap, false, start + 86_400))
    }

    /// Roll over to a new day if needed. Call with lock held via `mutate`.
    private func mutate(_ body: (inout MouseStatsSnapshot) -> Void) {
        let now = Date().timeIntervalSince1970
        state.withLock { s in
            if now >= s.nextDay {
                let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                s.snap = MouseStatsSnapshot(dayStart: start)
                s.nextDay = start + 86_400
            }
            body(&s.snap)
            s.dirty = true
        }
    }

    func recordClick(button: Int) {
        mutate { $0.clicks += 1; $0.buttonPresses[button, default: 0] += 1 }
    }

    func recordScroll(pixels: Double) {
        mutate { $0.scrollPixels += abs(pixels); $0.scrollEvents += 1 }
    }

    func snapshot() -> MouseStatsSnapshot {
        let now = Date().timeIntervalSince1970
        return state.withLock { s in
            if now >= s.nextDay { return MouseStatsSnapshot() }
            return s.snap
        }
    }

    func startFlushing() {
        guard flushTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: flushQueue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flushTimer = t
    }

    func stopFlushing() {
        flushTimer?.cancel()
        flushTimer = nil
        flush()
    }

    func resetToday() {
        mutate { $0 = MouseStatsSnapshot(dayStart: $0.dayStart) }
        flush()
    }

    private func flush() {
        let snapshot: MouseStatsSnapshot? = state.withLock { s in
            guard s.dirty else { return nil }
            s.dirty = false
            return s.snap
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - Live telemetry for the test area

struct MouseTelemetrySample: Sendable {
    var time: Double
    var value: Double
}

struct MouseTelemetryButtonEvent: Sendable, Identifiable {
    let id = UUID()
    var time: Double
    var button: Int
    var down: Bool
}

struct MouseTelemetrySnapshot: Sendable {
    var raw: [MouseTelemetrySample] = []
    var smoothed: [MouseTelemetrySample] = []
    var buttons: [MouseTelemetryButtonEvent] = []
    var lastScrollDevice: String = "—"
    var lastScrollTime: Double = 0
    var now: Double = 0
}

/// Ring buffers of recent raw/smoothed scroll values and button events. Only records while the
/// test area is on screen so the tap thread does no extra work otherwise.
final class MouseTelemetry: @unchecked Sendable {
    static let shared = MouseTelemetry()

    private struct State {
        var recording = false
        var raw: [MouseTelemetrySample] = []
        var smoothed: [MouseTelemetrySample] = []
        var buttons: [MouseTelemetryButtonEvent] = []
        var device = "—"
        var deviceTime = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func setRecording(_ on: Bool) {
        state.withLock {
            $0.recording = on
            if !on { $0.raw.removeAll(); $0.smoothed.removeAll(); $0.buttons.removeAll() }
        }
    }

    var isRecording: Bool { state.withLock { $0.recording } }

    func recordRaw(_ px: Double, device: String) {
        let t = Self.now()
        state.withLock {
            guard $0.recording else { return }
            $0.raw.append(.init(time: t, value: px))
            if $0.raw.count > 600 { $0.raw.removeFirst($0.raw.count - 600) }
            $0.device = device
            $0.deviceTime = t
        }
    }

    func recordSmoothed(velocity: Double) {
        let t = Self.now()
        state.withLock {
            guard $0.recording else { return }
            $0.smoothed.append(.init(time: t, value: velocity))
            if $0.smoothed.count > 900 { $0.smoothed.removeFirst($0.smoothed.count - 900) }
        }
    }

    func recordButton(_ button: Int, down: Bool) {
        let t = Self.now()
        state.withLock {
            guard $0.recording else { return }
            $0.buttons.append(.init(time: t, button: button, down: down))
            if $0.buttons.count > 40 { $0.buttons.removeFirst($0.buttons.count - 40) }
        }
    }

    /// Seconds since the last recorded scroll or button event (or a held button).
    var idleSeconds: Double {
        let t = Self.now()
        return state.withLock { s in
            if s.buttons.last?.down == true { return 0 }
            let last = max(s.raw.last?.time ?? 0, s.smoothed.last?.time ?? 0, s.buttons.last?.time ?? 0)
            return t - last
        }
    }

    func snapshot() -> MouseTelemetrySnapshot {
        let t = Self.now()
        return state.withLock {
            MouseTelemetrySnapshot(raw: $0.raw, smoothed: $0.smoothed, buttons: $0.buttons,
                                   lastScrollDevice: $0.device, lastScrollTime: $0.deviceTime, now: t)
        }
    }
}

/// Redraw schedule for the live mouse views: `fast` while the mouse is in use, 2 fps once it has
/// been idle for a few seconds (long enough for the scroll chart to scroll out).
struct MouseActivitySchedule: TimelineSchedule {
    var fast: Double
    var idleAfter: Double = 5

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var t = start
        return AnyIterator {
            let idle = mode == .lowFrequency || MouseTelemetry.shared.idleSeconds > idleAfter
            t = t.addingTimeInterval(idle ? 0.5 : fast)
            return t
        }
    }
}
