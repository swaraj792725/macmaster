import AVFoundation
import Speech

/// Microphone → speech recognizer. Not main-actor isolated: the audio tap runs on a realtime thread.
/// The engine runs only between `start` and `stop`, so the microphone is off between utterances.
final class DictationAudioCapture: @unchecked Sendable {
    enum StartError: Error { case noInput, engine(String) }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false

    /// Starts feeding `request` and reports a 0...1 level about 20 times a second.
    func start(request: SFSpeechAudioBufferRecognitionRequest, onLevel: @escaping @Sendable (Float) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.noInput }
        let state = LevelState()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let level = state.level(for: buffer) { onLevel(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw StartError.engine(error.localizedDescription)
        }
        running = true
    }

    /// Stops the microphone right away.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    /// Smooths and rate-limits level values (audio thread only).
    private final class LevelState: @unchecked Sendable {
        private var smoothed: Float = 0
        private var lastEmit: CFAbsoluteTime = 0

        func level(for buffer: AVAudioPCMBuffer) -> Float? {
            guard let ch = buffer.floatChannelData?[0] else { return nil }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return nil }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = (sum / Float(n)).squareRoot()
            // -50 dB ... -10 dB mapped to 0 ... 1
            let db = 20 * log10(max(rms, 0.000_01))
            let v = min(max((db + 50) / 40, 0), 1)
            smoothed = max(v, smoothed * 0.8)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEmit >= 0.05 else { return nil }
            lastEmit = now
            return smoothed
        }
    }
}

/// Wraps the recognition task so its callback is not tied to the main actor.
enum DictationRecognition {
    /// `onUpdate(text, isFinal, errorMessage, isNoSpeech)`
    static func start(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                      onUpdate: @escaping @Sendable (String?, Bool, String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onUpdate(result.bestTranscription.formattedString, result.isFinal, nil, false)
            } else if let error = error as NSError? {
                // 1110 / 203: "no speech detected" and friends. Not a failure the user needs to hear about.
                let noSpeech = error.domain == "kAFAssistantErrorDomain" && (error.code == 1110 || error.code == 203 || error.code == 1107)
                onUpdate(nil, true, error.localizedDescription, noSpeech)
            }
        }
    }
}
