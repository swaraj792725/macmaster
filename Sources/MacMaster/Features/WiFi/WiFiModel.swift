import SwiftUI
import AppKit
import CoreWLAN
import Network
import Observation

/// CoreWLAN event callbacks arrive on arbitrary threads; forward them as a plain closure.
private final class WiFiEventListener: NSObject, CWEventDelegate, @unchecked Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { handler() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { handler() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { handler() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { handler() }
}

/// Shared Wi-Fi state for the menu bar item, its popover and the sidebar page.
///
/// Cost model: while nothing is on screen it only reads CoreWLAN on a slow timer (plus link-change events).
/// Everything heavier (IP info, ping, netstat, public IP, scan, speed test) runs on demand, off the main thread.
@Observable
@MainActor
final class WiFiModel {
    static let shared = WiFiModel()

    enum ScanState: Equatable { case idle, scanning, done, needsLocation, failed(String) }

    private(set) var link = WiFiLink()
    private(set) var ip = WiFiIPInfo()
    private(set) var publicIP: WiFiRemote<String> = .idle
    private(set) var gatewayPing: WiFiPing?
    private(set) var internetPing: WiFiPing?
    private(set) var pinging = false
    private(set) var connections: Int?
    private(set) var networks: [WiFiNetwork] = []
    private(set) var scanState: ScanState = .idle
    private(set) var joiningID: String?
    private(set) var joinError: String?
    /// Network waiting for the user to type a password.
    var passwordTargetID: String?
    private(set) var locationGranted = Permissions.locationGranted
    private(set) var actionError: String?
    /// Latest internet latency for the "ping" bar style (nil until measured). Refreshed every 30 s, only for that style.
    private(set) var barPingMs: Int?

    /// Called after every link read so the menu bar can redraw when its signature changed.
    @ObservationIgnored var onUpdate: (() -> Void)?

    @ObservationIgnored private var barActive = false
    @ObservationIgnored private var uiCount = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval = 0.0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var needsFullRead = true
    @ObservationIgnored private var lastFullRead = Date.distantPast
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var monitoring = false
    @ObservationIgnored private var listener: WiFiEventListener?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var networkKey = ""
    @ObservationIgnored private var detailsInFlight = false
    @ObservationIgnored private var publicIPKey = ""
    @ObservationIgnored private var publicIPDate = Date.distantPast
    @ObservationIgnored private var promptedLocation = false
    @ObservationIgnored private var barPingTask: Task<Void, Never>?

