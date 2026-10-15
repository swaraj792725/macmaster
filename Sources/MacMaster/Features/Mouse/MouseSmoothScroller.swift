import Foundation
import CoreGraphics
import os

/// Turns discrete wheel impulses into smooth, inertial, pixel-precise scrolling.
///
/// Model: every wheel tick adds a pixel "distance to travel". A velocity chases `remaining / tau`
/// through a short low-pass (soft start), and the distance actually moved each display frame is
/// subtracted from `remaining` — so total travel is exactly what was asked for and the glide has an
/// exponential ease-out. With inertia on, once the wheel stops the glide continues as a real
/// momentum phase (like a trackpad flick).
///
/// Threading: `add` is called on the tap thread; `step` and all ticker management run on `tickQueue`.
/// Shared state sits behind an unfair lock and events are posted outside the lock.
///
/// The ticker is a plain dispatch timer, not a CVDisplayLink: a display link silently stops firing after
/// sleep/wake or a display change, which left the glide stuck "active" and every wheel tick swallowed.
final class MouseSmoothScroller: @unchecked Sendable {
    struct Params: Sendable {
        var tau: Double
        var inertia: Bool
    }

    private enum Phase { case idle, active, momentum }

    private struct State {
        var phase: Phase = .idle
        var remY = 0.0, remX = 0.0
        var velY = 0.0, velX = 0.0
        var fracY = 0.0, fracX = 0.0
        var began = false
        var momentumBegan = false
        var pendingMomentumEnd = false
        var lastInput = 0.0
        var lastStep = 0.0
        var flags: UInt64 = 0
        var tau = 0.125
        var inertia = true
    }

    private struct Out {
        var dy: Int32, dx: Int32
        var scrollPhase: Int64, momentumPhase: Int64
        var velocity: Double
    }

    // CGScrollPhase / CGMomentumScrollPhase raw values.
    private static let phaseBegan: Int64 = 1
    private static let phaseChanged: Int64 = 2
    private static let phaseEnded: Int64 = 4
    private static let momBegin: Int64 = 1
    private static let momContinue: Int64 = 2
    private static let momEnd: Int64 = 3

    private static let maxRemaining = 8000.0
    private static let idleGap = 0.11          // seconds without wheel input → hand over to momentum
    private static let tauUp = 0.035           // soft-start time constant
    private static let frameInterval = 1.0 / 120
    /// Animating but no frame for this long → the ticker is dead; drop the glide and let the wheel through.
    private static let stallGap = 0.5

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let source = CGEventSource(stateID: .privateState)
    private let tickQueue = DispatchQueue(label: "mm.mouse.scroll.tick", qos: .userInteractive)
    private var ticker: DispatchSourceTimer?   // tickQueue only
    private let stats = MouseStatsStore.shared
    private let telemetry = MouseTelemetry.shared

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Input (tap thread)

    /// Returns false when the animator was found stalled: it has been reset and restarted, and the caller
    /// should pass this tick through unsmoothed so the wheel never goes dead.
    @discardableResult
    func add(dy: Double, dx: Double, flags: CGEventFlags, params: Params) -> Bool {
        let now = Self.now()
        var needsTicker = false
        var stalled = false
        state.withLockUnchecked { s in
            if s.phase != .idle, now - s.lastStep > Self.stallGap {
                s = State()
                stalled = true
                return
            }
            s.tau = params.tau
            s.inertia = params.inertia
            if dy != 0 {
                if s.remY * dy < 0 { s.remY = 0; s.velY = 0 }
                s.remY = max(-Self.maxRemaining, min(Self.maxRemaining, s.remY + dy))
            }
            if dx != 0 {
                if s.remX * dx < 0 { s.remX = 0; s.velX = 0 }
                s.remX = max(-Self.maxRemaining, min(Self.maxRemaining, s.remX + dx))
            }
            s.flags = flags.rawValue
            s.lastInput = now
            switch s.phase {
            case .idle:
                s.phase = .active
                s.began = false
                s.lastStep = now
                needsTicker = true
            case .momentum:
                s.pendingMomentumEnd = s.momentumBegan
                s.momentumBegan = false
                s.phase = .active
                s.began = false
            case .active:
                break
            }
        }
        if stalled {
            tickQueue.async { [self] in
                ticker?.cancel()
                ticker = nil
            }
            return false
        }
        if needsTicker { ensureTickerRunning() }
        return true
    }

