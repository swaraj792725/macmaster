import AppKit
import ScreenCaptureKit

/// A frozen picture of one display.
struct CaptureFrame {
    let displayID: CGDirectDisplayID
    /// Display frame in global Cocoa coordinates (origin bottom-left of the primary display).
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat
    let image: CGImage
}

enum CaptureGrabError: LocalizedError {
    case noDisplays, timedOut
    var errorDescription: String? {
        switch self {
        case .noDisplays: "No display could be captured."
        case .timedOut: "The screen capture took too long. Try again."
        }
    }
}

/// Grabs every display once through ScreenCaptureKit, so menus and tooltips stay visible while the user selects.
@MainActor
enum CaptureGrabber {
    /// MacMaster's own windows (main window, HUD) are left out, except `keepWindowNumbers` (pinned images).
    static func grabAll(keepWindowNumbers: Set<CGWindowID>) async throws -> [CaptureFrame] {
        let screens: [(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat)] = NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(n.uint32Value), s.frame, s.backingScaleFactor)
        }
        guard !screens.isEmpty else { throw CaptureGrabError.noDisplays }
        let pid = ProcessInfo.processInfo.processIdentifier

        return try await withTimeout(seconds: 8) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let own = content.windows.filter {
                $0.owningApplication?.processID == pid && !keepWindowNumbers.contains($0.windowID)
            }
            var frames: [CaptureFrame] = []
            for s in screens {
                guard let display = content.displays.first(where: { $0.displayID == s.id }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: own)
                let cfg = SCStreamConfiguration()
                cfg.width = max(1, Int((s.frame.width * s.scale).rounded()))
                cfg.height = max(1, Int((s.frame.height * s.scale).rounded()))
                cfg.showsCursor = false
                cfg.colorSpaceName = CGColorSpace.sRGB
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                frames.append(CaptureFrame(displayID: s.id, frame: s.frame, scale: s.scale, image: img))
            }
            guard !frames.isEmpty else { throw CaptureGrabError.noDisplays }
            return frames
        }
    }

    /// Runs `body` but gives up after `seconds`.
    private static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CaptureGrabError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CaptureGrabError.timedOut }
            return first
        }
    }
}
