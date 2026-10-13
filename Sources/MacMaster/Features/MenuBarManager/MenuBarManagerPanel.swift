import AppKit
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class MenuBarManagerPanelModel {
    var hidden: [MenuBarManagerItem] = []
    var alwaysHidden: [MenuBarManagerItem] = []
    var appeared = false
    var maxWidth: CGFloat = 900
    var busyID: Int?
    var onSelect: ((MenuBarManagerItem) -> Void)?
    /// Right-click "Show in menu bar": the real ⌘-drag move back to the visible section.
    var onShow: ((MenuBarManagerItem) -> Void)?
    /// When set, the panel shows this message and a button instead of icons.
    var notice: String?
    var onNoticeAction: (() -> Void)?
    var isEmpty: Bool { hidden.isEmpty && alwaysHidden.isEmpty }
}

private struct MenuBarManagerSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Views

/// One icon in the dropdown bar: captured image when available, app icon + name otherwise.
struct MenuBarManagerIconCell: View {
    let item: MenuBarManagerItem
    var busy = false
    var onShow: (() -> Void)?
    let action: () -> Void
    @State private var hover = false
    private let capture = MenuBarManagerCapture.shared

    var body: some View {
        // Reading the version makes the cell redraw when new captures land.
        let _ = MenuBarManager.shared.captureVersion
        Button(action: action) {
            Group {
                if let cap = capture.image(for: item) {
                    MenuBarManagerCaptureView(capture: cap)
                        .frame(width: max(14, item.frame.width), height: min(22, max(12, item.frame.height - 2)))
                } else {
                    HStack(spacing: 6) {
                        Image(nsImage: item.icon ?? NSImage())
                            .resizable().scaledToFit().frame(width: 20, height: 20)
                        Text(item.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.14 : 0)))
            .overlay { if busy { ProgressView().controlSize(.small) } }
            .scaleEffect(hover ? 1.06 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .help(item.displayName)
        .contextMenu {
            Button("Open") { action() }
            if let onShow {
                Divider()
                Button("Show in Menu Bar", action: onShow)
            }
        }
    }
}

/// Floating glass strip shown under the menu bar.
struct MenuBarManagerPanelView: View {
    let model: MenuBarManagerPanelModel
    var onSize: (CGSize) -> Void
    @State private var contentWidth: CGFloat = 0

    private var screenRecording: Bool { Permissions.isGranted(.screenRecording) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open Menu Bar Settings") { model.onNoticeAction?() }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(6)
            } else if model.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("No hidden icons. ⌘-drag icons left of the | divider to hide them.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.hidden) { it in cell(it) }
                        if !model.alwaysHidden.isEmpty {
                            if !model.hidden.isEmpty {
                                Rectangle().fill(Theme.hairline).frame(width: 1, height: 20).padding(.horizontal, 6)
                            }
                            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                            ForEach(model.alwaysHidden) { it in cell(it) }
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in contentWidth = w }
                    })
                }
                .frame(width: contentWidth > 0 ? min(contentWidth, model.maxWidth) : nil)
            }
            if !screenRecording && !model.isEmpty && model.notice == nil {
                Text("Grant Screen Recording to show the real icons.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .fixedSize()
        .modifier(MenuBarManagerGlassModifier(radius: 16))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .background(GeometryReader { g in
            Color.clear.preference(key: MenuBarManagerSizeKey.self, value: g.size)
        })
        .onPreferenceChange(MenuBarManagerSizeKey.self) { onSize($0) }
        .padding(10) // room for the window shadow
        .scaleEffect(model.appeared ? 1 : 0.9, anchor: .top)
        .opacity(model.appeared ? 1 : 0)
        .offset(y: model.appeared ? 0 : -10)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: model.appeared)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.hidden.count + model.alwaysHidden.count)
    }

    private func cell(_ it: MenuBarManagerItem) -> some View {
        MenuBarManagerIconCell(item: it, busy: model.busyID == it.id,
                               onShow: model.onShow.map { f in { f(it) } }) { model.onSelect?(it) }
    }
}

/// Liquid Glass on macOS 26, material elsewhere.
struct MenuBarManagerGlassModifier: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        }
    }
}

// MARK: - Window controller

private final class MenuBarManagerNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarManagerPanelController {
    let model = MenuBarManagerPanelModel()
    private var panel: NSPanel?
    private var host: NSHostingView<MenuBarManagerPanelView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorX: CGFloat = 0
    private var screen: NSScreen?
    private var hideTask: Task<Void, Never>?
    private(set) var isVisible = false
    var frame: NSRect? { isVisible ? panel?.frame : nil }
    var onDismiss: (() -> Void)?
    /// Clicks in this window (the toggle) don't dismiss; the toggle's own action handles them.
    weak var ignoredWindow: NSWindow?

    /// `anchor` is the toggle's frame in AppKit coordinates.
    func show(hidden: [MenuBarManagerItem], alwaysHidden: [MenuBarManagerItem], anchor: CGRect, on screen: NSScreen) {
        hideTask?.cancel()
        self.screen = screen
        anchorX = anchor.midX
        model.hidden = hidden
        model.alwaysHidden = alwaysHidden
        model.maxWidth = max(300, screen.frame.width - 60)
        if panel == nil { build() }
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        // Always place the panel before showing it; an unmeasured panel would sit at the screen origin.
        resize(fit.width > 20 && fit.height > 20 ? fit : CGSize(width: 380, height: 70), force: true)
        if !isVisible {
            model.appeared = false
            panel.orderFrontRegardless()
            installMonitors()
            isVisible = true
            DispatchQueue.main.async { [model] in model.appeared = true }
        }
    }

    func update(hidden: [MenuBarManagerItem], alwaysHidden: [MenuBarManagerItem]) {
        guard isVisible else { return }
        model.hidden = hidden
        model.alwaysHidden = alwaysHidden
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        model.appeared = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
        onDismiss?()
    }

    private func build() {
        let p = MenuBarManagerNSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // SwiftUI content draws its own; avoids a square shadow around the clear window
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = MenuBarManagerPanelView(model: model) { [weak self] size in
            self?.resize(CGSize(width: size.width + 20, height: size.height + 20))
        }
        let h = NSHostingView(rootView: view)
        h.sizingOptions = []
        p.contentView = h
        panel = p
        host = h
    }

    private func resize(_ size: CGSize, force: Bool = false) {
        guard let panel, let screen, size.width > 20, size.height > 20 else { return }
        if !force && panel.frame.size == size { return }
        let top = screen.frame.maxY - MenuBarManagerGeometry.stripHeight(of: screen) + 4
        let minX = screen.frame.minX + 4, maxX = screen.frame.maxX - size.width - 4
        let x = min(max(anchorX - size.width / 2, minX), max(minX, maxX))
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel, event.window !== self.ignoredWindow { self.hide() }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
    }
}
