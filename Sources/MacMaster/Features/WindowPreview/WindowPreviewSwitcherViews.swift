import AppKit
import Combine
import SwiftUI

// MARK: - HUD background

struct WindowPreviewVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Apple-style glass HUD: Liquid Glass on macOS 26, `.hudWindow` vibrancy before that.
struct WindowPreviewHUD: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background { WindowPreviewVisualEffect().clipShape(shape) }
                .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}

// MARK: - Tile

struct WindowPreviewSwitcherTile: View {
    let item: WindowPreviewSwitcherItem
    let image: NSImage?
    let icon: NSImage?
    let size: CGSize
    let selected: Bool
    let hovered: Bool
    var onActivate: () -> Void = {}
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onQuit: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private let radius: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 8) {
            ZStack {
                shape.fill(Color.black.opacity(image == nil ? 0.10 : 0.24))
                preview
                if image != nil, let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: badgeSize, height: badgeSize)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
                statusBadges
                if selected || hovered { controls.transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topLeading))) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.white.opacity(hovered ? 0.3 : 0.1),
                                        lineWidth: selected ? 3 : 1))
            .shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: 12)

            Text(item.window.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary.opacity(selected ? 1 : 0.8))
                .frame(width: size.width, height: 18)
        }
        .scaleEffect(selected ? 1.045 : 1)
        .zIndex(selected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHover(true)
            case .ended: onHover(false)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.window.appName), \(item.window.title)")
    }

    private var badgeSize: CGFloat { max(24, min(36, size.width * 0.15)) }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .padding(8)
                .opacity(item.dimmed ? 0.5 : 1)
                .transition(.opacity)
        } else if let icon {
            // No screenshot (no Screen Recording, still loading, minimized...): big app icon.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: min(size.height * 0.56, 110), height: min(size.height * 0.56, 110))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .opacity(item.dimmed ? 0.5 : 0.95)
        }
    }

    private var statusBadges: some View {
        HStack(spacing: 4) {
            if item.window.isMinimized { badge("arrow.down.right.and.arrow.up.left", help: "Minimized") }
            if item.appHidden { badge("eye.slash", help: "App is hidden") }
            if item.window.onOtherSpace { badge("rectangle.3.group", help: "On another Space") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(8)
        .opacity(selected || hovered ? 0 : 1)
        .overlay(alignment: .bottomTrailing) {
            if item.appWindowCount > 1 {
                Text("\(item.appWindowCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    .padding(8)
                    .help(Fmt.count(item.appWindowCount, "window"))
            }
        }
    }

    private func badge(_ symbol: String, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .padding(5)
            .background(.ultraThinMaterial, in: Circle())
            .help(help)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !item.appOnly {
                control("xmark", Color(hex: 0xFF5F57), "Close window (W)", onClose)
                control("minus", Color(hex: 0xFEBC2E), item.window.isMinimized ? "Restore window (M)" : "Minimize (M)", onMinimize)
            }
            control("power", Color(hex: 0x8E8E93), "Quit \(item.window.appName) (Q)", onQuit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    private func control(_ symbol: String, _ color: Color, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.black.opacity(0.7))
                .frame(width: 20, height: 20)
                .background(color, in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Switcher panel content

struct WindowPreviewSwitcherPanelView: View {
    @ObservedObject var model: WindowPreviewSwitcherModel

    var body: some View {
        let l = model.layout
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(l.tile.width), spacing: l.gap), count: max(1, l.columns)),
                              spacing: l.gap) {
                        ForEach(model.items) { item in
                            WindowPreviewSwitcherTile(
                                item: item, image: model.images[item.id], icon: model.icons[item.window.pid],
                                size: l.tile, selected: model.selectedID == item.id, hovered: model.hoveredID == item.id,
                                onActivate: { model.onCommit(item) },
                                onClose: { model.onClose(item) },
                                onMinimize: { model.onMinimize(item) },
                                onQuit: { model.onQuit(item) },
                                onHover: { model.hover(item.id, inside: $0) })
                            .id(item.id)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(l.padding)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.selectedID) { _, id in
                    guard l.scrolls, let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if l.footer > 0 {
                Label("Live previews need Screen Recording. Showing app icons instead.", systemImage: "camera.metering.unknown")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: l.footer)
            }
        }
        .frame(width: l.content.width, height: l.content.height)
        .modifier(WindowPreviewHUD(radius: 24))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 8)
        .padding(l.inset)
        .scaleEffect(model.visible ? 1 : 0.94)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.visible)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.items.map(\.id))
    }
}

// MARK: - Settings mock

@MainActor
final class WindowPreviewMockModel: ObservableObject {
    @Published var items: [WindowPreviewSwitcherItem] = []
    @Published var images: [UInt32: NSImage] = [:]
    @Published var selected: UInt32?
    @Published var live = false
    var icons: [pid_t: NSImage] = [:]
    private var index = 0
    private var loaded = false

