import SwiftUI
import AppKit
import IOKit.pwr_mgt
import Observation

enum ToolsAwakeDuration: String, CaseIterable, Identifiable {
    case m15, h1, h2, h5, indefinite, untilQuit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .m15: "15 min"
        case .h1: "1 hour"
        case .h2: "2 hours"
        case .h5: "5 hours"
        case .indefinite: "Indefinitely"
        case .untilQuit: "Until MacMaster quits"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .m15: 900
        case .h1: 3_600
        case .h2: 7_200
        case .h5: 18_000
        default: nil
        }
    }
}

enum ToolsAwakeMode: String, CaseIterable, Identifiable {
    case display, system
    var id: String { rawValue }
    var title: String { self == .display ? "Keep display on" : "Allow display sleep" }
    var detail: String {
        self == .display ? "Screen and Mac stay awake." : "Screen may turn off, but the Mac keeps running."
    }
}

/// Caffeine-style sleep prevention via IOKit power assertions.
@Observable
@MainActor
final class ToolsKeepAwake {
    static let shared = ToolsKeepAwake()

    private(set) var isActive = false           // assertions are currently held
    private(set) var isArmed = false            // waiting on a watched app
    private(set) var endDate: Date?
    private(set) var remaining: TimeInterval?
    private(set) var watchedAppName: String?
    private(set) var currentDuration: ToolsAwakeDuration?

    var mode: ToolsAwakeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode); if isActive { reassert() } }
    }
    var defaultDuration: ToolsAwakeDuration {
        didSet { UserDefaults.standard.set(defaultDuration.rawValue, forKey: Keys.duration) }
    }

    private enum Keys {
        static let mode = "mm.tools.keepawake.mode"
        static let duration = "mm.tools.keepawake.duration"
        static let resume = "mm.tools.keepawake.resume"
    }

    @ObservationIgnored private var assertionIDs: [IOPMAssertionID] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchedBundleID: String?
    @ObservationIgnored private var started = false

    private init() {
        let d = UserDefaults.standard
        mode = ToolsAwakeMode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .display
        defaultDuration = ToolsAwakeDuration(rawValue: d.string(forKey: Keys.duration) ?? "") ?? .indefinite
    }

    /// Restores an "Indefinitely" session across launches. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        if UserDefaults.standard.bool(forKey: Keys.resume) { begin(.indefinite) }
    }

    func stop() {
        release()
        timer?.invalidate(); timer = nil
        isActive = false; isArmed = false
        endDate = nil; remaining = nil
        watchedBundleID = nil; watchedAppName = nil; currentDuration = nil
        UserDefaults.standard.set(false, forKey: Keys.resume)
    }

    /// Menu-bar friendly: stops if on, otherwise starts with the default duration.
    func toggle() {
        if isActive || isArmed { stop() } else { begin(defaultDuration) }
    }

    func begin(_ duration: ToolsAwakeDuration) {
        stop()
        defaultDuration = duration
        currentDuration = duration
        if let s = duration.seconds { endDate = Date().addingTimeInterval(s); remaining = s }
        UserDefaults.standard.set(duration == .indefinite, forKey: Keys.resume)
        acquire()
        startTimer()
    }

    /// Keeps the Mac awake only while the app with this bundle ID is running.
    func beginWatching(bundleID: String, name: String) {
        stop()
        watchedBundleID = bundleID
        watchedAppName = name
        isArmed = true
        checkWatched()
        startTimer()
    }

    // MARK: Assertions

    private func acquire() {
        release()
        var types: [String] = ["PreventUserIdleSystemSleep"]
        if mode == .display { types.insert("PreventUserIdleDisplaySleep", at: 0) }
        for t in types {
            var id = IOPMAssertionID(0)
            let r = IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "MacMaster Keep Awake" as CFString, &id)
            if r == kIOReturnSuccess { assertionIDs.append(id) }
        }
        isActive = !assertionIDs.isEmpty
    }

    private func release() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs = []
        isActive = false
    }

    private func reassert() { acquire() }

    // MARK: Timer

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if let end = endDate {
            let r = end.timeIntervalSinceNow
            if r <= 0 { stop(); ToolsToastCenter.shared.show("Keep Awake finished"); return }
            remaining = r
        }
        if watchedBundleID != nil { checkWatched() }
    }

    private func checkWatched() {
        guard let id = watchedBundleID else { return }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        if running && !isActive { acquire() }
        if !running && isActive { release() }
    }

    // MARK: Presentation

    var statusText: String {
        if let name = watchedAppName {
            return isActive ? "Awake while \(name) runs" : "Waiting for \(name) to launch"
        }
        guard isActive else { return "Your Mac sleeps normally" }
        if let r = remaining { return "Awake for \(ToolsKeepAwake.countdown(r))" }
        return currentDuration == .untilQuit ? "Awake until MacMaster quits" : "Awake until you turn it off"
    }

    nonisolated static func countdown(_ s: TimeInterval) -> String {
        let t = Int(max(0, s.rounded(.up)))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - View

struct ToolsKeepAwakeView: View {
    private let awake = ToolsKeepAwake.shared
    @State private var runningApps: [(id: String, name: String)] = []
    @State private var watchSelection = ""

    var body: some View {
        Page {
            statusCard
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Stay awake for", symbol: "timer")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(ToolsAwakeDuration.allCases) { d in
                        Button { awake.begin(d) } label: {
                            Text(d.title).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .tint(awake.currentDuration == d && awake.isActive ? .orange : nil)
                    }
                }
                Text("\"Indefinitely\" survives relaunching MacMaster. \"Until MacMaster quits\" does not.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Behavior", symbol: "display")
                Picker("", selection: Binding(get: { awake.mode }, set: { awake.mode = $0 })) {
                    ForEach(ToolsAwakeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Text(awake.mode.detail).font(.caption).foregroundStyle(.secondary)
                Text("Menu bar toggle uses: \(awake.defaultDuration.title.lowercased()).").font(.caption).foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Keep awake while an app is running", symbol: "app.badge.checkmark")
                HStack {
                    Picker("App", selection: $watchSelection) {
                        Text("Choose an app…").tag("")
                        ForEach(runningApps, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 320)
                    Button { loadApps() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh running apps")
                    Button("Start watching") {
                        if let app = runningApps.first(where: { $0.id == watchSelection }) {
                            awake.beginWatching(bundleID: app.id, name: app.name)
                        }
                    }
                    .disabled(watchSelection.isEmpty)
                }
                Text("The Mac stays awake as long as the app is open, then goes back to normal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card()
        }
        .onAppear { loadApps() }
    }

    private var statusCard: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(Theme.gradient(awake.isActive ? ToolsTool.keepAwake.colors : Theme.Palette.neutral))
                    .frame(width: 84, height: 84)
                    .shadow(color: (awake.isActive ? Color.orange : .clear).opacity(0.5), radius: 18)
                Image(systemName: awake.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 34)).foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: awake.isActive)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let r = awake.remaining, awake.isActive {
                    Text(ToolsKeepAwake.countdown(r))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                } else {
                    Text(awake.isActive ? "Awake" : (awake.isArmed ? "Armed" : "Off"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Text(awake.statusText).foregroundStyle(.secondary)
            }
            Spacer()
            Button(awake.isActive || awake.isArmed ? "Turn Off" : "Turn On") { awake.toggle() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(awake.isActive || awake.isArmed ? .red : .orange)
        }
        .card()
    }

    private func loadApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