    func shutdown() {
        tickQueue.sync {
            ticker?.cancel()
            ticker = nil
        }
        state.withLock { $0 = State() }
    }

    // MARK: Ticker

    private func ensureTickerRunning() {
        tickQueue.async { [self] in
            guard ticker == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: tickQueue)
            t.schedule(deadline: .now(), repeating: Self.frameInterval, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.step() }
            t.resume()
            ticker = t
        }
    }

    /// On tickQueue. A tick that raced in after this check restarts the ticker via `ensureTickerRunning`.
    private func stopTickerIfIdle() {
        guard state.withLock({ $0.phase == .idle }) else { return }
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Frame step (tickQueue)

    private func step() {
        let now = Self.now()
        var outs: [Out] = []
        var becameIdle = false

        state.withLockUnchecked { s in
            guard s.phase != .idle else { becameIdle = true; return }
            let dt = min(max(now - s.lastStep, 0.001), 0.05)
            s.lastStep = now

            if s.pendingMomentumEnd {
                outs.append(Out(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Self.momEnd, velocity: 0))
                s.pendingMomentumEnd = false
            }

            // Wheel went quiet → continue as momentum.
            if s.phase == .active, s.inertia, s.began, now - s.lastInput > Self.idleGap {
                outs.append(Out(dy: 0, dx: 0, scrollPhase: Self.phaseEnded, momentumPhase: 0, velocity: 0))
                s.phase = .momentum
                s.momentumBegan = false
            }

            let tau = s.phase == .momentum ? s.tau * 1.45 : s.tau
            let up = 1 - exp(-dt / Self.tauUp)

            func integrate(_ rem: inout Double, _ vel: inout Double) -> Double {
                let target = rem / tau
                vel += (target - vel) * up
                var d = vel * dt
                if d * rem < 0 { d = 0 }
                if abs(d) > abs(rem) { d = rem }
                rem -= d
                return d
            }

            var dY = integrate(&s.remY, &s.velY)
            var dX = integrate(&s.remX, &s.velX)

            // Finished?
            let done = abs(s.remY) < 0.8 && abs(s.remX) < 0.8
            if done {
                dY += s.remY; dX += s.remX
                s.remY = 0; s.remX = 0; s.velY = 0; s.velX = 0
            }

            s.fracY += dY; s.fracX += dX
            let iy = Int32(s.fracY.rounded(.towardZero))
            let ix = Int32(s.fracX.rounded(.towardZero))
            s.fracY -= Double(iy); s.fracX -= Double(ix)

            if iy != 0 || ix != 0 {
                let mag = hypot(Double(iy), Double(ix))
                let velocity = mag / dt
                if s.phase == .active {
                    outs.append(Out(dy: iy, dx: ix, scrollPhase: s.began ? Self.phaseChanged : Self.phaseBegan,
                                    momentumPhase: 0, velocity: velocity))
                    s.began = true
                } else {
                    outs.append(Out(dy: iy, dx: ix, scrollPhase: 0,
                                    momentumPhase: s.momentumBegan ? Self.momContinue : Self.momBegin,
                                    velocity: velocity))
                    s.momentumBegan = true
                }
            }

            if done {
                if s.phase == .active, s.began {
                    outs.append(Out(dy: 0, dx: 0, scrollPhase: Self.phaseEnded, momentumPhase: 0, velocity: 0))
                } else if s.phase == .momentum, s.momentumBegan {
                    outs.append(Out(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Self.momEnd, velocity: 0))
                }
                s.phase = .idle
                s.began = false
                s.momentumBegan = false
                s.fracX = 0; s.fracY = 0
                becameIdle = true
            }
        }

        if !outs.isEmpty {
            let flags = state.withLock { CGEventFlags(rawValue: $0.flags) }
            let loc = CGEvent(source: nil)?.location ?? .zero
            for o in outs { post(o, flags: flags, location: loc) }
        }
        if becameIdle { stopTickerIfIdle() }
    }

    private func post(_ o: Out, flags: CGEventFlags, location: CGPoint) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: o.dy, wheel2: o.dx, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticMagic)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: o.scrollPhase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: o.momentumPhase)
        e.flags = flags
        e.location = location
        e.post(tap: .cgSessionEventTap)
        if o.dy != 0 || o.dx != 0 {
            stats.recordScroll(pixels: hypot(Double(o.dy), Double(o.dx)))
            telemetry.recordSmoothed(velocity: o.velocity)
        }
    }
}
