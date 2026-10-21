import SwiftUI

struct CommandBarView: View {
    @AppStorage(CommandBarPrefs.enabledKey) private var enabled = false
    @AppStorage(CommandBarPrefs.webEngineKey) private var engineRaw = CBWebEngine.google.rawValue
    @State private var engine = CommandBarEngine.shared
    @State private var tracked = CommandBarUsage.shared.trackedCount
    @State private var confirmReset = false

    var body: some View {
        Page {
            PageHeader(title: AppSection.commandbar.title, subtitle: AppSection.commandbar.blurb,
                       symbol: AppSection.commandbar.symbol, colors: AppSection.commandbar.colors)
            enableCard.searchAnchor("commandbar.enable")
            CBPreviewCard().searchAnchor("commandbar.preview")
            providersCard.searchAnchor("commandbar.providers")
            rankingCard.searchAnchor("commandbar.ranking")
            tipsCard.searchAnchor("commandbar.tips")
        }
        .onChange(of: enabled) { _, on in engine.setEnabled(on) }
        .onAppear { tracked = CommandBarUsage.shared.trackedCount }
    }

    // MARK: Enable + hotkey

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable Command Bar").font(.system(size: 17, weight: .semibold))
                    Text("Press one shortcut anywhere to launch apps, run actions, jump to settings or do quick math.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut").font(.callout.weight(.medium))
                    Text("Click the field, then press the keys you want.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HotKeyField(defaultsKey: CommandBarPrefs.hotKeyKey, onChange: { _ in engine.hotKeyChanged() })
                    .frame(width: 160)
                statusPill
            }
            .searchAnchor("commandbar.hotkey")
            HStack {
                if enabled, engine.hotKeyState == .conflict {
                    Text("Another app already uses this shortcut. Pick a different one.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Open Now") { engine.openNow() }
                    .buttonStyle(.mmSecondary)
                    .disabled(!enabled)
            }
        }
        .card()
    }

    @ViewBuilder private var statusPill: some View {
        if !enabled {
            StatusPill(text: "Off", color: .gray)
        } else {
            switch engine.hotKeyState {
            case .active: StatusPill(text: "Ready", color: .green)
            case .conflict: StatusPill(text: "In use", color: .orange)
            case .none: StatusPill(text: "No shortcut", color: .orange)
            case .off: StatusPill(text: "Starting", color: .gray)
            }
        }
    }

    // MARK: Providers

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "What it searches", symbol: "checklist")
            ForEach(CBKind.allCases) { kind in
                CBProviderToggle(kind: kind)
                if kind != CBKind.allCases.last { Divider().opacity(0.5) }
            }
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                IconTile(symbol: "globe", colors: Theme.Palette.blue, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Web search engine").font(.callout.weight(.medium))
                    Text("Return searches here. Command-Return uses the other one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: $engineRaw) {
                    ForEach(CBWebEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.vertical, 6)
        }
        .card()
    }

    // MARK: Ranking

    private var rankingCard: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "chart.line.uptrend.xyaxis", colors: Theme.Palette.green, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage ranking").font(.callout.weight(.medium))
                Text(tracked == 0
                     ? "Results you pick float to the top over time. Nothing learned yet."
                     : "Learned from \(tracked) item\(tracked == 1 ? "" : "s") you picked. Stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reset usage ranking") { confirmReset = true }
                .buttonStyle(.mmSecondary)
                .disabled(tracked == 0)
        }
        .card()
        .confirmationDialog("Forget what the Command Bar has learned?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { engine.resetUsage(); tracked = 0 }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Tips

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Tips", symbol: "lightbulb")
            tip("2^10 / 15% of 80 / sqrt(2)", "Math. Return copies the answer.")
            tip("10 km in mi / 72f to c / 5 gb in mb", "Unit conversion. Return copies the answer.")
            tip("clip invoice", "Search your clipboard history. Return copies, Command-Return pastes.")
            tip("snip sig", "Find a snippet. Return inserts it into the app you were using.")
            tip("open apple.com", "Open a web address. Anything else can be searched on the web.")
            tip("wifi settings / bluetooth", "Jump straight to a System Settings pane.")
            tip("Command 1 to 9", "Pick the numbered result without moving the selection.")
            tip("Command Return", "Run the second action: reveal an app in Finder, search with the other engine.")
        }
        .card()
    }

    private func tip(_ example: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(example)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Provider toggle

private struct CBProviderToggle: View {
    let kind: CBKind
    @AppStorage private var on: Bool

    init(kind: CBKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: kind.defaultOn, kind.defaultsKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: kind.symbol, colors: kind.colors, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Live preview

private struct CBPreviewCard: View {
    private static let samples: [CBResult] = [
        CBResult(id: "p1", kind: .actions, title: "Keep Awake", subtitle: "Prevent the Mac from sleeping.",
                 symbol: "cup.and.saucer.fill", colors: Theme.Palette.orange, hint: "Turn on"),
        CBResult(id: "p2", kind: .apps, title: "Keynote", subtitle: "/Applications",
                 symbol: "app.fill", colors: Theme.Palette.blue, hint: "Open", altHint: "Reveal in Finder"),
        CBResult(id: "p3", kind: .pages, title: "Keyboard", subtitle: "Input › Keyboard",
                 symbol: "keyboard", colors: Theme.Palette.gray),
        CBResult(id: "p4", kind: .systemSettings, title: "Keyboard Settings", subtitle: "System Settings",
                 symbol: "keyboard", colors: Theme.Palette.gray),
        CBResult(id: "p5", kind: .web, title: "Search Google for \"ke\"", subtitle: "www.google.com",
                 symbol: "magnifyingglass", colors: Theme.Palette.blue, hint: "Search", altHint: "Search DuckDuckGo"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Preview", symbol: "eye")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                    Text("ke").font(.system(size: 22))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: CBLayout.header)
                Divider().opacity(0.5)
                VStack(spacing: 0) {
                    ForEach(Array(Self.samples.enumerated()), id: \.element.id) { i, r in
                        CBRow(result: r, index: i, selected: i == 0)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                CBFooter(result: Self.samples[0])
            }
            .frame(maxWidth: CBLayout.width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .card()
    }
}
