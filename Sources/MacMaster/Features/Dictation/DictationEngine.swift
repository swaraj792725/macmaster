import AppKit
import Carbon.HIToolbox
import Observation
import Speech
import os

enum DictationKeys {
    static let enabled = "mm.dictation.enabled"
    static let hotkey = "mm.dictation.hotkey"
    static let mode = "mm.dictation.mode"             // "hold" | "toggle"
    static let locale = "mm.dictation.locale"         // "" = the Mac's language
    static let punctuation = "mm.dictation.punctuation"
    static let trailingSpace = "mm.dictation.trailingSpace"
    static let copyOnly = "mm.dictation.copyOnly"
    static let voiceCommands = "mm.dictation.voiceCommands"
    static let onDeviceOnly = "mm.dictation.onDeviceOnly"
    static let showHUD = "mm.dictation.hud"
}

struct DictationEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
}

enum DictationLanguages {
    struct Item: Identifiable, Hashable { let id: String; let name: String }

    /// Every language macOS can recognize, sorted by name.
    static let all: [Item] = {
        let loc = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { Item(id: $0.identifier, name: loc.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// The locale to recognize: the saved one, or the Mac's own language when it is supported, else US English.
    static func resolve(_ stored: String) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "_") }
        if !stored.isEmpty, let hit = supported.first(where: { norm($0.identifier) == norm(stored) }) { return hit }
        let current = Locale.current
        if let hit = supported.first(where: { norm($0.identifier) == norm(current.identifier) }) { return hit }
        if let code = current.language.languageCode?.identifier,
           let hit = supported.first(where: { $0.language.languageCode?.identifier == code && $0.identifier.hasSuffix(current.region?.identifier ?? "") })
            ?? supported.first(where: { $0.language.languageCode?.identifier == code }) { return hit }
        return Locale(identifier: "en_US")
    }
}

/// Hold a shortcut, speak, and the text is typed into whatever app you are in. Recognition is on-device
/// whenever the language supports it. The microphone is only open between press and release.
@MainActor @Observable
final class DictationEngine {
    static let shared = DictationEngine()

    enum Phase { case idle, starting, listening, finishing }

    private(set) var phase: Phase = .idle
    private(set) var isEnabled: Bool
    private(set) var history: [DictationEntry] = []
    /// Latest problem, shown in the tool view until the next successful run.
    private(set) var lastError: String?

    @ObservationIgnored private let log = Logger(subsystem: "com.macmaster.app", category: "dictation")
    @ObservationIgnored private let hud = DictationHUD()
    @ObservationIgnored private var started = false

    // One utterance. `sid` changes every time so late callbacks from an old one are ignored.
    @ObservationIgnored private var sid = 0
    @ObservationIgnored private var capture: DictationAudioCapture?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var releaseRequested = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var maxTask: Task<Void, Never>?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var useHUD = true

