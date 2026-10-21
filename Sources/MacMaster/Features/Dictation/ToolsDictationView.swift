import SwiftUI
import Speech

struct ToolsDictationView: View {
    private let engine = DictationEngine.shared

    @AppStorage(DictationKeys.mode) private var mode = "hold"
    @AppStorage(DictationKeys.locale) private var localeID = ""
    @AppStorage(DictationKeys.punctuation) private var punctuation = true
    @AppStorage(DictationKeys.trailingSpace) private var trailingSpace = true
    @AppStorage(DictationKeys.copyOnly) private var copyOnly = false
    @AppStorage(DictationKeys.voiceCommands) private var voiceCommands = true
    @AppStorage(DictationKeys.onDeviceOnly) private var onDeviceOnly = true
    @AppStorage(DictationKeys.showHUD) private var showHUD = true

    @State private var onDevice: Bool?
    @State private var resolvedName = ""
    @State private var hotKeySet = false
    @State private var tryText = ""
    @State private var copiedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                heroCard
                if engine.isEnabled {
                    PermissionBanner(permission: .microphone, reason: "Dictation listens only while you hold the shortcut. Audio is processed on your Mac and never saved.")
                    PermissionBanner(permission: .speechRecognition, reason: "Turns what you say into text. MacMaster asks macOS to do this on your Mac where your language supports it.")
                    if !copyOnly {
                        PermissionBanner(permission: .accessibility, reason: "Needed to paste the text into the app you are typing in. Without it, text is only copied.")
                    }
                    if let e = engine.lastError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).card()
                    }
                }
                shortcutSection
                languageSection
                textSection
                trySection
                historySection
                Text("Audio is processed on your Mac and never saved. The microphone is open only while you hold the shortcut. Transcripts below stay in memory and disappear when you quit MacMaster.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(Theme.pagePadding)
        }
        .onAppear { refreshLocale(); hotKeySet = engine.hasHotKey }
        .onChange(of: localeID) { _, _ in refreshLocale() }
    }

    private func refreshLocale() {
        let loc = DictationLanguages.resolve(localeID)
        resolvedName = Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier
        onDevice = SFSpeechRecognizer(locale: loc)?.supportsOnDeviceRecognition
    }

    // MARK: Hero

    private var statusText: String {
        guard engine.isEnabled else { return "Off" }
        switch engine.phase {
        case .starting, .listening: return "Listening…"
        case .finishing: return "Transcribing…"
        case .idle:
            if !hotKeySet { return "Record a shortcut to start" }
            return mode == "toggle" ? "Ready • press your shortcut" : "Ready • hold your shortcut"
        }
    }

    private var statusColor: Color {
        guard engine.isEnabled else { return .gray }
        if engine.phase != .idle { return .red }
        return hotKeySet ? .green : .orange
    }

    private var heroCard: some View {
        HStack(spacing: 16) {
            IconTile(symbol: ToolsTool.dictation.symbol, colors: ToolsTool.dictation.colors, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dictation").font(.title2.weight(.semibold))
                StatusPill(text: statusText, color: statusColor)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { engine.isEnabled }, set: { engine.setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.large)
        }
        .card()
    }

    // MARK: Settings

    private var shortcutSection: some View {
        GroupedSection("Shortcut", symbol: "keyboard",
                       footer: "Pick a combination other apps don't use, such as ⌥Space or ⌃⌥D.") {
            SettingsRow(title: "Dictation shortcut", subtitle: "Click, then press the keys you want.") {
                HotKeyField(defaultsKey: DictationKeys.hotkey) { combo in
                    hotKeySet = combo != nil
                    engine.registerHotKey()
                }
            }
            SettingsRow(title: "How it works") {
                Picker("", selection: $mode) {
                    Text("Hold to talk").tag("hold")
                    Text("Press to start and stop").tag("toggle")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }
        }
    }

    private var languageSection: some View {
        GroupedSection("Language", symbol: "globe",
                       footer: footerForLanguage) {
            SettingsRow(title: "Spoken language", subtitle: onDeviceText) {
                Picker("", selection: $localeID) {
                    Text("Same as this Mac (\(Locale.current.localizedString(forIdentifier: DictationLanguages.resolve("").identifier) ?? "English"))").tag("")
                    Divider()
                    ForEach(DictationLanguages.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 260)
            }
            SettingsRow(title: "Only recognize on this Mac", subtitle: "Never send audio to Apple, even when it would be more accurate.") {
                Toggle("", isOn: $onDeviceOnly).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var onDeviceText: String? {
        switch onDevice {
        case true: "\(resolvedName) runs fully on this Mac."
        case false: onDeviceOnly ? "\(resolvedName) can't run on this Mac, so it won't work while \"Only recognize on this Mac\" is on."
                                 : "\(resolvedName) needs an internet connection and Apple's servers."
        default: nil
        }
    }

    private var footerForLanguage: String? {
        onDevice == false ? "If a language is missing on-device support, turn off the switch below to use Apple's online recognition for it." : nil
    }

    private var textSection: some View {
        GroupedSection("Text", symbol: "text.cursor",
                       footer: "Voice commands: say \"new line\" or \"new paragraph\". With automatic punctuation off, also \"period\", \"comma\", \"question mark\", \"exclamation mark\", \"colon\" and \"semicolon\".") {
            SettingsRow(title: "Automatic punctuation", subtitle: "Adds commas and full stops for you.") {
                Toggle("", isOn: $punctuation).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Voice commands", subtitle: "\"New line\", \"new paragraph\", spoken punctuation.") {
                Toggle("", isOn: $voiceCommands).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Add a space after the text") {
                Toggle("", isOn: $trailingSpace).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Copy only, don't paste", subtitle: "Puts the text on the clipboard instead of typing it. No Accessibility needed.") {
                Toggle("", isOn: $copyOnly).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Show the floating bar", subtitle: "Level meter and live text near the bottom of the screen.") {
                Toggle("", isOn: $showHUD).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Try it

    private var trySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Try it", symbol: "pencil.line")
            TextField("Click here, then use your shortcut and speak", text: $tryText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            Text("This is a test field inside MacMaster. In other apps the text goes wherever your cursor is.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Recent", symbol: "clock.arrow.circlepath")
                Spacer()
                if !engine.history.isEmpty {
                    Button("Clear") { engine.clearHistory() }.buttonStyle(.mmGhost)
                }
            }
            if engine.history.isEmpty {
                Text("What you dictate shows up here, newest first. The last 20 are kept until you quit MacMaster.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.history) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).font(.callout).lineLimit(4).textSelection(.enabled)
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button {
                                engine.copy(entry)
                                copiedID = entry.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == entry.id { copiedID = nil } }
                            } label: {
                                Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                                    .frame(width: 20)
                            }
                            .buttonStyle(.mmGhost).help("Copy")
                        }
                        .padding(.vertical, 8)
                        if entry.id != engine.history.last?.id { HairlineDivider() }
                    }
                }
            }
        }
        .card()
    }
}
