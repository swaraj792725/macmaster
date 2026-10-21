import Foundation
import AVFoundation

/// Listens to the microphone and exposes a smoothed loudness in dB. The audio thread only writes one number
/// behind a lock; the teleprompter tick reads it. Nothing is recorded or stored.
final class VoicePacer: @unchecked Sendable {
    private let audio = AVAudioEngine()
    private let lock = NSLock()
    private var db: Double = -120
    private(set) var isRunning = false

    var levelDB: Double {
        lock.lock(); defer { lock.unlock() }
        return db
    }

    private func set(_ v: Double) {
        lock.lock(); db = v; lock.unlock()
    }

    /// Starts the input tap. Caller must have microphone permission.
    func start() throws {
        guard !isRunning else { return }
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoicePacer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        isRunning = false
        set(-120)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        let rms = Double((sum / Float(n)).squareRoot())
        let now = 20 * log10(max(rms, 1e-7))
        lock.lock()
        db = db * 0.5 + now * 0.5
        lock.unlock()
    }
}
