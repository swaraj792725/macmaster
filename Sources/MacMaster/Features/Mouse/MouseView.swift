import SwiftUI

struct MouseView: View {
    @ObservedObject private var settings = MouseSettings.shared
    @ObservedObject private var engine = MouseEngine.shared
    @State private var selectedButton = 3

    var body: some View {
        Page(jump: [PageJump("mouse.scrolling", "Scrolling"), PageJump("mouse.buttons", "Buttons"),
                    PageJump("mouse.pointer", "Pointer"),
                    PageJump("mouse.test", "Test area")]) {
            PageHeader(title: "Mouse", subtitle: "Smooth scrolling, button remapping and hold-and-drag actions for external mice",
                       symbol: "computermouse.fill", colors: Theme.Palette.mouse) {
                HStack(spacing: 12) {
                    StatusPill(text: engine.status.text, color: statusColor)
                    Toggle("", isOn: $settings.enabled)
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            PermissionBanner(permission: .accessibility,
                             reason: "Needed to intercept mouse scroll and button events system-wide.")

            statsRow

            MouseClicksSection()

            Group {
                scrollingCard.searchAnchor("mouse.scrolling")
                buttonsCard.searchAnchor("mouse.buttons")
                pointerCard.searchAnchor("mouse.pointer")
                MouseTestArea(engine: engine).searchAnchor("mouse.test")
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)
        }
        .onAppear {
            MouseTelemetry.shared.setRecording(true)
            engine.start()
        }
        .onDisappear { MouseTelemetry.shared.setRecording(false) }
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: return .green
        case .needsAccessibility, .failed: return .orange
        case .off: return .gray
        }
    }

    // MARK: Stats

    private var statsRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let s = MouseStatsStore.shared.snapshot()
            let top = s.buttonPresses.max { $0.value < $1.value }
            HStack(spacing: Theme.spacing) {
                StatTile(title: "Clicks today", value: "\(s.clicks)",
                         caption: "\(s.buttonPresses.values.reduce(0, +) - (s.buttonPresses[0] ?? 0) - (s.buttonPresses[1] ?? 0)) on extra buttons",
                         symbol: "cursorarrow.click.2", colors: Theme.Palette.mouse)
                StatTile(title: "Scrolled today", value: Self.distance(s.scrollMeters),
                         caption: "\(Int(s.scrollPixels).formatted()) pt of wheel scrolling",
                         symbol: "arrow.up.and.down.circle.fill", colors: Theme.Palette.stats)
                StatTile(title: "Favorite button", value: top.map { mouseButtonName($0.key).components(separatedBy: " (").first ?? "—" } ?? "—",
                         caption: top.map { "\($0.value) presses" } ?? "No clicks yet",
                         symbol: "star.fill", colors: Theme.Palette.tools)
            }
        }
    }

    private static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : (m >= 1 ? String(format: "%.1f m", m) : String(format: "%.0f cm", m * 100))
    }

    // MARK: Scrolling

    private var scrollingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Scrolling", symbol: "arrow.up.and.down.text.horizontal")
            Text("These only affect external mice with a wheel. Trackpads and Magic Mouse are never touched.")
                .font(.callout).foregroundStyle(.secondary)

            Toggle("Reverse vertical scrolling", isOn: $settings.config.reverseVertical)
            Toggle("Reverse horizontal scrolling", isOn: $settings.config.reverseHorizontal)

            Divider()

            Toggle(isOn: $settings.config.smoothEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth scrolling").fontWeight(.semibold)
                    Text("Turns wheel clicks into fluid, pixel-precise scrolling.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.config.smoothEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Smoothness").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                        Picker("", selection: $settings.config.smoothness) {
                            ForEach(MouseSmoothness.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                    }
                    HStack {
                        Text("Speed").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                        Slider(value: $settings.config.speed, in: 0.3...3.0).frame(maxWidth: 260)
                        Text(String(format: "%.1f×", settings.config.speed)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("Acceleration").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                        Picker("", selection: $settings.config.acceleration) {
                            ForEach(MouseAccelCurve.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 180)
                        Text("Faster spins travel further").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Inertia (keep gliding after the wheel stops)", isOn: $settings.config.inertia)
                }
                .padding(.leading, 4)
            }

            Divider()

            Text("Modifier keys").font(.subheadline.weight(.semibold))
            Toggle("Shift + scroll scrolls horizontally", isOn: $settings.config.shiftHorizontal)
            Toggle("Option + scroll is slow and precise" + (settings.config.smoothEnabled ? "" : " (needs smooth scrolling)"),
                   isOn: $settings.config.optionPrecise)
            Toggle("Control + scroll is fast" + (settings.config.smoothEnabled ? "" : " (needs smooth scrolling)"),
                   isOn: $settings.config.controlFast)
            Toggle("Command + scroll passes through untouched (zoom)", isOn: $settings.config.commandZoomPassthrough)
            if settings.config.optionPrecise || settings.config.controlFast {
                HStack(spacing: 24) {
                    if settings.config.optionPrecise {
                        HStack {
                            Text("Precise").foregroundStyle(.secondary)
                            Slider(value: $settings.config.preciseFactor, in: 0.1...0.8).frame(width: 140)
                            Text(String(format: "%.1f×", settings.config.preciseFactor)).monospacedDigit()
                        }
                    }
                    if settings.config.controlFast {
                        HStack {
                            Text("Fast").foregroundStyle(.secondary)
                            Slider(value: $settings.config.fastFactor, in: 1.5...8).frame(width: 140)
                            Text(String(format: "%.1f×", settings.config.fastFactor)).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }
        }
        .toggleStyle(.mmSwitch)
        .card()
    }

    // MARK: Buttons

    private var buttonsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Buttons", symbol: "computermouse")
            Text("Press a button on your mouse (or pick one below) to choose what it does. Left and right buttons are never changed.")
                .font(.callout).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 24) {
                MouseIllustration(selected: $selectedButton, mappings: settings.config.mappings)
                    .frame(width: 190)

                VStack(alignment: .leading, spacing: 10) {
                    buttonChips
                    HStack {
                        Text(mouseButtonName(selectedButton)).font(.headline)
                        Spacer()
                        Button("Reset button") { settings.config.mappings[selectedButton] = nil }
                            .controlSize(.small)
                            .disabled(settings.config.mappings[selectedButton] == nil)
                    }
                    MouseActionEditor(title: "Click", action: mappingBinding(\.click))
                    MouseActionEditor(title: "Double click", action: mappingBinding(\.doubleClick))
                    MouseActionEditor(title: "Long press", action: mappingBinding(\.hold))
                    Divider().padding(.vertical, 2)
                    dragEditor
                    Text("Double click and long press add a short delay before a plain click of that button fires.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private var dragMode: Binding<MouseDragMode> {
        let b = selectedButton
        return Binding(
            get: { settings.config.mappings[b]?.drag ?? .none },
            set: { newValue in
                var m = settings.config.mappings[b] ?? MouseButtonMapping()
                m.drag = newValue
                settings.config.mappings[b] = m
            })
    }

    @ViewBuilder
    private var dragEditor: some View {
        let mode = dragMode.wrappedValue
        HStack {
            Text("Hold & drag").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            Picker("", selection: dragMode) {
                ForEach(MouseDragMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 260)
            Spacer(minLength: 0)
        }
        if mode != .none {
            HStack(alignment: .top) {
                Spacer().frame(width: 110)
                Text(mode.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if mode == .spaces || mode == .custom {
            HStack {
                Text("Drag distance").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                Slider(value: $settings.config.gestureThreshold, in: 20...200).frame(maxWidth: 200)
                Text("\(Int(settings.config.gestureThreshold)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        if mode == .custom {
            MouseActionEditor(title: "← Drag left", action: mappingBinding(\.dragLeft))
            MouseActionEditor(title: "→ Drag right", action: mappingBinding(\.dragRight))
            MouseActionEditor(title: "↑ Drag up", action: mappingBinding(\.dragUp))
            MouseActionEditor(title: "↓ Drag down", action: mappingBinding(\.dragDown))
        }
    }

    private var buttonChips: some View {
        HStack(spacing: 6) {
            ForEach(2...9, id: \.self) { b in
                Button {
                    selectedButton = b
                } label: {
                    VStack(spacing: 1) {
                        Text(Self.chipName(b)).font(.caption.weight(.bold))
                        Text(settings.mapping(b).isManaged ? "mapped" : "default")
                            .font(.system(size: 9)).foregroundStyle(settings.mapping(b).isManaged ? Theme.Palette.mouse[0] : .secondary)
                    }
                    .frame(minWidth: 44)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(selectedButton == b ? Theme.Palette.mouse[1].opacity(0.35) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mouseButtonName(b))
            }
        }
    }

    private static func chipName(_ b: Int) -> String {
        switch b {
        case 2: return "Middle"
        case 3: return "Back"
        case 4: return "Forward"
        default: return "#\(b + 1)"
        }
    }

    private func mappingBinding(_ kp: WritableKeyPath<MouseButtonMapping, MouseAction>) -> Binding<MouseAction> {
        let b = selectedButton
        return Binding(
            get: { (settings.config.mappings[b] ?? MouseButtonMapping())[keyPath: kp] },
            set: { newValue in
                var m = settings.config.mappings[b] ?? MouseButtonMapping()
                m[keyPath: kp] = newValue
                settings.config.mappings[b] = m
            })
    }

    // MARK: Pointer

    private var pointerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Pointer", symbol: "cursorarrow.motionlines")
            Text("Applies to external mice only (trackpad settings are separate). Changes are live and revert when MacMaster quits or you reset.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Disable pointer acceleration (flat, 1:1 movement)", isOn: $settings.config.disableAcceleration)
            Toggle("Custom pointer speed", isOn: $settings.config.customPointerSpeed)
                .disabled(settings.config.disableAcceleration)
            if settings.config.customPointerSpeed && !settings.config.disableAcceleration {
                HStack {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.config.pointerSpeed, in: 0.1...3.0).frame(maxWidth: 320)
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    Text(String(format: "%.2f", settings.config.pointerSpeed)).monospacedDigit()
                }
            }
            HStack {
                Button("Reset to system default") { engine.resetPointer() }
                Text(engine.pointerStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.mmSwitch)
        .card()
    }
}