    func load() async {
        if items.isEmpty { loadSamples() }
        guard !loaded else { return }
        loaded = true
        guard Permissions.isGranted(.accessibility) else { return }
        let cache = WindowPreviewWindowCache.shared
        let wins = cache.hasData ? cache.windows : await cache.refresh()
        let rec = WindowPreviewRecency.shared
        let top = wins
            .filter { $0.isOnScreen && !$0.isMinimized && $0.id & 0x8000_0000 == 0 }
            .sorted { (rec.score($0), -$0.order) > (rec.score($1), -$1.order) }
            .prefix(4)
        guard top.count >= 2 else { return }
        var live: [WindowPreviewSwitcherItem] = []
        var icons: [pid_t: NSImage] = [:]
        for w in top {
            live.append(WindowPreviewSwitcherItem(id: w.id, window: w, appWindowCount: 1, appHidden: false, appOnly: false))
            icons[w.pid] = NSRunningApplication(processIdentifier: w.pid)?.icon
        }
        var imgs: [UInt32: NSImage] = [:]
        if Permissions.isGranted(.screenRecording) {
            let thumbs = WindowPreviewThumbnailer.shared
            for w in top {
                if let c = await thumbs.capture(id: w.id, box: CGSize(width: 520, height: 330), maxAge: 20) {
                    imgs[w.id] = WindowPreviewSwitcherModel.nsImage(c)
                }
            }
        }
        withAnimation(.smooth) {
            self.icons = icons
            self.items = live
            self.images = imgs
            self.live = true
            index = 0
            selected = live.first?.id
        }
    }

    func advance() {
        guard items.count > 1 else { return }
        index = (index + 1) % min(3, items.count)
        selected = items[index].id
    }

    private func loadSamples() {
        struct S { let app: String; let bundle: String; let title: String; let color: Color }
        let samples = [
            S(app: "Safari", bundle: "com.apple.Safari", title: "Apple", color: Color(hex: 0x0A84FF)),
            S(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "MacMaster.swift", color: Color(hex: 0x5E5CE6)),
            S(app: "Terminal", bundle: "com.apple.Terminal", title: "zsh — 120×32", color: Color(hex: 0x2C2C2E)),
            S(app: "Notes", bundle: "com.apple.Notes", title: "Shopping list", color: Color(hex: 0xFFD60A)),
        ]
        var items: [WindowPreviewSwitcherItem] = []
        for (i, s) in samples.enumerated() {
            let pid = pid_t(-(i + 1))
            let id = UInt32(0xD000_0000) + UInt32(i)
            let w = WindowPreviewWindow(id: id, pid: pid, title: s.title, appName: s.app, bundleID: s.bundle,
                                        frame: CGRect(x: 0, y: 0, width: 1200, height: 760), isMinimized: false,
                                        isOnScreen: true, onOtherSpace: false, order: i, ax: nil)
            items.append(WindowPreviewSwitcherItem(id: id, window: w, appWindowCount: i == 0 ? 3 : 1, appHidden: false, appOnly: false))
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundle) {
                icons[pid] = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                icons[pid] = NSWorkspace.shared.icon(for: .applicationBundle)
            }
            let renderer = ImageRenderer(content: WindowPreviewMockArt(color: s.color).frame(width: 400, height: 253))
            renderer.scale = 1
            if let img = renderer.nsImage { images[id] = img }
        }
        self.items = items
        selected = items.count > 1 ? items[1].id : items.first?.id
        index = 1
    }
}

/// Fake window content used for the settings mock when no real windows are available.
private struct WindowPreviewMockArt: View {
    let color: Color
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 10, height: 10) }
                }
                ForEach(Array([0.8, 0.55, 0.7, 0.4].enumerated()), id: \.offset) { _, f in
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.28)).frame(width: 340 * f, height: 12)
                }
                Spacer()
            }
            .padding(16)
        }
    }
}

/// Large live mock of the switcher HUD for the settings page. Uses your real windows when it can,
/// reflects the chosen size and cycles the selection like Tab would.
struct WindowPreviewSwitcherMock: View {
    @ObservedObject var settings: WindowPreviewSettings
    @StateObject private var model = WindowPreviewMockModel()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var width: CGFloat = 0

    private var tile: CGSize {
        let b = settings.switcherSize.switcherSize
        return CGSize(width: b.width * 0.72, height: b.height * 0.72)
    }

    var body: some View {
        ZStack {
            wallpaper.drawingGroup() // static; rasterize the blurs once
            // Fit as many tiles as the width allows (cheaper than ViewThatFits, which lays out every candidate).
            hud(model.items.prefix(fittingCount))
                .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .overlay(alignment: .topLeading) {
            StatusPill(text: model.live ? "Your windows" : "Sample", color: model.live ? .green : .gray).padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(settings.switcherShortcut.symbol) ⇥").font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.35), in: Capsule())
                .foregroundStyle(.white).padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task { await model.load() }
        .onReceive(timer) { _ in
            // Only animate while MacMaster is frontmost; nobody is watching otherwise.
            guard NSApp.isActive else { return }
            withAnimation(.easeOut(duration: 0.25)) { model.advance() }
        }
    }

    private var fittingCount: Int {
        let per = tile.width + 14
        let avail = width - 24 - 40 + 14
        return max(2, min(4, Int(avail / per)))
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3A2E8F), Color(hex: 0x8E3FBF), Color(hex: 0xE0567A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(hex: 0x5AC8FA).opacity(0.35)).frame(width: 280).blur(radius: 60).offset(x: -220, y: -40)
            Circle().fill(Color(hex: 0xFFB340).opacity(0.30)).frame(width: 240).blur(radius: 60).offset(x: 240, y: 60)
        }
    }

    private func hud(_ items: ArraySlice<WindowPreviewSwitcherItem>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(items) { item in
                WindowPreviewSwitcherTile(item: item, image: model.images[item.id], icon: model.icons[item.window.pid],
                                          size: tile, selected: model.selected == item.id, hovered: false)
            }
        }
        .padding(20)
        .modifier(WindowPreviewHUD(radius: 24))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(.horizontal, 12)
    }
}
