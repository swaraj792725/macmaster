import SwiftUI
import CoreAudio

/// Sound page: output and input devices, priority and automation, mic mute, menu bar.
struct SoundView: View {
    @State private var engine = SoundEngine.shared

    var body: some View {
        Page(jump: [PageJump("sound.output", "Output"), PageJump("sound.input", "Input"),
                    PageJump("sound.priority", "Priority"), PageJump("sound.safety", "Safety"),
                    PageJump("sound.micmute", "Mic mute"), PageJump("sound.menubar", "Menu bar")]) {
            PageHeader(title: AppSection.sound.title, subtitle: AppSection.sound.blurb,
                       symbol: AppSection.sound.symbol, colors: AppSection.sound.colors) {
                if engine.micMuted {
                    Button { engine.setMicMuted(false) } label: { Label("Unmute mic", systemImage: "mic.slash.fill") }
                        .buttonStyle(.mmPrimary(tint: .red))
                } else {
                    Button { engine.setMicMuted(true) } label: { Label("Mute mic", systemImage: "mic.fill") }
                        .buttonStyle(.mmSecondary)
                }
            }
            SoundBanners()
            if !engine.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                SoundOutputSection().searchAnchor("sound.output")
                SoundInputSection().searchAnchor("sound.input")
                SoundPrioritySection().searchAnchor("sound.priority")
                SoundSafetySection().searchAnchor("sound.safety")
                SoundMicMuteSection().searchAnchor("sound.micmute")
                SoundMenuBarSection().searchAnchor("sound.menubar")
            }
        }
        .onAppear { engine.setObserving("page", true) }
        .onDisappear {
            engine.setObserving("page", false)
            SoundLevelMeter.shared.stop()
        }
    }
}

// MARK: - Banners

private struct SoundBanners: View {
    @State private var engine = SoundEngine.shared
    var body: some View {
        VStack(spacing: 8) {
            if let t = engine.errorText {
                banner(t, symbol: "exclamationmark.triangle.fill", color: .orange) { engine.errorText = nil }
            }
            if let t = engine.notice {
                banner(t, symbol: "info.circle.fill", color: .blue) { engine.notice = nil }
            }
        }
        .animation(.smooth(duration: 0.25), value: engine.errorText)
        .animation(.smooth(duration: 0.25), value: engine.notice)
    }

