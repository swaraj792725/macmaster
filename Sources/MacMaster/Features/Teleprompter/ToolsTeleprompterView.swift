import SwiftUI
import AppKit

/// Teleprompter tool: script, speed and look, overlay mode, voice pacing. The overlay itself lives in its own panel.
struct ToolsTeleprompterView: View {
    private let engine = TeleprompterEngine.shared
    private var tint: Color { Theme.Palette.purple[1] }

    var body: some View {
        @Bindable var e = engine
        Page {
            scriptCard(e: e)
            playbackCard(e: e)
            overlayCard(e: e)
            voiceCard(e: e)
            controlsCard
        }
        .onAppear { engine.ensureScriptLoaded() }
        .onDisappear { engine.flushScript() }
    }

    // MARK: Script

    private func scriptCard(e: TeleprompterEngine) -> some View {
        @Bindable var e = e
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Script", symbol: "text.alignleft")
                Spacer()
                if e.overlayOpen {
                    StatusPill(text: statusText(e), color: .green)
                    Button(e.state == .playing ? "Pause" : "Resume") { e.togglePlayPause() }.buttonStyle(.mmSecondary)
                    Button("Stop") { e.stop() }.buttonStyle(.mmPrimary(tint: .red))
                } else {
                    Button { e.begin() } label: { Label("Start prompter", systemImage: "play.fill") }
                        .buttonStyle(.mmPrimary(tint: tint))
                }
            }
            TextEditor(text: $e.script)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if e.script.isEmpty {
                        Text("Paste or type your script here. Each paragraph becomes lines in the prompter.")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                Button { e.chooseImport() } label: { Label("Import .txt / .md…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.mmSecondary)
                if !e.script.isEmpty {
                    Button("Clear") { e.script = "" }.buttonStyle(.mmGhost)
                }
                Spacer()
                Text("\(e.wordCount) words · about \(duration(e.estimatedSeconds)) at \(Int(e.wpm)) wpm")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let m = e.message {
                Text(m).font(.caption).foregroundStyle(.red)
            }
        }
        .card()
        .searchAnchor("teleprompter.script")
    }

    private func statusText(_ e: TeleprompterEngine) -> String {
        switch e.state {
        case .idle: "Ready"
        case .countdown: "Starting"
        case .playing: "Playing"
        case .paused: e.atEnd ? "Finished" : "Paused"
        }
    }

    private func duration(_ s: Int) -> String {
        s < 60 ? "\(s) sec" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) sec")
    }

    // MARK: Playback and look

    private func playbackCard(e: TeleprompterEngine) -> some View {
        @Bindable var e = e
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Speed and text", symbol: "slider.horizontal.3")
            slider("Speed", value: $e.wpm, range: 40...400, step: 5, unit: "wpm")
            slider("Font size", value: $e.fontSize, range: 20...96, step: 1, unit: "pt")
            slider("Text width", value: $e.textWidth, range: 320...1100, step: 10, unit: "pt")
            slider("Background opacity", value: $e.opacity, range: 0.3...1, step: 0.02, unit: "%", scale: 100)
            Divider()
            Toggle("Highlight the line being read", isOn: $e.highlight).toggleStyle(.switch)
            Toggle("3-2-1 countdown before scrolling", isOn: $e.countdownEnabled).toggleStyle(.switch)
            Toggle("Mirror text (for a glass teleprompter)", isOn: $e.mirror).toggleStyle(.switch)
        }
        .card()
        .searchAnchor("teleprompter.playback")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, scale: Double = 1) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text("\(Int((value.wrappedValue * scale).rounded())) \(unit)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: Overlay

    private func overlayCard(e: TeleprompterEngine) -> some View {
        @Bindable var e = e
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Overlay", symbol: "rectangle.topthird.inset.filled")
            Picker("", selection: $e.mode) {
                ForEach(TeleprompterMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            if e.mode == .notch {
                Text("A black bar pinned under the camera at the top of your screen, so you look at the lens while reading.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Bar height", value: $e.notchHeight, range: 100...420, step: 5, unit: "pt")
            } else {
                Text("A window you can drag and resize. Place it next to the camera or anywhere on screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Play / pause shortcut").font(.callout)
                HotKeyField(defaultsKey: TPPrefs.hotkey) { _ in e.registerHotKey() }
            }
            Text("The overlay is hidden from screen sharing and recordings where macOS allows it, stays above other windows, and doesn't take focus from the app you're presenting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
        .searchAnchor("teleprompter.overlay")
    }

    // MARK: Voice

    private func voiceCard(e: TeleprompterEngine) -> some View {
        @Bindable var e = e
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Voice pacing", symbol: "waveform")
            Toggle("Scroll while I'm speaking, pause when I stop", isOn: Binding(
                get: { e.voicePacing }, set: { e.setVoicePacing($0) }))
                .toggleStyle(.switch)
            Text("Uses the microphone level only while the prompter is open. Nothing is recorded or sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            if e.voicePacing {
                slider("Sensitivity", value: Binding(get: { -e.voiceThreshold }, set: { e.voiceThreshold = -$0 }),
                       range: 20...60, step: 1, unit: "dB")
                Text("A higher number picks up quieter speech. Raise it if scrolling stops between words, lower it if room noise moves the text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if e.micDenied {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                    Text("Microphone access is off for MacMaster.").font(.callout)
                    Spacer()
                    Button("Open Settings") { NSWorkspace.shared.open(Permission.microphone.settingsURL) }
                        .buttonStyle(.mmSecondary)
                }
            }
        }
        .card()
        .searchAnchor("teleprompter.voice")
    }

    // MARK: Help

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Controls", symbol: "keyboard")
            ForEach(Self.controls, id: \.0) { key, text in
                HStack(spacing: 10) {
                    Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: 90, alignment: .leading)
                    Text(text).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            Text("Keys work after you click the prompter. Use the global shortcut to start and pause without clicking. Hover over the prompter for a mini control strip.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private static let controls: [(String, String)] = [
        ("Space", "Play or pause"),
        ("Up / Down", "Faster or slower"),
        ("Left / Right", "Jump back or forward one line"),
        ("Esc", "Stop and close the prompter"),
    ]
}
