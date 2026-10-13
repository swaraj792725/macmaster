import AppKit
import SwiftUI

// MARK: - Panel

/// Non-activating, transparent floating panel. Never takes focus from the frontmost app.
final class WindowPreviewPanel: NSPanel {
    var onMiddleClick: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseUp, event.buttonNumber == 2 {
            onMiddleClick?()
            return
        }
        super.sendEvent(event)
    }

    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

// MARK: - Glass background

struct WindowPreviewGlass: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14)))
        }
    }
}

// MARK: - Card

struct WindowPreviewCard: View {
    let window: WindowPreviewWindow
    let image: NSImage?
    let icon: NSImage?
    let size: CGSize
    let showTitle: Bool
    let selected: Bool
    let hovered: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.28))
                if let image {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .opacity(window.isMinimized ? 0.5 : 1)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else if let icon {
                    VStack(spacing: 6) {
                        Image(nsImage: icon).resizable().frame(width: min(size.height * 0.4, 56), height: min(size.height * 0.4, 56))
                        if !showTitle {
                            Text(window.title).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                        }
                    }
                    .opacity(window.isMinimized ? 0.6 : 1)
                }
                if window.isMinimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2.weight(.bold)).padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                } else if window.onOtherSpace {
                    Image(systemName: "rectangle.3.group")
                        .font(.caption2.weight(.bold)).padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                        .help("On another Space")
                }
                if hovered {
                    HStack(spacing: 5) {
                        control("xmark", color: Color(hex: 0xFF5F57), action: onClose)
                        control("minus", color: Color(hex: 0xFEBC2E), action: onMinimize)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(7)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .white.opacity(hovered ? 0.35 : 0.1),
                                  lineWidth: selected ? 3 : 1)
            )
            .scaleEffect(selected ? 1.03 : 1)

            if showTitle {
                HStack(spacing: 5) {
                    if let icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text(window.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .frame(width: size.width, alignment: .center)
                .foregroundStyle(.primary.opacity(0.9))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { onHover($0) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func control(_ symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 16, height: 16)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock panel content

struct WindowPreviewDockPanelView: View {
    @ObservedObject var model: WindowPreviewPanelModel

    var body: some View {
        let content = Group {
            if model.vertical {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) { cards }.padding(14)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) { cards }.padding(14)
                }
            }
        }
        content
            .modifier(WindowPreviewGlass())
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .padding(14) // room for the shadow
            .scaleEffect(model.visible ? 1 : 0.9, anchor: model.anchor)
            .opacity(model.visible ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.visible)
    }

    @ViewBuilder private var cards: some View {
        ForEach(model.windows) { w in
            WindowPreviewCard(
                window: w, image: model.images[w.id], icon: model.icons[w.pid],
                size: model.thumbSize, showTitle: model.showTitles,
                selected: false, hovered: model.hoveredID == w.id,
                onActivate: { model.onActivate(w) },
                onClose: { model.onClose(w) },
                onMinimize: { model.onMinimize(w) },
                onHover: { h in
                    if h { model.hoveredID = w.id } else if model.hoveredID == w.id { model.hoveredID = nil }
                })
        }
    }
}
