import Foundation
import AVFoundation
import os

/// Live input level for the default microphone. Runs only while the Sound page is visible and the user has the
/// meter switched on; the audio engine is torn down the moment either stops being true.
@MainActor @Observable
final class SoundLevelMeter {
    static let shared = SoundLevelMeter()

    enum State: Equatable { case off, running, noInput, failed }

    private(set) var level: Float = 0      // 0...1, smoothed
    private(set) var peak: Float = 0
    private(set) var state: State = .off

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private let log = Logger(subsystem: "com.macmaster.app", category: "sound")
    @ObservationIgnored private let box = LevelBox()
    private init() {}

    /// Starts metering. Does nothing (and never prompts) unless microphone access is already granted.
    func start() {
        wanted = true
        guard engine == nil else { return }
        guard Permissions.isGranted(.microphone) else { state = .off; return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        // installTap raises an Objective-C exception on a zero-rate format, which Swift can't catch.
        guard format.sampleRate > 0, format.channelCount > 0 else { state = .noInput; return }
        let box = self.box
        box.reset()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0, peak: Float = 0
            let ch = data[0]
            for i in 0..<n { let s = ch[i]; sum += s * s; peak = max(peak, abs(s)) }
            let rms = (sum / Float(n)).squareRoot()
            if box.shouldPost(rms: rms, peak: peak) {
                let (r, p) = box.take()
                DispatchQueue.main.async { MainActor.assumeIsolated { SoundLevelMeter.shared.push(rms: r, peak: p) } }
            }
        }
        e.prepare()
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            log.error("meter start failed: \(error.localizedDescription)")
            state = .failed
            return
        }
        engine = e
        state = .running
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { _ in
            MainActor.assumeIsolated { SoundLevelMeter.shared.restartIfRunning() }
        }
    }

    func stop() {
        wanted = false
        teardown()
        state = .off
        level = 0; peak = 0
    }

    /// Default input changed: rebuild against the new device.
    func restartIfRunning() {
        guard wanted else { return }
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { if SoundLevelMeter.shared.wanted { SoundLevelMeter.shared.start() } }
        }
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
    }

    fileprivate func push(rms: Float, peak p: Float) {
        guard engine != nil else { return }
        // -60 dB ... 0 dB mapped to 0...1
        func norm(_ v: Float) -> Float { min(max((20 * log10(max(v, 1e-6)) + 60) / 60, 0), 1) }
        let target = norm(rms)
        level = target > level ? target : level * 0.82 + target * 0.18   // fast attack, slow release
        let pk = norm(p)
        peak = pk > peak ? pk : max(peak - 0.04, 0)
    }
}

/// Audio-thread side of the meter: accumulates and rate-limits updates to the main thread (~20 per second).
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rms: Float = 0, peak: Float = 0
    private var last: UInt64 = 0

    func reset() { lock.lock(); rms = 0; peak = 0; last = 0; lock.unlock() }

    func shouldPost(rms r: Float, peak p: Float) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rms = max(rms, r); peak = max(peak, p)
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last > 50_000_000 else { return false }
        last = now
        return true
    }

    func take() -> (Float, Float) {
        lock.lock(); defer { lock.unlock() }
        let r = (rms, peak)
        rms = 0; peak = 0
        return r
    }
}
