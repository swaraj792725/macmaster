import SwiftUI
import AppKit
import CoreAudio

// MARK: - Saved levels

/// Volumes of microphones we muted, by device UID, so unmute puts them back (even after a relaunch).
/// Value < 0 means the device's mute switch was used instead of its volume.
final class SoundMicStore: @unchecked Sendable {
    static let shared = SoundMicStore()
    private let lock = NSLock()
    private var saved: [String: Double]

    private init() {
        saved = UserDefaults.standard.dictionary(forKey: SoundSettings.micSavedKey) as? [String: Double] ?? [:]
    }

    func contains(_ uid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return saved[uid] != nil }

    private func persist() { UserDefaults.standard.set(saved, forKey: SoundSettings.micSavedKey) }

    /// Mutes `d` (HAL queue only). Returns false when the device offers neither a mute switch nor a volume.
    func mute(_ d: SoundDevice) -> Bool {
        guard let fresh = SoundHAL.readDevice(d.id) else { return false }
        var value: Double
        if fresh.inMuteSettable {
            guard SoundHAL.setMute(fresh.id, .input, true) == noErr else { return false }
            value = -1
        } else if fresh.inVolumeSettable, let v = fresh.inVolume {
            value = v > 0.001 ? Double(v) : 0.7
            guard SoundHAL.setVolume(fresh.id, .input, 0) == noErr else { return false }
        } else {
            return false
        }
        lock.lock(); saved[fresh.uid] = value; persist(); lock.unlock()
        return true
    }

    /// Restores every saved microphone that is connected (HAL queue only).
    func restoreConnected() {
        let ids = SoundHAL.deviceIDs()
        for id in ids {
            guard let d = SoundHAL.readDevice(id), d.isInput else { continue }
            lock.lock(); let v = saved[d.uid]; lock.unlock()
            guard let v else { continue }
            if d.inMuteSettable { SoundHAL.setMute(id, .input, false) }
            if v >= 0, d.inVolumeSettable, (d.inVolume ?? 0) < 0.01 { SoundHAL.setVolume(id, .input, Float(v)) }
            lock.lock(); saved[d.uid] = nil; persist(); lock.unlock()
        }
    }
}

// MARK: - Mic mute on the engine

extension SoundEngine {
    func toggleMicMute() { setMicMuted(!micMuted) }

    func setMicMuted(_ muted: Bool) {
        guard muted != micMuted else { return }
        micMuted = muted
        UserDefaults.standard.set(muted, forKey: SoundSettings.micMutedKey)
        micMuteProblem = nil
        micFailed = []
        SoundMuteIndicator.shared.sync(muted: muted, animated: true)
        reconcileMic()
        // Keep listeners alive while muted so a newly selected mic is muted too.
        settingsChanged()
    }

    /// Makes reality match the "mic muted" switch. Only reacts to the set of microphones, never to level changes,
    /// so it can't fight the user adjusting input volume themselves.
    func reconcileMic() {
        if micMuted {
            guard loaded else { return }
            guard let d = defaultInput else {
                micMuteProblem = "No microphone is selected."
                return
            }
            if SoundMicStore.shared.contains(d.uid) || micFailed.contains(d.uid) { return }
            micFailed.insert(d.uid)   // cleared below on success; prevents re-entry while the write is in flight
            SoundHAL.queue.async {
                let ok = SoundMicStore.shared.mute(d)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if ok {
                            self.micFailed.remove(d.uid)
                            self.micMuteProblem = nil
                        } else {
                            self.micMuteProblem = "\(d.name) can't be muted from software. Pick another microphone or use its own mute switch."
                        }
                        self.refreshNow()
                    }
                }
            }
        } else if devices.contains(where: { $0.isInput && SoundMicStore.shared.contains($0.uid) }) {
            SoundHAL.queue.async {
                SoundMicStore.shared.restoreConnected()
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshNow() } }
            }
        }
    }
}

// MARK: - Floating indicator

/// Small pill near the top of the screen while the mic is muted. Not hidden from screen sharing on purpose:
/// it is for the user, and showing it on a shared screen is harmless.
@MainActor
final class SoundMuteIndicator {
    static let shared = SoundMuteIndicator()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var lastMuted: Bool?

    /// `animated` flashes a short "Mic on" confirmation when unmuting; at launch nothing flashes.
    func sync(muted: Bool, animated: Bool) {
        defer { lastMuted = muted }
        guard SoundSettings.mutedIndicator, !Services.isSnapshotRun else { close(); return }
        hideTask?.cancel()
        if muted {
            show(muted: true)
        } else if animated, lastMuted == true {
            show(muted: false)
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { self.close() }
            }
        } else {
            close()
        }
    }

    private func show(muted: Bool) {
        let host = NSHostingView(rootView: SoundMuteIndicatorView(muted: muted))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host
        p.setContentSize(size)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 10))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

struct SoundMuteIndicatorView: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 13, weight: .bold))
            Text(muted ? "Mic muted" : "Mic on")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(muted ? Color(hex: 0xFF3B30) : Color(hex: 0x28B84A)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .padding(6)
    }
}
