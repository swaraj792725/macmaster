import AVFoundation
import Vision
import os

/// What one processed camera frame showed.
struct PrivacyGuardReading: Sendable {
    /// Faces large enough to be someone at the screen (tiny background faces are ignored).
    var faces: Int
    /// Head turn of the biggest face in degrees (0 = facing the screen). Nil when it can't be told.
    var yawDegrees: Double?
}

/// Low-resolution camera feed plus Vision face detection. Frames are analysed in memory, ~5 per second, and
/// dropped right after; nothing is written to disk. Everything here is thread-safe and off the main thread.
final class PrivacyGuardCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Sendable { case noCamera, cannotOpen, interrupted, runtime }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.macmaster.privacyguard.camera", qos: .utility)
    private let log = Logger(subsystem: "com.macmaster.app", category: "privacyGuard")

    // Touched on `queue` only.
    private var output: AVCaptureVideoDataOutput?
    private var lastProcessed: TimeInterval = 0
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []
    private var onReading: (@Sendable (PrivacyGuardReading) -> Void)?
    private var onFailure: (@Sendable (Failure?) -> Void)?

    private static let framesPerSecond = 5.0
    private let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            r.revision = VNDetectFaceRectanglesRequestRevision3
        }
        return r
    }()

    /// Opens the default camera. `onFailure(nil)` means the feed is live (again).
    func start(onReading: @escaping @Sendable (PrivacyGuardReading) -> Void, onFailure: @escaping @Sendable (Failure?) -> Void) {
        queue.async { [self] in
            self.onReading = onReading
            self.onFailure = onFailure
            wantsRunning = true
            guard configureIfNeeded() else { return }
            observe()
            if !session.isRunning { session.startRunning() }
            if session.isRunning { onFailure(nil) } else { onFailure(.cannotOpen) }
        }
    }

    /// Closes the camera (the green light goes off) and forgets the callbacks.
    func stop() {
        queue.async { [self] in
            wantsRunning = false
            onReading = nil
            onFailure = nil
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for i in session.inputs { session.removeInput(i) }
            if let output { session.removeOutput(output) }
            session.commitConfiguration()
            output = nil
        }
    }

    // MARK: Setup (on queue)

    private func configureIfNeeded() -> Bool {
        if !session.inputs.isEmpty, output != nil { return true }
        guard let device = AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            onFailure?(.noCamera)
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low
            guard session.canAddInput(input) else { onFailure?(.cannotOpen); return false }
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(out) else { onFailure?(.cannotOpen); return false }
            session.addOutput(out)
            output = out
        } catch {
            log.error("camera open failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(.cannotOpen)
            return false
        }
        limitFrameRate(device)
        return true
    }

    /// Asks the camera for ~8 fps when it supports it (fewer frames to throw away). Best effort.
    private func limitFrameRate(_ device: AVCaptureDevice) {
        let target = 8.0
        let ok = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target && target <= $0.maxFrameRate }
        guard ok, (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
        device.unlockForConfiguration()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.onFailure?(.interrupted) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.onFailure?(nil) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.wantsRunning else { return }
                self.onFailure?(.runtime)
                // Try once more after a short pause (device unplugged and replugged, another app let go, ...).
                self.queue.asyncAfter(deadline: .now() + 2) {
                    guard self.wantsRunning, !self.session.isRunning else { return }
                    self.session.startRunning()
                    if self.session.isRunning { self.onFailure?(nil) }
                }
            }
        })
    }

    // MARK: Frames (on queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard wantsRunning, now - lastProcessed >= 1.0 / Self.framesPerSecond - 0.01 else { return }
        lastProcessed = now
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return }
        let found = (request.results ?? []).filter { $0.boundingBox.width >= 0.06 }
        let biggest = found.max { $0.boundingBox.width < $1.boundingBox.width }
        // Someone sitting far behind you is smaller than the face at the screen; ignore specks.
        let counted = found.filter { $0.boundingBox.width >= (biggest?.boundingBox.width ?? 0) * 0.25 }
        let yaw = biggest?.yaw.map { abs($0.doubleValue) * 180 / .pi }
        onReading?(PrivacyGuardReading(faces: counted.count, yawDegrees: yaw))
    }
}