    private init() {
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.paused = true }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.paused = false; self?.scheduleRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .locationAuthorizationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.locationGranted = Permissions.locationGranted
                self?.scheduleRefresh()
            }
        })
    }

    // MARK: Demand

    /// The menu bar item wants link updates.
    func setBarActive(_ on: Bool) {
        barActive = on
        reconfigure()
    }

    /// A popover or page is on screen: poll faster and load the heavier details once.
    func uiAppeared() {
        uiCount += 1
        SystemMonitor.shared.start()
        reconfigure()
        refreshDetails()
    }

    func uiDisappeared() {
        uiCount = max(0, uiCount - 1)
        reconfigure()
    }

    /// Re-evaluates timer interval and event monitoring. Idempotent; call after settings change.
    func reconfigure() {
        let want = barActive || uiCount > 0 || WiFiAutomations.shared.hasActiveRules
        updateBarPing()
        guard want else { stopMonitoring(); return }
        if !monitoring { startMonitoring() }
        let interval = uiCount > 0 ? 2 : WiFiSettings.interval
        if timer == nil || interval != timerInterval {
            timer?.invalidate()
            timerInterval = interval
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            t.tolerance = interval * 0.25
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        }
    }

    /// Slow latency probe, only while the menu bar shows the ping style and Wi-Fi is up.
    private func updateBarPing() {
        let wanted = barActive && WiFiSettings.style == .ping
        if !wanted { barPingTask?.cancel(); barPingTask = nil; if barPingMs != nil { barPingMs = nil }; return }
        guard barPingTask == nil else { return }
        barPingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.link.isConnected, !self.paused {
                    let ms = await Task.detached(priority: .utility) { WiFiTools.pingOnce("1.1.1.1") }.value
                    let v = ms.map { Int($0.rounded()) }
                    if v != self.barPingMs { self.barPingMs = v; self.onUpdate?() }
                } else if let self, self.barPingMs != nil { self.barPingMs = nil; self.onUpdate?() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func startMonitoring() {
        monitoring = true
        let l = WiFiEventListener { Task { @MainActor in WiFiModel.shared.scheduleRefresh() } }
        listener = l
        let client = CWWiFiClient.shared()
        client.delegate = l
        for type in [CWEventType.powerDidChange, .ssidDidChange, .bssidDidChange, .linkDidChange] {
            try? client.startMonitoringEvent(with: type)
        }
        let pm = NWPathMonitor()
        pm.pathUpdateHandler = { _ in Task { @MainActor in WiFiModel.shared.scheduleRefresh() } }
        pm.start(queue: DispatchQueue(label: "macmaster.wifi.path", qos: .utility))
        pathMonitor = pm
    }

    private func stopMonitoring() {
        timer?.invalidate(); timer = nil; timerInterval = 0
        debounce?.cancel()
        guard monitoring else { return }
        monitoring = false
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
        CWWiFiClient.shared().delegate = nil
        listener = nil
        pathMonitor?.cancel(); pathMonitor = nil
    }

    /// Coalesces bursts of link events into one read.
    private func scheduleRefresh() {
        needsFullRead = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: Link polling

    func tick() {
        guard !reading, !paused else { return }
        reading = true
        // Full read when something changed, a Wi-Fi surface is open, or once a minute; otherwise just the signal.
        let full = needsFullRead || uiCount > 0 || Date().timeIntervalSince(lastFullRead) > 60
        let base = link
        if full { needsFullRead = false; lastFullRead = Date() }
        Task.detached(priority: .utility) {
            var l = full ? WiFiReader.readLink() : WiFiReader.readSignal(base: base)
            // Power or association flipped under a light read: fetch the rest now.
            if !full, l.powerOn != base.powerOn || (l.rssi == 0) != (base.rssi == 0) { l = WiFiReader.readLink() }
            await WiFiModel.shared.apply(l)
        }
    }

    private func apply(_ l: WiFiLink) {
        reading = false
        if l != link { link = l }
        let key = "\(l.powerOn)|\(l.isConnected)|\(l.ssid ?? "")|\(l.bssid ?? "")|\(l.interfaceName ?? "")"
        if key != networkKey {
            networkKey = key
            publicIPDate = .distantPast
            if uiCount > 0 { refreshDetails() }
        }
        WiFiAutomations.shared.linkChanged(powerOn: l.powerOn, connected: l.isConnected, ssid: l.ssid)
        onUpdate?()
    }

    // MARK: On-demand details

    /// IP info, latency, connection count and public IP. Called when a Wi-Fi surface opens.
    func refreshDetails() {
        checkLocation()
        guard !detailsInFlight else { return }
        detailsInFlight = true
        let name = link.interfaceName
        Task {
            let info = await Task.detached(priority: .utility) { WiFiReader.readIPInfo(interface: name) }.value
            if info != ip { ip = info }
            detailsInFlight = false
            runPings()
            fetchPublicIP()
            let n = await Task.detached(priority: .utility) { WiFiTools.establishedConnections() }.value
            connections = n
        }
    }

    func runPings() {
        guard !pinging else { return }
        guard link.isConnected else { gatewayPing = nil; internetPing = nil; return }
        pinging = true
        let router = ip.router
        Task {
            async let gw: WiFiPing? = {
                guard let router else { return nil }
                return await Task.detached(priority: .utility) { WiFiTools.ping(router) }.value
            }()
            async let net = Task.detached(priority: .utility) { WiFiTools.ping("1.1.1.1") }.value
            gatewayPing = await gw
            internetPing = await net
            pinging = false
        }
    }

    /// Cached for 10 minutes and per network; skipped entirely when the user turned it off.
    func fetchPublicIP(force: Bool = false) {
        guard WiFiSettings.publicIPEnabled else { publicIP = .idle; return }
        guard link.isConnected else { publicIP = .idle; return }
        if !force, publicIP.value != nil, Date().timeIntervalSince(publicIPDate) < 600 { return }
        guard !publicIP.isLoading else { return }
        if publicIP.value == nil || force { publicIP = .loading }
        Task {
            if let v = await WiFiTools.publicIP() {
                publicIP = .value(v); publicIPDate = Date()
            } else if publicIP.value == nil {
                publicIP = .failed("Unavailable")
            }
        }
    }

    func publicIPSettingChanged() {
        if WiFiSettings.publicIPEnabled { fetchPublicIP(force: true) } else { publicIP = .idle }
    }

    /// Asks for Location once per launch when the network name is hidden and macOS hasn't asked yet.
    private func checkLocation() {
        locationGranted = Permissions.locationGranted
        guard !locationGranted, !promptedLocation, link.isConnected, link.ssid == nil,
              Permissions.locationCanPrompt else { return }
        promptedLocation = true
        Permissions.request(.location)
    }

    var needsLocationForName: Bool { link.isConnected && link.ssid == nil && !locationGranted }

    // MARK: Scan / join / power

    func scan() {
        guard scanState != .scanning else { return }
        scanState = .scanning
        joinError = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { WiFiTools.scan() }.value
            switch r {
            case .networks(let list): networks = list; scanState = .done
            case .needsLocation: networks = []; scanState = .needsLocation
            case .failed(let m): networks = []; scanState = .failed(m)
            }
        }
    }

    func join(_ network: WiFiNetwork, password: String?) {
        guard joiningID == nil else { return }
        if network.isEnterprise {
            joinError = "\(network.displayName) uses enterprise sign-in. Join it from Wi-Fi settings."
            return
        }
        joiningID = network.id
        joinError = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { WiFiTools.join(network, password: password) }.value
            joiningID = nil
            switch r {
            case .joined:
                passwordTargetID = nil
                tick()
                scan()
            case .needsPassword:
                passwordTargetID = network.id
            case .failed(let m):
                joinError = m
            }
        }
    }

    func setPower(_ on: Bool) {
        actionError = nil
        Task {
            let err = await Task.detached(priority: .userInitiated) { WiFiTools.setPower(on) }.value
            actionError = err
            if !on { networks = []; scanState = .idle; gatewayPing = nil; internetPing = nil; publicIP = .idle }
            tick()
        }
    }

    // MARK: Helpers

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openWiFiSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(u) }
    }

    static func openControlCenterSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    static func openDiagnostics() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Wireless Diagnostics.app"))
    }
}

// MARK: - View presence

private struct WiFiPresence: ViewModifier {
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !counted else { return }
                counted = true
                WiFiModel.shared.uiAppeared()
            }
            .onDisappear {
                guard counted else { return }
                counted = false
                WiFiModel.shared.uiDisappeared()
            }
    }
}

extension View {
    /// Marks a Wi-Fi surface as visible: faster link polling and a one-shot load of IP/latency details.
    func wifiPresence() -> some View { modifier(WiFiPresence()) }
}
