import SwiftUI
import AppKit

struct KeyboardCornersTab: View {
    @AppStorage(KeyboardPrefs.cornersEnabled) private var enabled = false
    @AppStorage(KeyboardPrefs.cornerDelay) private var delay = 0.25
    @AppStorage(KeyboardPrefs.cornerFlash) private var flash = true
    @State private var selected: KeyboardCorner = .topLeft
    @State private var native: [KeyboardCorner] = []
    private let store = KeyboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if !native.isEmpty { nativeWarning }

            KeyboardToggleHeader(symbol: "rectangle.inset.topleft.filled", colors: Theme.Palette.purple,
                                 title: "Hot Corners+",
                                 detail: "Push the cursor into a screen corner to trigger an action. Add a dwell delay and a modifier to avoid accidents.",
                                 pill: enabled ? ("On", Color(hex: 0x30D158)) : ("Off", .secondary), isOn: $enabled)

            diagram

            GroupedSection(selected.title, symbol: "rectangle.dashed",
                           footer: "Triggers when the cursor rests in the 2 px corner for the dwell time. Dragging a window into a corner doesn't trigger it.") {
                SettingsRow(title: "Action", symbol: store.corners[selected].action.symbol, colors: Theme.Palette.purple) {
                    Picker("Action", selection: actionBinding) {
                        ForEach(KeyboardCornerAction.allCases) { a in Label(a.title, systemImage: a.symbol).tag(a) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Only when", subtitle: "Require a modifier key to be held", symbol: "option",
                            colors: Theme.Palette.orange) {
                    Picker("Modifier", selection: modifierBinding) {
                        ForEach(KeyboardCornerModifier.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if store.corners[selected].action == .openApp {
                    SettingsRow(title: "App",
                                subtitle: store.corners[selected].appPath.isEmpty ? "Not set"
                                    : KeyboardPickers.appName(store.corners[selected].appPath),
                                symbol: "app.fill", colors: Theme.Palette.blue) {
                        Button("Pick App…") {
                            if let p = KeyboardPickers.chooseApp() { store.corners[selected].appPath = p }
                        }
                    }
                }
                SettingsRow(title: "Try this action", symbol: "play.fill", colors: Theme.Palette.green) {
                    Button("Run Now") {
                        let c = store.corners[selected]
                        KeyboardSystemActions.perform(c.action, appPath: c.appPath)
                    }
                    .disabled(store.corners[selected].action == .none)
                }
            }

            GroupedSection("Behaviour") {
                SettingsRow(title: "Dwell delay", subtitle: "How long the cursor must stay in the corner",
                            symbol: "timer", colors: Theme.Palette.teal) {
                    HStack(spacing: 10) {
                        Slider(value: $delay.snapped(0.05), in: 0.05...1.5).frame(width: 160)
                        Text(String(format: "%.2f s", delay)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                SettingsRow(title: "Corner flash", subtitle: "Brief animation when a corner fires",
                            symbol: "sparkles", colors: Theme.Palette.yellow) {
                    Toggle("Corner flash", isOn: $flash).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { native = KeyboardHotCorners.nativeCornersInUse() }
    }

    private var actionBinding: Binding<KeyboardCornerAction> {
        Binding(get: { store.corners[selected].action },
                set: { store.corners[selected].action = $0 })
    }

    private var modifierBinding: Binding<KeyboardCornerModifier> {
        Binding(get: { store.corners[selected].modifier },
                set: { store.corners[selected].modifier = $0 })
    }

    private var nativeWarning: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill", colors: Theme.Palette.orange, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS hot corners are also set").font(.headline)
                Text("\(native.map(\.title).joined(separator: ", ")) will trigger the system action as well. Turn them off in Desktop & Dock → Hot Corners.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Recheck") { native = KeyboardHotCorners.nativeCornersInUse() }.buttonStyle(.mmSecondary)
            Button("Open Settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(u) }
            }.buttonStyle(.mmPrimary)
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFF9F0A).opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Color(hex: 0xFF9F0A).opacity(0.28), lineWidth: 0.5))
    }

    private var diagram: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: 0x5856D6).opacity(0.22), Color(hex: 0xAF52DE).opacity(0.14)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(Theme.hairline, lineWidth: 1)
            VStack(spacing: 4) {
                Image(systemName: "macwindow").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Choose a corner to configure").font(.caption).foregroundStyle(.secondary)
            }
            VStack {
                HStack { chip(.topLeft); Spacer(); chip(.topRight) }
                Spacer()
                HStack { chip(.bottomLeft); Spacer(); chip(.bottomRight) }
            }
            .padding(10)
        }
        .frame(height: 220)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func chip(_ corner: KeyboardCorner) -> some View {
        let cfg = store.corners[corner]
        let isSel = selected == corner
        return Button { withAnimation(.smooth(duration: 0.2)) { selected = corner } } label: {
            VStack(spacing: 4) {
                Image(systemName: cfg.action.symbol).font(.system(size: 18, weight: .medium))
                Text(cfg.action == .none ? corner.title : cfg.action.title).font(.caption2.weight(.medium)).lineLimit(1)
                if cfg.modifier != .none { Text(cfg.modifier.title).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .frame(width: 112, height: 62)
            .background(isSel ? Color.accentColor.opacity(0.18) : Theme.cardFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSel ? Color.accentColor : Theme.hairline, lineWidth: isSel ? 1.5 : 0.5))
        }
        .buttonStyle(.mmCard)
        .accessibilityLabel("\(corner.title): \(cfg.action.title)")
    }
}