    private func banner(_ text: String, symbol: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Output

private struct SoundOutputSection: View {
    @State private var engine = SoundEngine.shared

    var body: some View {
        let outputs = engine.outputs
        GroupedSection("Output", symbol: "speaker.wave.2.fill",
                       footer: "Click a device to make it the sound output. Volume and sample rate apply to the selected device.") {
            if outputs.isEmpty {
                SettingsRow(title: "No output devices", subtitle: "Connect speakers or headphones.", symbol: "speaker.slash.fill")
            }
            ForEach(outputs) { d in
                SoundDeviceRow(device: d, scope: .output, selected: d.id == engine.defaultOutputID) {
                    withAnimation(.snappy(duration: 0.2)) { engine.selectOutput(d) }
                }
            }
            if let cur = engine.defaultOutput {
                SoundOutputVolumeRow(device: cur)
                if cur.rates.count > 1 {
                    SoundRateRow(device: cur).searchAnchor("sound.samplerate")
                }
                if outputs.count > 1 {
                    SoundSystemOutputRow().searchAnchor("sound.alert")
                }
            }
        }
    }
}

struct SoundRateRow: View {
    let device: SoundDevice
    @State private var engine = SoundEngine.shared

    var body: some View {
        var rates = device.rates
        if device.rate > 0, !rates.contains(device.rate) { rates.append(device.rate); rates.sort() }
        return SettingsRow(title: "Sample rate", subtitle: "Higher rates use more bandwidth. Most apps follow this setting.",
                           symbol: "waveform", colors: Theme.Palette.indigo) {
            Picker("", selection: Binding(get: { device.rate }, set: { engine.setRate(device, $0) })) {
                ForEach(rates, id: \.self) { Text(SoundFormat.rate($0)).tag($0) }
            }
            .labelsHidden().frame(width: 120)
        }
    }
}

private struct SoundSystemOutputRow: View {
    @State private var engine = SoundEngine.shared
    var body: some View {
        SettingsRow(title: "Alerts and system sounds", subtitle: "Where alert sounds, notifications and Siri play.",
                    symbol: "bell.fill", colors: Theme.Palette.orange) {
            Picker("", selection: Binding(get: { engine.defaultSystemOutputID },
                                          set: { id in if let d = engine.outputs.first(where: { $0.id == id }) { engine.selectSystemOutput(d) } })) {
                ForEach(engine.outputs) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden().frame(width: 200)
        }
    }
}

// MARK: - Input

private struct SoundInputSection: View {
    @State private var engine = SoundEngine.shared
    @State private var meter = SoundLevelMeter.shared
    @State private var meterOn = false
    @State private var permission = PermissionWatcher.shared

    var body: some View {
        let inputs = engine.inputs
        GroupedSection("Input", symbol: "mic.fill",
                       footer: "The level meter listens to the selected microphone only while it is on and this page is open.") {
            if inputs.isEmpty {
                SettingsRow(title: "No input devices", subtitle: "Connect a microphone.", symbol: "mic.slash.fill")
            }
            ForEach(inputs) { d in
                SoundDeviceRow(device: d, scope: .input, selected: d.id == engine.defaultInputID) {
                    withAnimation(.snappy(duration: 0.2)) { engine.selectInput(d) }
                }
            }
            if let cur = engine.defaultInput {
                gainRow(cur)
                if cur.rates.count > 1 { SoundRateRow(device: cur) }
                meterRow(cur)
                if meterOn {
                    if permission.isGranted(.microphone) {
                        meterBar(cur)
                    } else {
                        grantRow
                    }
                }
            }
        }
        .onChange(of: meterOn) { _, on in
            if on, Permissions.isGranted(.microphone) { meter.start() } else { meter.stop() }
        }
    }

    private func gainRow(_ d: SoundDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill").font(.system(size: 14, weight: .medium)).frame(width: 22)
                .foregroundStyle(.secondary)
            if d.inVolume != nil, d.inVolumeSettable {
                Slider(value: Binding(get: { Double(d.inVolume ?? 0) }, set: { engine.setInputVolume(d, Float($0)) }), in: 0...1)
                    .accessibilityLabel("Input gain")
                Text("\(Int(((d.inVolume ?? 0) * 100).rounded()))%")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            } else {
                Text("This microphone has no gain control.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func meterRow(_ d: SoundDevice) -> some View {
        SettingsRow(title: "Level meter", subtitle: d.transport == .bluetooth
                    ? "A Bluetooth mic lowers headphone sound quality while metering."
                    : "Show a live level for the selected microphone.",
                    symbol: "waveform.badge.mic", colors: Theme.Palette.green) {
            Toggle("", isOn: $meterOn).labelsHidden().toggleStyle(.switch)
        }
        .searchAnchor("sound.meter")
    }

    private func meterBar(_ d: SoundDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SoundMeterBar(level: meter.level, peak: meter.peak)
            switch meter.state {
            case .noInput: Text("No microphone input is available.").font(.caption).foregroundStyle(.secondary)
            case .failed: Text("Couldn't start the meter. Try another microphone.").font(.caption).foregroundStyle(.orange)
            default:
                if engine.micMuted { Text("Mic is muted, so the meter stays quiet.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var grantRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "lock.fill", colors: Theme.Palette.orange, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Microphone access needed").font(.body)
                Text("Allow MacMaster to use the microphone to show levels. Audio is never recorded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Grant access") {
                Permissions.requestMedia(.microphone) { granted in
                    if granted, meterOn { meter.start() }
                }
            }
            .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF8A00)))
        }
    }
}

// MARK: - Priority

private struct SoundPrioritySection: View {
    @AppStorage(SoundSettings.autoSwitchKey) private var autoSwitch = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            GroupedSection("Device priority", symbol: "list.number",
                           footer: "When a device connects or disconnects, MacMaster switches to the highest one in the lists below that is available. Your own choices are never overridden in between.") {
                SoundToggleRow("Switch automatically", subtitle: "Follow the priority lists when devices come and go.",
                               symbol: "arrow.triangle.swap", colors: Theme.Palette.pink,
                               key: SoundSettings.autoSwitchKey, defaultValue: false)
                SoundToggleRow("Never auto-select Bluetooth for input",
                               subtitle: "Keeps AirPods on high-quality sound instead of the low-quality call mode.",
                               symbol: "airpods", colors: Theme.Palette.blue,
                               key: SoundSettings.neverBTInputKey, defaultValue: true, disabled: !autoSwitch)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.spacing) {
                    SoundPriorityList(scope: .output)
                    SoundPriorityList(scope: .input)
                }
                .frame(minWidth: 640)
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    SoundPriorityList(scope: .output)
                    SoundPriorityList(scope: .input)
                }
            }
        }
    }
}

