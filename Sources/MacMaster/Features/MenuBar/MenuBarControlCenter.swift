import SwiftUI
import AppKit

private struct MenuBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Popover root: a Control Center style panel. Host with `NSHostingController(rootView: MenuBarControlCenter())`.
struct MenuBarControlCenter: View {
    @State private var model = MenuBarModel.shared
    @State private var monitor = SystemMonitor.shared
    @State private var battery = BatteryMonitor.shared
    @State private var health = HealthMonitor.shared
    @State private var contentHeight: CGFloat = 520
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 352

    private var maxHeight: CGFloat {
        min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                header
                if model.isSectionVisible(.issues), !health.issues.isEmpty { issuesBanner }
                if model.isSectionVisible(.stats) { statsStrip }
                if model.isSectionVisible(.toggles) { toggleGrid }
                if model.isSectionVisible(.sliders), model.hasBrightness || model.hasVolume { sliders }
                if model.isSectionVisible(.actions) { actionsSection }
                if model.isSectionVisible(.windows) { windowsSection }
                if model.isSectionVisible(.power) { powerSection }
                if model.isSectionVisible(.processes) { processesSection }
            }
            .padding(12)
            .background(GeometryReader { Color.clear.preference(key: MenuBarHeightKey.self, value: $0.size.height) })
        }
        .frame(width: Self.width, height: min(max(contentHeight, 120), maxHeight))
        .onPreferenceChange(MenuBarHeightKey.self) { h in
            if h > 0 { contentHeight = h }
        }
        .animation(.smooth(duration: 0.25), value: model.prefsRevision)
        .onAppear {
            monitor.start()
            model.appeared()
            if model.isSectionVisible(.processes) { model.acquireProcesses() }
        }
        .onDisappear { model.disappeared() }
        .onChange(of: model.prefsRevision) {
            if model.isSectionVisible(.processes) { model.acquireProcesses() } else { model.releaseProcesses() }
        }
    }

    // MARK: Header

    private var scoreColor: Color { health.score >= 80 ? .green : health.score >= 60 ? .orange : .red }

    private var header: some View {
        HStack(spacing: 10) {
            MenuBarLogoTile(size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(SystemInfo.current.hostName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Button { openMain(.health) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(scoreColor).frame(width: 7, height: 7)
                        Text("Health \(health.score)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(scoreColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(MenuBarPressStyle())
                .help(health.summary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                MenuBarIconButton(symbol: "macwindow", help: "Open MacMaster") { openMain(nil) }
                MenuBarIconButton(symbol: "gearshape.fill", help: "Settings") { openSettings() }
                MenuBarIconButton(symbol: "power", help: "Quit MacMaster", tint: .red) { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Issues

    private var issuesBanner: some View {
        let worst = health.issues.map(\.severity).max() ?? .info
        let color: Color = worst == .critical ? .red : .orange
        return Button { openMain(.health) } label: {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(health.issues.count) issue\(health.issues.count == 1 ? "" : "s") need attention")
                        .font(.system(size: 12, weight: .semibold))
                    Text(health.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.25)))
        }
        .buttonStyle(MenuBarPressStyle())
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: Stats

    private var statsStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                MenuBarMiniGauge(label: "CPU", fraction: monitor.cpu.total, colors: Theme.Palette.stats) { openMain(.stats) }
                MenuBarMiniGauge(label: "RAM", fraction: monitor.memory.usedFraction, colors: Theme.Palette.windows) { openMain(.stats) }
                MenuBarMiniGauge(label: "GPU", fraction: monitor.gpu, colors: Theme.Palette.health) { openMain(.stats) }
                MenuBarMiniGauge(label: "Disk", fraction: monitor.disk.usedFraction, colors: Theme.Palette.tools) { openMain(.stats) }
            }
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").foregroundStyle(Theme.Palette.network)
                    Text(Fmt.rate(monitor.network.downRate))
                    Image(systemName: "arrow.up").foregroundStyle(Theme.Palette.cpu).padding(.leading, 4)
                    Text(Fmt.rate(monitor.network.upRate))
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let t = monitor.thermal.cpu {
                    HStack(spacing: 2) {
                        Image(systemName: "thermometer.medium").foregroundStyle(Theme.Palette.thermal)
                        Text(Fmt.temperature(t))
                    }
                }
                if battery.reading.isPresent {
                    HStack(spacing: 4) {
                        BatteryGlyph(percent: battery.reading.percent, isCharging: battery.reading.isCharging,
                                     isPluggedIn: battery.reading.isPluggedIn, height: 10)
                        Text(Fmt.percent(battery.reading.percent))
                    }
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        .padding(8)
        .menuBarGlass(radius: 16)
    }

    // MARK: Toggles

    private var toggleGrid: some View {
        let tiles = MenuBarTile.allCases.filter { model.isTileVisible($0) }
        let cols = model.tileColumns
        return Group {
            if !tiles.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                    ForEach(tiles) { t in
                        MenuBarToggleTile(symbol: symbol(for: t), title: t.title, subtitle: model.subtitle(t),
                                          isOn: model.isOn(t), tint: t.tint, busy: model.busy.contains(t.rawValue),
                                          compact: cols == 3) { model.toggle(t) }
                    }
                }
            }
        }
    }

    private func symbol(for t: MenuBarTile) -> String {
        switch t {
        case .darkMode: model.snapshot.darkMode ? "moon.fill" : "sun.max.fill"
        case .wifi: model.snapshot.wifi == true ? "wifi" : "wifi.slash"
        case .mute: model.snapshot.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .hideDesktop: model.snapshot.hideDesktop ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle"
        default: t.symbol
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 10) {
            if model.hasBrightness {
                MenuBarSlider(title: "Display", symbol: "sun.max.fill",
                              value: Binding(get: { model.brightness }, set: { model.brightness = $0 }),
                              onChange: { model.setBrightness($0) })
            }
            if model.hasVolume {
                MenuBarSlider(title: "Sound", symbol: volumeSymbol,
                              value: Binding(get: { model.volume }, set: { model.volume = $0 }),
                              onChange: { model.setVolume($0) })
            }
        }
        .padding(12)
        .menuBarGlass(radius: 16)
    }

    private var volumeSymbol: String {
        if model.snapshot.muted == true || model.volume <= 0.001 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: Actions

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MenuBarSectionLabel(text: "Snap front window")
                Spacer()
                Button { openMain(.tiling) } label: { Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            TilingQuickGrid()
            HStack(spacing: 8) {
                MenuBarManagerQuickToggle()
                Button { TilingEngine.shared.tileAll() } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.13))
                            Image(systemName: "square.grid.2x2").font(.system(size: 14, weight: .semibold))
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Tile All").font(.system(size: 12, weight: .semibold))
                            Text("Grid this screen").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 150, height: 64)
                    .menuBarGlass(radius: 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarPressStyle())
            }
        }
        .padding(10)
        .menuBarGlass(radius: 16)
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuBarSectionLabel(text: "Power")
            PowerQuickRow()
        }
        .padding(10)
        .menuBarGlass(radius: 16)
    }

    private var actionsSection: some View {
        let actions = MenuBarQuickAction.allCases.filter { model.isActionVisible($0) }
        return Group {
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 10) {
                        ForEach(actions) { a in
                            MenuBarActionButton(action: a, busy: model.busy.contains(a.rawValue)) { model.run(a) }
                        }
                    }
                    feedback
                }
                .padding(10)
                .menuBarGlass(radius: 16)
            }
        }
    }

    /// Inline confirmation or result toast.
    @ViewBuilder private var feedback: some View {
        if let c = model.confirm {
            VStack(alignment: .leading, spacing: 6) {
                Text(c.title).font(.system(size: 12, weight: .semibold))
                Text(c.message).font(.system(size: 10.5)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { withAnimation(.smooth) { model.confirm = nil } }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button(c.button) { let run = c.run; withAnimation(.smooth) { model.confirm = nil }; run() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let t = model.toast {
            HStack(spacing: 6) {
                Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? .orange : .green)
                Text(t.text).font(.system(size: 11)).lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: Processes

    private var processesSection: some View {
        let top = Array(monitor.topCPU.filter { $0.cpu > 0 || true }.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            MenuBarSectionLabel(text: "Top processes")
            if top.isEmpty {
                Text("Sampling…").font(.system(size: 11)).foregroundStyle(.secondary).padding(6)
            } else {
                ForEach(top) { p in
                    MenuBarProcessRow(sample: p, canQuit: model.canQuit(pid: p.pid)) { model.quitApp(pid: p.pid) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .menuBarGlass(radius: 16)
    }

    // MARK: Navigation

    private func openMain(_ section: AppSection?) {
        MainStatusItem.shared.close()
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { openWindow(id: "main") }
        MainWindow.show(section: section)
    }

    private func openSettings() {
        openMain(nil)
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