    private static let maxSeconds: TimeInterval = 60
    private static let historyLimit = 20

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: DictationKeys.enabled)
    }

    func start() {
        guard !started else { return }
        started = true
        registerHotKey()
    }

    // MARK: Settings

    /// Turns Dictation on or off. Turning on asks for the microphone and speech recognition (once each).
    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: DictationKeys.enabled)
        registerHotKey()
        if on {
            Permissions.requestMedia(.microphone) { _ in
                if Permissions.isGranted(.microphone) || Permissions.mediaCanPrompt(.speechRecognition) {
                    Permissions.requestMedia(.speechRecognition)
                }
            }
        } else {
            cancel()
        }
    }

    func registerHotKey() {
        guard isEnabled else { GlobalHotKeys.shared.unregister("dictation.talk"); return }
        GlobalHotKeys.shared.register("dictation.talk", defaultsKey: DictationKeys.hotkey, press: { [weak self] in
            self?.hotKeyPressed()
        }, release: { [weak self] in
            self?.hotKeyReleased()
        })
    }

    var hasHotKey: Bool { StoredHotKey.load(DictationKeys.hotkey) != nil }

    private var isToggleMode: Bool { UserDefaults.standard.string(forKey: DictationKeys.mode) == "toggle" }

    func clearHistory() { history.removeAll() }

    func copy(_ entry: DictationEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
    }

    // MARK: Hotkey

    private func hotKeyPressed() {
        guard isEnabled else { return }
        if isToggleMode {
            switch phase {
            case .idle: begin()
            case .starting, .listening: finish()
            case .finishing: break
            }
        } else if phase == .idle {
            begin()
        }
    }

    private func hotKeyReleased() {
        guard isEnabled, !isToggleMode else { return }
        switch phase {
        case .starting, .listening: finish()
        default: break
        }
    }

    // MARK: Utterance

    private func begin() {
        let d = UserDefaults.standard
        useHUD = d.object(forKey: DictationKeys.showHUD) as? Bool ?? true
        lastError = nil

        guard Permissions.isGranted(.microphone) else {
            fail("Microphone access is off. Allow it in System Settings › Privacy & Security.")
            if Permissions.mediaCanPrompt(.microphone) { Permissions.requestMedia(.microphone) }
            return
        }
        guard Permissions.isGranted(.speechRecognition) else {
            fail("Speech Recognition access is off. Allow it in System Settings › Privacy & Security.")
            if Permissions.mediaCanPrompt(.speechRecognition) { Permissions.requestMedia(.speechRecognition) }
            return
        }
        let locale = DictationLanguages.resolve(d.string(forKey: DictationKeys.locale) ?? "")
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            fail("Speech recognition isn't available right now. Try again in a moment.")
            return
        }
        let onDeviceOnly = d.object(forKey: DictationKeys.onDeviceOnly) as? Bool ?? true
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        } else if onDeviceOnly {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            fail("\(name) can't be recognized on this Mac. Pick another language, or allow online recognition in Dictation settings.")
            return
        }
        req.addsPunctuation = d.object(forKey: DictationKeys.punctuation) as? Bool ?? true

        sid += 1
        let id = sid
        recognizer = rec
        request = req
        partial = ""
        releaseRequested = false
        startedAt = Date()
        phase = .starting
        if useHUD { hud.showListening() }

        task = DictationRecognition.start(recognizer: rec, request: req) { [weak self] text, isFinal, error, noSpeech in
            Task { @MainActor in self?.recognition(id, text: text, isFinal: isFinal, error: error, noSpeech: noSpeech) }
        }

        let cap = DictationAudioCapture()
        capture = cap
        let weakEngine: DictationEngine? = self   // singleton, lives for the whole run
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                try cap.start(request: req) { level in
                    Task { @MainActor in weakEngine?.level(id, level) }
                }
                result = .success(())
            } catch { result = .failure(error) }
            let message: String? = {
                guard case .failure(let e) = result else { return nil }
                if case DictationAudioCapture.StartError.noInput = e { return "No microphone found." }
                return "The microphone could not be opened."
            }()
            await MainActor.run {
                if let e = weakEngine { e.audioStarted(id, capture: cap, error: message) } else { cap.stop() }
            }
        }
    }

    private func audioStarted(_ id: Int, capture cap: DictationAudioCapture, error: String?) {
        // Cancelled while the microphone was still opening: close it again.
        guard id == sid, phase == .starting else { cap.stop(); return }
        if let error { fail(error); teardown(); return }
        phase = .listening
        maxTask?.cancel()
        maxTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishIfCurrent(id)
        }
        if releaseRequested { finish() }
    }

    private func finishIfCurrent(_ id: Int) {
        guard id == sid, phase == .listening || phase == .starting else { return }
        finish()
    }

    private func level(_ id: Int, _ value: Float) {
        guard id == sid, useHUD else { return }
        hud.push(level: value)
    }

    /// Stop listening and turn what was heard into text.
    private func finish() {
        switch phase {
        case .starting:
            releaseRequested = true
        case .listening:
            // A quick tap in hold mode is a slip, not a sentence.
            if !isToggleMode, Date().timeIntervalSince(startedAt) < 0.35, partial.isEmpty { cancel(); return }
            phase = .finishing
            maxTask?.cancel()
            capture?.stop()
            request?.endAudio()
            if useHUD { hud.showWorking() }
            let id = sid
            finishTimeout?.cancel()
            finishTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.complete(id)
            }
        default: break
        }
    }

    func cancel() {
        guard phase != .idle else { hud.hide(); return }
        sid += 1
        teardown()
        hud.hide()
    }

    private func teardown() {
        maxTask?.cancel(); finishTimeout?.cancel()
        capture?.stop(); capture = nil
        task?.cancel(); task = nil
        request = nil; recognizer = nil
        phase = .idle
    }

    private func recognition(_ id: Int, text: String?, isFinal: Bool, error: String?, noSpeech: Bool) {
        guard id == sid, phase != .idle else { return }
        if let text {
            partial = text
            if useHUD, phase == .listening || phase == .starting { hud.update(text: text) }
            if isFinal { complete(id) }
            return
        }
        // The recognizer stopped on its own, with no result.
        if !partial.isEmpty { complete(id); return }
        if noSpeech {
            sid += 1; teardown(); hud.hide()
            return
        }
        fail(error.map { "Recognition failed: \($0)" } ?? "Recognition failed.")
        sid += 1; teardown()
    }

    /// Final (or best available) text is in: clean it up and insert it.
    private func complete(_ id: Int) {
        guard id == sid, phase != .idle else { return }
        let raw = partial
        sid += 1
        teardown()
        let d = UserDefaults.standard
        let punct = d.object(forKey: DictationKeys.punctuation) as? Bool ?? true
        let text = DictationText.process(raw, .init(
            voiceCommands: d.object(forKey: DictationKeys.voiceCommands) as? Bool ?? true,
            recognizerPunctuates: punct,
            trailingSpace: d.object(forKey: DictationKeys.trailingSpace) as? Bool ?? true))
        guard !text.isEmpty else { hud.hide(); return }
        history.insert(DictationEntry(date: Date(), text: text.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        deliver(text, copyOnly: d.object(forKey: DictationKeys.copyOnly) as? Bool ?? false)
    }

    private func fail(_ message: String) {
        lastError = message
        log.error("\(message, privacy: .public)")
        if useHUD { hud.showError(message) }
        else { Notifier.post(title: "Dictation", body: message, id: "mm.dictation.error", sound: false) }
    }

    // MARK: Insert

    private func deliver(_ text: String, copyOnly: Bool) {
        if copyOnly {
            DictationInserter.copy(text)
            if useHUD { hud.showDone("Copied") }
            return
        }
        guard Permissions.isGranted(.accessibility) else {
            DictationInserter.copy(text)
            lastError = "Accessibility is off, so the text was copied but not pasted. Allow it in System Settings › Privacy & Security."
            if useHUD { hud.showError("Copied. Allow Accessibility to paste automatically.") }
            return
        }
        DictationInserter.paste(text)
        if useHUD { hud.showDone("Done", hideAfter: 0.6) }
    }
}

/// Puts text into the frontmost app by pasting it, then puts the user's clipboard back.
@MainActor
enum DictationInserter {
    private typealias Saved = [[(NSPasteboard.PasteboardType, Data)]]
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: Saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient) // clipboard managers skip transient items
        pb.writeObjects([item])
        let change = pb.changeCount
        // A moment for the shortcut's own keys to be let go, so ⌘V isn't seen as ⌘⌥V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            KeyboardKeyPoster.tap(CGKeyCode(keyCode(for: "v") ?? 9), flags: .maskCommand)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 + 0.6) {
            let pb = NSPasteboard.general
            guard pb.changeCount == change else { return } // the user copied something meanwhile
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.compactMap { pairs in
                guard !pairs.isEmpty else { return nil }
                let it = NSPasteboardItem()
                for (t, d) in pairs { it.setData(d, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Key that types `ch` on the current layout (Dvorak and friends), so ⌘V is really ⌘V.
    private static func keyCode(for ch: Character) -> UInt16? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 as Range<UInt16> {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr, len == 1, let u = Unicode.Scalar(chars[0]), Character(u) == ch { return code }
            }
            return nil
        }
    }
}

extension AppSearchIndex {
    /// Dictation settings, added to the global search.
    static let dictationEntries: [SearchEntry] = [
        SearchEntry(.tools, crumb: "Dictation", "Dictation shortcut", "push to talk hold key record voice hotkey", tab: "dictation"),
        SearchEntry(.tools, crumb: "Dictation", "Dictation language", "speech recognition locale language on-device", tab: "dictation"),
        SearchEntry(.tools, crumb: "Dictation", "Press to start, press to stop", "toggle mode hold push to talk", tab: "dictation"),
        SearchEntry(.tools, crumb: "Dictation", "Copy only, don't paste", "clipboard paste insert text", tab: "dictation"),
        SearchEntry(.tools, crumb: "Dictation", "Automatic punctuation", "commas periods voice commands new line new paragraph", tab: "dictation"),
        SearchEntry(.tools, crumb: "Dictation", "Dictation history", "transcripts copy last recent", tab: "dictation"),
    ]
}
