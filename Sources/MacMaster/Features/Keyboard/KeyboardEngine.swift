import AppKit
import Observation

/// Owns every background piece of the Keyboard feature and starts only what the user enabled.
/// `start()` / `stop()` are idempotent; settings changes are picked up automatically.
@MainActor
@Observable
final class KeyboardEngine {
    static let shared = KeyboardEngine()

    // Observable status for the UI.
    private(set) var accessibilityGranted = Permissions.isGranted(.accessibility)
    private(set) var tapRunning = false
    private(set) var hyperMapped = false
    private(set) var cleaningActive = false
    private(set) var hotkeyFailures: Set<UUID> = []

    /// Short list of what is currently on, e.g. for a Dashboard summary.
    var activeFeatures: [String] {
        var a: [String] = []
        if KeyboardPrefs.bool(KeyboardPrefs.hyperEnabled) { a.append("Hyper Key") }
        if !KeyboardStore.shared.shortcuts.filter({ $0.enabled && $0.combo != nil }).isEmpty { a.append("App Shortcuts") }
        if KeyboardPrefs.bool(KeyboardPrefs.cornersEnabled) { a.append("Hot Corners") }
        if KeyboardPrefs.bool(KeyboardPrefs.snippetsEnabled) { a.append("Snippets") }
        if KeyboardPrefs.bool(KeyboardPrefs.visualizerEnabled) { a.append("Key Visualizer") }
        if KeyboardPrefs.bool(KeyboardPrefs.cmdQGuard) { a.append("⌘Q Guard") }
        return a
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var tap: KeyboardMainTap?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private let visualizer = KeyboardVisualizerController()
    @ObservationIgnored private let quitHint = KeyboardQuitHintController()
    @ObservationIgnored private let cleaning = KeyboardCleaningController()
    @ObservationIgnored private var mappingWanted = false

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        cleaning.onChange = { [weak self] in self?.cleaningActive = self?.cleaning.isActive ?? false }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownForQuit() }
        }
        // Poll Accessibility (granted late, revoked, or the tap was disabled by the system).
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        reconcile()
    }

    func stop() {
        guard started else { return }
        started = false
        pollTimer?.invalidate(); pollTimer = nil
        debounce?.cancel(); debounce = nil
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil; terminateObserver = nil

        cleaning.stop()
        tap?.stop(); tap = nil
        tapRunning = false
        visualizer.setEnabled(false)
        quitHint.hide(after: 0)
        KeyboardHotkeys.shared.stop()
        hotkeyFailures = []
        KeyboardHotCorners.shared.stop()
        mappingWanted = false
        KeyboardHyperMapper.restore(wait: true)
        hyperMapped = false
    }

    private func shutDownForQuit() {
        cleaning.stop()
        tap?.stop()
        KeyboardHyperMapper.restore(wait: true)
    }

    // MARK: Reconcile

    private func scheduleReconcile() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private func poll() {
        let ax = Permissions.isGranted(.accessibility)
        if ax != accessibilityGranted { reconcile(); return }
        if let tap, ax, !tap.isEnabled { // system disabled it for good: rebuild
            tap.stop(); self.tap = nil
            reconcile()
        }
    }

    /// Brings every sub-feature in line with the current settings. Cheap when nothing changed.
    func reconcile() {
        guard started else { return }
        let store = KeyboardStore.shared
        let ax = Permissions.isGranted(.accessibility)
        if ax != accessibilityGranted { accessibilityGranted = ax }

        // Event-tap features.
        let hyperOn = KeyboardPrefs.bool(KeyboardPrefs.hyperEnabled)
        let key = KeyboardHyperKey.current
        let snippetsOn = KeyboardPrefs.bool(KeyboardPrefs.snippetsEnabled)
        let snippets: [KeyboardTapSnippet] = snippetsOn
            ? store.snippets.filter { $0.enabled && $0.trigger.count >= 2 && !$0.text.isEmpty }
                .map { KeyboardTapSnippet(chars: Array($0.trigger.utf16), text: $0.text) }
            : []
        let vizOn = KeyboardPrefs.bool(KeyboardPrefs.visualizerEnabled)
        let config = KeyboardTapConfig(hyper: hyperOn ? key : nil,
                                       tapEscape: KeyboardPrefs.bool(KeyboardPrefs.hyperTapEscape, default: true),
                                       snippets: snippets, visualizer: vizOn,
                                       cmdQ: KeyboardPrefs.bool(KeyboardPrefs.cmdQGuard))

        if config.needsTap && ax {
            if tap == nil {
                let t = KeyboardMainTap { out in
                    DispatchQueue.main.async { MainActor.assumeIsolated { KeyboardEngine.shared.handle(out) } }
                }
                if t.start() { tap = t }
            }
            tap?.update(config)
        } else if let t = tap {
            t.stop(); tap = nil
        }
        let running = tap != nil
        if running != tapRunning { tapRunning = running }

        // Caps Lock -> F18 only while something can turn F18 into Hyper; otherwise Caps Lock would be dead.
        let wantMapping = hyperOn && key == .caps && running
        if wantMapping != mappingWanted {
            mappingWanted = wantMapping
            if wantMapping { KeyboardHyperMapper.apply() } else { KeyboardHyperMapper.restore(wait: false) }
            hyperMapped = wantMapping
        } else if !wantMapping, !hyperOn, KeyboardHyperMapper.hasPendingRestore {
            KeyboardHyperMapper.restore(wait: false) // left over from a crash
        }

        visualizer.setEnabled(vizOn && running)

        // App shortcut hotkeys (Carbon, no Accessibility required).
        KeyboardHotkeys.shared.sync(store.shortcuts)
        if KeyboardHotkeys.shared.failures != hotkeyFailures { hotkeyFailures = KeyboardHotkeys.shared.failures }

        // Hot corners.
        if KeyboardPrefs.bool(KeyboardPrefs.cornersEnabled) { KeyboardHotCorners.shared.start() }
        else { KeyboardHotCorners.shared.stop() }
    }

    // MARK: Cleaning mode

    @discardableResult
    func startCleaning(seconds: Int) -> Bool {
        guard Permissions.isGranted(.accessibility) else { return false }
        return cleaning.start(seconds: seconds <= 0 ? 0 : max(5, seconds))
    }

    func stopCleaning() { cleaning.stop() }

    // MARK: Visualizer preview

    func previewVisualizer() {
        visualizer.setEnabled(true)
        visualizer.push(code: 40, flags: CGEventFlags([.maskCommand, .maskShift]).rawValue, char: 0)
        if !KeyboardPrefs.bool(KeyboardPrefs.visualizerEnabled) || !tapRunning {
            // Not enabled for real: let the preview fade, then switch off again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !(KeyboardPrefs.bool(KeyboardPrefs.visualizerEnabled) && self.tapRunning) { self.visualizer.setEnabled(false) }
                }
            }
        }
    }

    // MARK: Output from the tap thread

    private func handle(_ out: KeyboardTapOutput) {
        switch out {
        case .snippet(let text, let backspaces):
            KeyboardSnippetExpander.expand(text: text, backspaces: backspaces)

        case .key(let code, let flags, let char):
            visualizer.push(code: code, flags: flags, char: char)

        case .cmdQBegan(let token):
            let app = NSWorkspace.shared.frontmostApplication
            quitHint.show(appName: app?.localizedName ?? "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let tap = self.tap, tap.cmdQToken.withLock({ $0 }) == token else { return }
                    app?.terminate()
                    self.quitHint.hide(after: 0.1)
                }
            }

        case .cmdQEnded:
            quitHint.hide(after: 0.9)
        }
    }
}
