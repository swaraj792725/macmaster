import Foundation
import AppKit
import Observation
import os

// MARK: - Preferences

enum TPPrefs {
    static let mode = "mm.teleprompter.mode"
    static let wpm = "mm.teleprompter.wpm"
    static let fontSize = "mm.teleprompter.fontSize"
    static let textWidth = "mm.teleprompter.textWidth"
    static let notchHeight = "mm.teleprompter.notchHeight"
    static let opacity = "mm.teleprompter.opacity"
    static let mirror = "mm.teleprompter.mirror"
    static let highlight = "mm.teleprompter.highlight"
    static let countdown = "mm.teleprompter.countdown"
    static let voice = "mm.teleprompter.voice"
    static let voiceThreshold = "mm.teleprompter.voiceThreshold"
    static let hotkey = "mm.teleprompter.hotkey"
    static let floatFrame = "mm.teleprompter.floatFrame"
}

enum TeleprompterMode: String, CaseIterable, Identifiable {
    case notch, floating
    var id: String { rawValue }
    var title: String { self == .notch ? "Notch bar" : "Floating window" }
}

enum TeleprompterState { case idle, countdown, playing, paused }

/// The scroll position lives on its own object so only the overlay's scrolling layer re-renders at 60 Hz.
@MainActor @Observable
final class TeleprompterScroll {
    var offset: CGFloat = 0
}

// MARK: - Engine

/// Script, settings and playback for the teleprompter. The 60 Hz tick exists only while the script is
/// scrolling (or easing to a jumped line); the microphone only runs while the overlay is open.
@MainActor @Observable
final class TeleprompterEngine {
    static let shared = TeleprompterEngine()
    private static let log = Logger(subsystem: "com.macmaster.app", category: "teleprompter")
    static let hotKeyName = "teleprompter.playpause"
    static let screenPadding: CGFloat = 28

    // Settings (persisted on change)
    var mode: TeleprompterMode { didSet { store(mode.rawValue, TPPrefs.mode); if mode != oldValue { modeChanged() } } }
    var wpm: Double { didSet { store(wpm, TPPrefs.wpm) } }
    var fontSize: Double { didSet { store(fontSize, TPPrefs.fontSize); if fontSize != oldValue { relayout() } } }
    var textWidth: Double { didSet { store(textWidth, TPPrefs.textWidth); if textWidth != oldValue { geometryChanged() } } }
    var notchHeight: Double { didSet { store(notchHeight, TPPrefs.notchHeight); geometryChanged() } }
    var opacity: Double { didSet { store(opacity, TPPrefs.opacity) } }
    var mirror: Bool { didSet { store(mirror, TPPrefs.mirror) } }
    var highlight: Bool { didSet { store(highlight, TPPrefs.highlight) } }
    var countdownEnabled: Bool { didSet { store(countdownEnabled, TPPrefs.countdown) } }
    var voiceThreshold: Double { didSet { store(voiceThreshold, TPPrefs.voiceThreshold) } }
    private(set) var voicePacing: Bool

    // Script
    var script: String { didSet { if !loadingScript { scriptChanged() } } }

    // Playback
    private(set) var state: TeleprompterState = .idle
    private(set) var countdown: Int?
    private(set) var layout: PromptLayout = .empty
    private(set) var overlayOpen = false
    private(set) var voiceSpeaking = false
    private(set) var micDenied = false
    private(set) var atEnd = false
    var message: String?
    let scroll = TeleprompterScroll()

    @ObservationIgnored private var layoutWidth: CGFloat = 560
    @ObservationIgnored private var scriptLoaded = false
    @ObservationIgnored private var loadingScript = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var jumpTarget: CGFloat?
    @ObservationIgnored private let pacer = VoicePacer()
    @ObservationIgnored private var voiceMult = 0.0
    @ObservationIgnored private var voiceOn = false
    @ObservationIgnored private var voiceLastLoud: CFTimeInterval = 0
    @ObservationIgnored private var started = false

    private init() {
        let d = UserDefaults.standard
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        mode = TeleprompterMode(rawValue: d.string(forKey: TPPrefs.mode) ?? "") ?? .notch
        wpm = num(TPPrefs.wpm, 150)
        fontSize = num(TPPrefs.fontSize, 34)
        textWidth = num(TPPrefs.textWidth, 560)
        notchHeight = num(TPPrefs.notchHeight, 200)
        opacity = num(TPPrefs.opacity, 0.92)
        mirror = flag(TPPrefs.mirror, false)
        highlight = flag(TPPrefs.highlight, true)
        countdownEnabled = flag(TPPrefs.countdown, true)
        voiceThreshold = num(TPPrefs.voiceThreshold, -40)
        voicePacing = flag(TPPrefs.voice, false)
        script = ""
    }