private struct SoundPriorityList: View {
    let scope: SoundScope
    @State private var engine = SoundEngine.shared
    @State private var targeted: String?
    @AppStorage(SoundSettings.neverBTInputKey) private var neverBT = true
    @AppStorage(SoundSettings.autoSwitchKey) private var autoSwitch = false

    var body: some View {
        let entries = engine.priorityEntries(scope)
        GroupedSection(scope == .output ? "Output priority" : "Input priority",
                       symbol: scope == .output ? "speaker.wave.2" : "mic",
                       footer: entries.count > 1 ? "Drag to reorder. Top is preferred. Disconnected devices stay listed." : nil) {
            if entries.isEmpty {
                SettingsRow(title: "No devices yet", subtitle: "Devices appear here once seen.")
            }
            ForEach(Array(entries.enumerated()), id: \.element.uid) { index, e in
                row(e, index: index, count: entries.count)
            }
        }
    }

    private func row(_ e: SoundPriorityEntry, index: Int, count: Int) -> some View {
        let skipped = scope == .input && autoSwitch && neverBT && e.transport == .bluetooth
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
            IconTile(symbol: e.symbol, colors: e.connected ? Theme.Palette.pink : Theme.Palette.gray, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.callout).lineLimit(1)
                if !e.connected {
                    Text("Not connected").font(.caption).foregroundStyle(.secondary)
                } else if skipped {
                    Text("Not auto-selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
        }
        .opacity(e.connected ? 1 : 0.5)
        .padding(.vertical, 1)
        .background(targeted == e.uid ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .draggable(e.uid)
        .dropDestination(for: String.self) { items, _ in
            guard let u = items.first else { return false }
            withAnimation(.snappy(duration: 0.2)) { engine.movePriority(scope, uid: u, to: e.uid) }
            return true
        } isTargeted: { t in
            if t { targeted = e.uid } else if targeted == e.uid { targeted = nil }
        }
        .contextMenu {
            Button("Move up") { withAnimation { engine.nudgePriority(scope, uid: e.uid, by: -1) } }.disabled(index == 0)
            Button("Move down") { withAnimation { engine.nudgePriority(scope, uid: e.uid, by: 1) } }.disabled(index == count - 1)
            if !e.connected {
                Divider()
                Button("Forget device", role: .destructive) { engine.forget(scope, uid: e.uid) }
            }
        }
        .accessibilityLabel("\(index + 1). \(e.name)\(e.connected ? "" : ", not connected")")
        .accessibilityAction(named: "Move up") { engine.nudgePriority(scope, uid: e.uid, by: -1) }
        .accessibilityAction(named: "Move down") { engine.nudgePriority(scope, uid: e.uid, by: 1) }
    }
}

// MARK: - Safety (unplug protection, volume memory)

private struct SoundSafetySection: View {
    @AppStorage(SoundSettings.unplugProtectKey) private var protect = true
    @AppStorage(SoundSettings.unplugActionKey) private var action = "mute"
    @AppStorage(SoundSettings.unplugVolumeKey) private var percent = 25

    var body: some View {
        GroupedSection("Output safety", symbol: "shield.lefthalf.filled",
                       footer: "Applies when headphones are unplugged or Bluetooth drops and sound falls back to the Mac's speakers. Switching manually never triggers it.") {
            SoundToggleRow("Protect against sudden speaker audio",
                           subtitle: "Quiet the speakers when headphones or Bluetooth disappear.",
                           symbol: "headphones", colors: Theme.Palette.orange,
                           key: SoundSettings.unplugProtectKey, defaultValue: true)
            if protect {
                SettingsRow(title: "When it happens", symbol: "slider.horizontal.3", colors: Theme.Palette.gray) {
                    Picker("", selection: $action) {
                        Text("Mute").tag("mute")
                        Text("Set volume").tag("volume")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                if action == "volume" {
                    SettingsRow(title: "Speaker volume", symbol: "speaker.wave.1.fill", colors: Theme.Palette.gray) {
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { Double(percent) }, set: { percent = Int($0.rounded()) }), in: 0...80)
                                .frame(width: 160)
                            Text("\(percent)%").font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            SoundToggleRow("Remember volume per device",
                           subtitle: "Restore each output's last volume when it becomes the active device.",
                           symbol: "memorychip", colors: Theme.Palette.teal,
                           key: SoundSettings.rememberVolumeKey, defaultValue: false)
                .searchAnchor("sound.volumememory")
        }
    }
}

// MARK: - Mic mute

private struct SoundMicMuteSection: View {
    @State private var engine = SoundEngine.shared

    var body: some View {
        GroupedSection("Mic mute", symbol: "mic.slash.fill",
                       footer: "Mutes by setting the microphone's input volume to zero (or its mute switch) and restores it when you unmute. If you switch microphones while muted, the new one is muted too.") {
            SettingsRow(title: "Microphone muted", subtitle: engine.micMuted ? "No app can hear you right now." : "Turn on to silence the default input.",
                        symbol: engine.micMuted ? "mic.slash.fill" : "mic.fill",
                        colors: engine.micMuted ? Theme.Palette.red : Theme.Palette.gray) {
                Toggle("", isOn: Binding(get: { engine.micMuted }, set: { engine.setMicMuted($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if let p = engine.micMuteProblem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(p).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsRow(title: "Shortcut", subtitle: "Works from any app. Click to record, Delete to clear.",
                        symbol: "keyboard", colors: Theme.Palette.indigo) {
                HotKeyField(defaultsKey: SoundSettings.hotKeyKey) { _ in engine.registerHotKey() }
            }
            .searchAnchor("sound.hotkey")
            SoundToggleRow("Show a floating indicator while muted",
                           subtitle: "A small red pill at the top of the screen.",
                           symbol: "mic.slash", colors: Theme.Palette.red,
                           key: SoundSettings.mutedIndicatorKey, defaultValue: true)
        }
    }
}

// MARK: - Menu bar

private struct SoundMenuBarSection: View {
    var body: some View {
        GroupedSection("Menu bar", symbol: "menubar.rectangle",
                       footer: "A volume icon with a popover for switching devices and muting the mic. It turns red while the mic is muted.") {
            SoundToggleRow("Show Sound in menu bar", symbol: "speaker.wave.2.fill", colors: Theme.Palette.pink,
                           key: SoundSettings.menuBarKey, defaultValue: false)
        }
    }
}

// MARK: - Search

extension AppSearchIndex {
    /// Sound settings, added to the global search.
    static let soundEntries: [SearchEntry] = [
        SearchEntry(.sound, crumb: "Output", "Output device", "speaker headphones airpods switch default audio output", anchor: "sound.output"),
        SearchEntry(.sound, crumb: "Output", "Output volume and mute", "volume slider mute speaker loudness", anchor: "sound.output"),
        SearchEntry(.sound, crumb: "Output", "Sample rate", "khz hertz hz format quality 44.1 48 96 192", anchor: "sound.samplerate"),
        SearchEntry(.sound, crumb: "Output", "Alerts and system sounds device", "alert sound effects notification siri system output", anchor: "sound.alert"),
        SearchEntry(.sound, crumb: "Input", "Input device", "microphone mic switch default input", anchor: "sound.input"),
        SearchEntry(.sound, crumb: "Input", "Input gain", "microphone volume level gain", anchor: "sound.input"),
        SearchEntry(.sound, crumb: "Input", "Input level meter", "mic level meter vu test microphone", anchor: "sound.meter"),
        SearchEntry(.sound, crumb: "Priority", "Device priority", "order reorder drag preferred prefer list", anchor: "sound.priority"),
        SearchEntry(.sound, crumb: "Priority", "Switch devices automatically", "auto switch connect disconnect bluetooth usb priority", anchor: "sound.priority"),
        SearchEntry(.sound, crumb: "Priority", "Never auto-select Bluetooth for input", "airpods bluetooth microphone call mode quality", anchor: "sound.priority"),
        SearchEntry(.sound, crumb: "Safety", "Protect against sudden speaker audio", "unplug headphones disconnect mute speakers loud embarrassing", anchor: "sound.safety"),
        SearchEntry(.sound, crumb: "Safety", "Remember volume per device", "restore volume device memory", anchor: "sound.volumememory"),
        SearchEntry(.sound, crumb: "Mic mute", "Mute microphone", "mic mute unmute silence meeting call", anchor: "sound.micmute"),
        SearchEntry(.sound, crumb: "Mic mute", "Mic mute shortcut", "hotkey global shortcut keyboard push mute", anchor: "sound.hotkey"),
        SearchEntry(.sound, crumb: "Mic mute", "Muted indicator", "floating pill red overlay mic muted", anchor: "sound.micmute"),
        SearchEntry(.sound, crumb: "Menu bar", "Sound in menu bar", "status item popover volume device switcher", anchor: "sound.menubar"),
    ]
}
