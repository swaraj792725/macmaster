import AppKit
import SwiftUI

// MARK: - Glass

struct TilingGlass: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

// MARK: - Layout diagram

/// Mini window-in-screen glyph for a layout.
struct TilingLayoutDiagram: View {
    let layout: TilingLayout
    var highlighted = false
    var accent: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            let inset: CGFloat = 2.5
            let w = geo.size.width - inset * 2, h = geo.size.height - inset * 2
            ZStack(alignment: .topLeading) {
                shape.fill(Color.primary.opacity(highlighted ? 0.12 : 0.06))
                shape.strokeBorder(highlighted ? accent.opacity(0.9) : Color.primary.opacity(0.2), lineWidth: 1)
                if let r = layout.diagramRect {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(highlighted ? accent : accent.opacity(0.55))
                        .frame(width: max(3, r.width * w), height: max(3, r.height * h))
                        .offset(x: inset + r.minX * w, y: inset + r.minY * h)
                } else {
                    Image(systemName: SymbolKit.resolve(layout.symbol))
                        .font(.system(size: min(geo.size.height * 0.5, 14), weight: .semibold))
                        .foregroundStyle(highlighted ? accent : Color.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .animation(.smooth(duration: 0.15), value: highlighted)
        .accessibilityLabel(layout.title)
    }
}

// MARK: - Mini screen (hero + zone map)

/// Interactive miniature desktop. Hover a zone to preview the resulting frame; click to apply it.
struct TilingMiniScreen: View {
    var onHoverChange: (TilingLayout?) -> Void = { _ in }
    var onApply: (TilingLayout) -> Void
    @State private var hover: TilingZoneRegion?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack(alignment: .topLeading) {
                shape.fill(LinearGradient(colors: [Color(hex: 0x6A8DFF), Color(hex: 0x9B6BFF), Color(hex: 0xFF7DB0)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.85))
                // menu bar
                Rectangle().fill(.white.opacity(0.22)).frame(height: size.height * 0.055)
                // target preview
                if let h = hover, let r = h.layout.diagramRect {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.95), lineWidth: 2))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .frame(width: r.width * size.width - 12, height: r.height * size.height - 12)
                        .offset(x: r.minX * size.width + 6, y: r.minY * size.height + 6)
                        .transition(.opacity)
                }
                // zone hit regions
                ForEach(TilingZoneRegion.all) { region in
                    let rect = region.rect
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(hover == region ? 0.18 : 0.0))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(hover == nil ? 0.28 : (hover == region ? 0.9 : 0.12)),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .frame(width: rect.width * size.width - 4, height: rect.height * size.height - 4)
                        .offset(x: rect.minX * size.width + 2, y: rect.minY * size.height + 2)
                }
                .allowsHitTesting(false)
                // dock
                Capsule().fill(.white.opacity(0.25))
                    .frame(width: size.width * 0.34, height: size.height * 0.05)
                    .position(x: size.width / 2, y: size.height - size.height * 0.04)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let u = CGPoint(x: p.x / max(1, size.width), y: p.y / max(1, size.height))
                    let h = TilingZoneRegion.all.first { $0.rect.contains(u) }
                    if h != hover {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hover = h }
                        onHoverChange(h?.layout)
                    }
                case .ended:
                    withAnimation(.smooth(duration: 0.2)) { hover = nil }
                    onHoverChange(nil)
                }
            }
            .onTapGesture {
                if let h = hover { onApply(h.layout) }
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
    }
}

/// Static map of drag-to-snap zones; regions dim when their setting is off.
struct TilingZoneMap: View {
    @AppStorage(TilingSettings.Key.snapHalves) private var halves = true
    @AppStorage(TilingSettings.Key.snapTop) private var top = true
    @AppStorage(TilingSettings.Key.snapCorners) private var corners = true
    @AppStorage(TilingSettings.Key.snapThirds) private var thirds = true

    private func isOn(_ l: TilingLayout) -> Bool {
        switch l {
        case .leftHalf, .rightHalf: halves
        case .maximize: top
        case .topLeft, .topRight, .bottomLeft, .bottomRight: corners
        case .leftThird, .centerThird, .rightThird: thirds
        default: false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            ZStack(alignment: .topLeading) {
                shape.fill(Color.primary.opacity(0.05))
                ForEach(TilingZoneRegion.all.filter { $0.layout != .center }) { region in
                    let on = isOn(region.layout)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.04))
                        .overlay(
                            Text(region.layout.shortTitle)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(on ? Color.primary : Color.secondary.opacity(0.6))
                        )
                        .frame(width: region.rect.width * size.width - 3, height: region.rect.height * size.height - 3)
                        .offset(x: region.rect.minX * size.width + 1.5, y: region.rect.minY * size.height + 1.5)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .animation(.smooth(duration: 0.2), value: halves)
            .animation(.smooth(duration: 0.2), value: top)
            .animation(.smooth(duration: 0.2), value: corners)
            .animation(.smooth(duration: 0.2), value: thirds)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
    }
}

// MARK: - Shortcut recorder

struct TilingShortcutRecorder: View {
    let layout: TilingLayout
    private let store = TilingShortcutStore.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hover = false

    var body: some View {
        let sc = store.shortcut(for: layout)
        let conflict = store.conflicts.contains(layout.rawValue)
        HStack(spacing: 6) {
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut is already used by another app or the system.")
            }
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Type shortcut…" : (sc?.display ?? "Record"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(recording ? Color.accentColor : (sc == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 84)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hover ? 0.09 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Theme.hairline, lineWidth: recording ? 1.5 : 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            if sc != nil && !recording {
                Button { store.clear(layout) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .animation(.smooth(duration: 0.15), value: recording)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        TilingHotkeys.shared.setPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown { stopRecording(); return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stopRecording(); return nil } // esc
            if mods.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
                store.clear(layout)
                stopRecording()
                return nil
            }
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            store.set(TilingShortcut(keyCode: UInt32(event.keyCode), modifiers: TilingShortcut.carbonModifiers(mods)),
                      for: layout)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording {
            recording = false
            TilingHotkeys.shared.setPaused(false)
        }
    }
}

// MARK: - Quick grid (menu bar)

/// Compact ~320×70 row of layout buttons. Applies to the frontmost non-MacMaster window.
struct TilingQuickGrid: View {
    private static let items: [TilingLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .maximize, .center,
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.items) { layout in TilingQuickGridButton(layout: layout) }
        }
        .padding(.horizontal, 2)
        .frame(width: 320, height: 70)
    }
}

private struct TilingQuickGridButton: View {
    let layout: TilingLayout
    @State private var hover = false

    var body: some View {
        Button { TilingEngine.shared.apply(layout) } label: {
            VStack(spacing: 4) {
                TilingLayoutDiagram(layout: layout, highlighted: hover)
                    .frame(width: 32, height: 24)
                Text(layout.shortTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 34, height: 58)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(layout.title)
        .animation(.smooth(duration: 0.12), value: hover)
    }
}