    private func store(_ v: Any, _ key: String) { UserDefaults.standard.set(v, forKey: key) }

    // MARK: Launch

    /// Registers the play/pause hot key (none by default). Nothing else runs at idle.
    func start() {
        guard !started else { return }
        started = true
        registerHotKey()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TeleprompterEngine.shared.flushScript() }
        }
    }

    func registerHotKey() {
        GlobalHotKeys.shared.register(Self.hotKeyName, defaultsKey: TPPrefs.hotkey) {
            TeleprompterEngine.shared.togglePlayPause()
        }
    }

    // MARK: Script storage

    private var scriptURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacMaster/Teleprompter/script.txt")
    }

    func ensureScriptLoaded() {
        guard !scriptLoaded else { return }
        scriptLoaded = true
        guard let data = try? Data(contentsOf: scriptURL) else { return }
        loadingScript = true
        script = String(decoding: data, as: UTF8.self)
        loadingScript = false
    }

    private func scriptChanged() {
        scriptLoaded = true
        if overlayOpen { relayout() }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushScript()
        }
    }

    func flushScript() {
        guard scriptLoaded else { return }
        saveTask?.cancel(); saveTask = nil
        let url = scriptURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            message = "Couldn't save the script: \(error.localizedDescription)"
            Self.log.error("script save failed: \(error.localizedDescription)")
        }
    }

    var wordCount: Int { script.split(whereSeparator: { $0.isWhitespace }).count }

    /// Reading time at the current speed.
    var estimatedSeconds: Int { Int((Double(wordCount) * 60 / wpm).rounded()) }

    /// Loads a .txt or .md file into the script (markdown is flattened to plain text).
    func importScript(from url: URL) {
        guard let data = try? Data(contentsOf: url), data.count < 5_000_000 else {
            message = "Couldn't read that file."
            return
        }
        var text = String(decoding: data, as: UTF8.self)
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) { text = PromptText.stripMarkdown(text) }
        script = text
        message = nil
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .init(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .txt or .md script"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importScript(from: url)
    }

    // MARK: Layout

    /// Called by the overlay when the text area width is known or changes.
    func setLayoutWidth(_ w: CGFloat) {
        guard abs(w - layoutWidth) > 1 else { return }
        layoutWidth = w
        if overlayOpen { relayout() }
    }

    private func relayout() {
        guard overlayOpen else { return }
        let old = layout.progress(at: scroll.offset)
        let hadLines = !layout.lines.isEmpty
        layout = PromptLayout.make(text: script, fontSize: CGFloat(fontSize), width: layoutWidth)
        jumpTarget = nil
        scroll.offset = hadLines ? layout.offset(line: min(old.line, max(0, layout.lines.count - 1)), fraction: old.fraction)
                                 : layout.startOffset
    }

    private func geometryChanged() {
        guard overlayOpen else { return }
        TeleprompterOverlayController.shared.applyGeometry()
    }

    private func modeChanged() {
        guard overlayOpen else { return }
        TeleprompterOverlayController.shared.reopen()
    }

    // MARK: Playback

    /// Opens the overlay and starts (with the 3-2-1 if enabled).
    func begin() {
        ensureScriptLoaded()
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Add a script first."
            return
        }
        message = nil
        guard !Services.isSnapshotRun else { return }
        if !overlayOpen {
            overlayOpen = true
            layoutWidth = TeleprompterOverlayController.shared.show()
            layout = PromptLayout.make(text: script, fontSize: CGFloat(fontSize), width: layoutWidth)
            scroll.offset = layout.startOffset
            atEnd = false
            startVoiceIfWanted()
        }
        if state == .idle || state == .paused { startPlayback() }
    }

    private func startPlayback() {
        if atEnd { scroll.offset = layout.startOffset; atEnd = false }
        guard countdownEnabled, state == .idle else { play(); return }
        state = .countdown
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.countdown = n
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.countdown = nil
            self.countdownTask = nil
            self.play()
        }
    }

    func play() {
        guard overlayOpen else { begin(); return }
        countdownTask?.cancel(); countdownTask = nil
        countdown = nil
        if atEnd { scroll.offset = layout.startOffset; atEnd = false }
        state = .playing
        lastTick = CACurrentMediaTime()
        ensureTicking()
    }

    func pause() {
        guard overlayOpen else { return }
        countdownTask?.cancel(); countdownTask = nil
        countdown = nil
        state = .paused
        ensureTicking()
    }

    func togglePlayPause() {
        switch state {
        case .idle: begin()
        case .countdown, .playing: pause()
        case .paused: play()
        }
    }

    /// Closes the overlay, stops the mic and rewinds.
    func stop() {
        countdownTask?.cancel(); countdownTask = nil
        countdown = nil
        state = .idle
        jumpTarget = nil
        ensureTicking()
        stopVoice()
        let wasOpen = overlayOpen
        overlayOpen = false
        if wasOpen { TeleprompterOverlayController.shared.close() }
        layout = .empty
        scroll.offset = 0
        atEnd = false
    }

    /// Faster / slower in 10 wpm steps.
    func nudgeSpeed(_ delta: Double) { wpm = min(400, max(40, wpm + delta)) }

    /// Moves the reading marker `n` lines (negative = back), easing there.
    func jump(lines n: Int) {
        guard overlayOpen, !layout.lines.isEmpty else { return }
        let base = jumpTarget ?? scroll.offset
        let i = max(0, min(layout.lines.count - 1, layout.index(at: base) + n))
        jumpTarget = layout.lines[i].center
        atEnd = false
        lastTick = CACurrentMediaTime()
        ensureTicking()
    }

    // MARK: Tick

    private func ensureTicking() {
        let need = state == .playing || jumpTarget != nil
        if need {
            guard tickTimer == nil else { return }
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                MainActor.assumeIsolated { TeleprompterEngine.shared.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        var off = scroll.offset
        if let target = jumpTarget {
            let d = target - off
            if abs(d) < 0.5 { off = target; jumpTarget = nil }
            else { off += d * CGFloat(1 - exp(-dt * 14)) }
        } else if state == .playing, !layout.lines.isEmpty {
            let mult = paceMultiplier(dt: dt, now: now)
            if mult > 0.001 {
                let line = layout.lines[layout.index(at: off)]
                let secs = max(0.25, Double(max(line.words, 1)) * 60 / wpm)
                off += CGFloat(Double(line.height) / secs * mult * dt)
            }
            if off >= layout.endOffset {
                off = layout.endOffset
                atEnd = true
                state = .paused
            }
        }
        if abs(off - scroll.offset) > 0.01 { scroll.offset = off }
        ensureTicking()
    }

    // MARK: Voice pacing

    func setVoicePacing(_ on: Bool) {
        guard on else { voicePacing = false; store(false, TPPrefs.voice); stopVoice(); return }
        Permissions.requestMedia(.microphone) { ok in
            let e = TeleprompterEngine.shared
            e.micDenied = !ok
            e.voicePacing = ok
            e.store(ok, TPPrefs.voice)
            if ok { e.startVoiceIfWanted() }
        }
    }

    private func startVoiceIfWanted() {
        guard voicePacing, overlayOpen, !pacer.isRunning else { return }
        guard Permissions.isGranted(.microphone) else {
            micDenied = true
            voicePacing = false
            return
        }
        do { try pacer.start(); micDenied = false }
        catch {
            message = "Voice pacing couldn't start: \(error.localizedDescription)"
            voicePacing = false
        }
    }

    private func stopVoice() {
        pacer.stop()
        voiceOn = false
        voiceMult = 0
        if voiceSpeaking { voiceSpeaking = false }
    }

    /// 1 when voice pacing is off; otherwise a 0...1 ramp that follows whether you are speaking.
    private func paceMultiplier(dt: Double, now: CFTimeInterval) -> Double {
        guard voicePacing, pacer.isRunning else { return 1 }
        let db = pacer.levelDB
        let on = voiceThreshold, off = voiceThreshold - 8
        if db > on { voiceOn = true; voiceLastLoud = now }
        else if db > off { if voiceOn { voiceLastLoud = now } }
        else if voiceOn, now - voiceLastLoud > 0.7 { voiceOn = false }
        if voiceOn != voiceSpeaking { voiceSpeaking = voiceOn }
        let target = voiceOn ? 1.0 : 0.0
        voiceMult += (target - voiceMult) * min(1, dt * (target > voiceMult ? 8 : 3))
        return voiceMult
    }
}

extension AppSearchIndex {
    /// Teleprompter settings, added to the global search.
    static let teleprompterEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Teleprompter", "Teleprompter script", "teleprompter script editor import text markdown cue", anchor: "teleprompter.script", tab: "teleprompter"),
        SearchEntry(.tools, crumb: "Teleprompter", "Teleprompter speed", "teleprompter scroll speed wpm words per minute font size countdown mirror", anchor: "teleprompter.playback", tab: "teleprompter"),
        SearchEntry(.tools, crumb: "Teleprompter", "Notch teleprompter bar", "teleprompter notch bar top camera floating window overlay hidden from screen share hotkey", anchor: "teleprompter.overlay", tab: "teleprompter"),
        SearchEntry(.tools, crumb: "Teleprompter", "Voice-paced scrolling", "teleprompter voice microphone follow speaking pace scroll", anchor: "teleprompter.voice", tab: "teleprompter"),
    ]
}
