import SwiftUI
import AVFoundation

/// Live camera picture (only used while the tool view is open and the user asked for it).
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class Host: NSView {
        let layerView = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layerView.videoGravity = .resizeAspectFill
            layer?.addSublayer(layerView)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layerView.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let h = Host()
        h.layerView.session = session
        return h
    }

    func updateNSView(_ nsView: Host, context: Context) {
        if nsView.layerView.session !== session { nsView.layerView.session = session }
    }

    static func dismantleNSView(_ nsView: Host, coordinator: ()) {
        nsView.layerView.session = nil
    }
}

struct ToolsPrivacyGuardView: View {
    private let engine = PrivacyGuardEngine.shared
    private let watcher = PermissionWatcher.shared

    @AppStorage(PrivacyGuardKeys.walkAway) private var walkAway = true
    @AppStorage(PrivacyGuardKeys.walkAwayDelay) private var walkAwayDelay = 5.0
    @AppStorage(PrivacyGuardKeys.lockEnabled) private var lockEnabled = false
    @AppStorage(PrivacyGuardKeys.lockDelay) private var lockDelay = 60.0
    @AppStorage(PrivacyGuardKeys.shoulder) private var shoulder = true
    @AppStorage(PrivacyGuardKeys.shoulderNotify) private var shoulderNotify = true
    @AppStorage(PrivacyGuardKeys.lookAway) private var lookAway = false
    @AppStorage(PrivacyGuardKeys.lookAwayDelay) private var lookAwayDelay = 3.0
    @AppStorage(PrivacyGuardKeys.lookAwayAngle) private var lookAwayAngle = 40.0
    @AppStorage(PrivacyGuardKeys.menuBar) private var menuBar = true
    @State private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                heroCard
                if engine.cameraDenied || (engine.isOn && !watcher.isGranted(.camera)) {
                    PermissionBanner(permission: .camera,
                                     reason: "Privacy Guard needs the camera to see whether you are at your Mac. Frames are processed on your Mac and never saved.")
                }
                if let p = engine.problem, engine.isOn {
                    Label(p, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .card()
                }
                triggers
                controls
                previewCard
                Text("Frames are processed on your Mac and never saved. The camera only runs while Privacy Guard is on, and it turns off when the screen locks or the Mac sleeps.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(Theme.pagePadding)
        }
        .onDisappear { showPreview = false }
    }

    // MARK: Hero

    private var statusText: String {
        if !engine.isOn { return "Off" }
        if engine.isPaused { return "Paused" }
        if engine.isSuspended { return "Waiting for the screen to wake" }
        if engine.blurReason != nil { return "Screen covered" }
        guard engine.cameraLive, let n = engine.faceCount else { return "Starting the camera…" }
        return n == 1 ? "Watching • 1 face" : "Watching • \(n) faces"
    }

    private var statusColor: Color {
        if !engine.isOn { return .gray }
        if engine.isPaused || engine.isSuspended { return .orange }
        if engine.blurReason != nil { return .red }
        return .green
    }

    private var heroCard: some View {
        HStack(spacing: 16) {
            IconTile(symbol: ToolsTool.privacyGuard.symbol, colors: ToolsTool.privacyGuard.colors, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy Guard").font(.title2.weight(.semibold))
                StatusPill(text: statusText, color: statusColor)
            }
            Spacer(minLength: 12)
            if engine.isOn {
                Button(engine.isPaused ? "Resume" : "Pause") { engine.setPaused(!engine.isPaused) }
                    .buttonStyle(.mmSecondary)
            }
            Toggle("", isOn: Binding(get: { engine.isOn }, set: { engine.setOn($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.large)
        }
        .card()
    }

    // MARK: Triggers

    private var triggers: some View {
        GroupedSection("Cover the screen when…", symbol: "eye.slash",
                       footer: "Press Esc or the button on the cover to see your screen for a minute. The cover lifts by itself once things look normal again.") {
            SettingsRow(title: "You walk away", subtitle: "No face for a few seconds", symbol: "figure.walk", colors: Theme.Palette.blue) {
                Toggle("", isOn: $walkAway).labelsHidden().toggleStyle(.switch)
            }
            if walkAway {
                sliderRow("Wait", value: $walkAwayDelay, range: 2...30, unit: "s")
                SettingsRow(title: "Lock the Mac as well", subtitle: "If you stay away. Uses the lock screen; if that is unavailable it turns the display off, which locks when macOS asks for a password right away.") {
                    Toggle("", isOn: $lockEnabled).labelsHidden().toggleStyle(.switch)
                }
                if lockEnabled {
                    sliderRow("Lock after", value: $lockDelay, range: 10...600, step: 5, unit: "s")
                }
            }
            SettingsRow(title: "Someone looks over your shoulder", subtitle: "Two or more faces at once", symbol: "person.2.fill", colors: Theme.Palette.orange) {
                Toggle("", isOn: $shoulder).labelsHidden().toggleStyle(.switch)
            }
            if shoulder {
                SettingsRow(title: "Send a notification") {
                    Toggle("", isOn: $shoulderNotify).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsRow(title: "You look away", subtitle: "Your head turns away from the screen", symbol: "eye.trianglebadge.exclamationmark", colors: Theme.Palette.purple) {
                Toggle("", isOn: $lookAway).labelsHidden().toggleStyle(.switch)
            }
            if lookAway {
                sliderRow("Wait", value: $lookAwayDelay, range: 1...15, unit: "s")
                sliderRow("Head turn", value: $lookAwayAngle, range: 20...70, step: 5, unit: "°")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, unit: String) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: value.snapped(step), in: range).frame(width: 180)
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        GroupedSection("Controls", symbol: "slider.horizontal.3") {
            SettingsRow(title: "Pause shortcut", subtitle: "Pauses or resumes the guard, or turns it on if it is off.") {
                HotKeyField(defaultsKey: PrivacyGuardKeys.hotkey) { _ in engine.registerHotKey() }
            }
            SettingsRow(title: "Show in the menu bar", subtitle: "An eye icon with Pause and Stop while the guard is on.") {
                Toggle("", isOn: $menuBar).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Camera preview", symbol: "video.fill")
                Spacer()
                Toggle("", isOn: $showPreview).labelsHidden().toggleStyle(.switch)
                    .disabled(!engine.cameraLive)
            }
            if showPreview, engine.cameraLive {
                CameraPreview(session: engine.previewSession)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            } else {
                Text(engine.cameraLive ? "Shows what the camera sees, only while this page is open. Off by default."
                                       : "Turn Privacy Guard on to see a live preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}
