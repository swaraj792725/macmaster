import SwiftUI
import AppKit

// MARK: - Layout constants

enum CBLayout {
    static let width: CGFloat = 680
    static let header: CGFloat = 60
    static let row: CGFloat = 46
    static let label: CGFloat = 26
    static let footer: CGFloat = 34
    static let maxRows = 8
    static let empty: CGFloat = 64

    static func height(rows: Int, hasLabel: Bool) -> CGFloat {
        if rows == 0 { return header + 1 + empty }
        return header + 1 + (hasLabel ? label : 0) + CGFloat(min(rows, maxRows)) * row + 8 + footer
    }
}

// MARK: - Model

@MainActor @Observable
final class CBModel {
    var query = ""
    var results: [CBResult] = []
    var selected = 0
    /// "Suggestions" for the empty query, or the scope name ("Clipboard") when a prefix narrowed the list.
    var label: String?

    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored var onLayout: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var base: [CBResult] = []
    @ObservationIgnored private var fileHits: [CBResult] = []
    @ObservationIgnored let files = CommandBarFiles()
    private static let noUsage: Set<CBKind> = [.calc, .web, .clipboard]

    init() {
        files.onResults = { [weak self] hits in
            guard let self else { return }
            self.fileHits = hits
            self.merge(resetSelection: false)
        }
    }

    /// Fresh state each time the bar opens.
    func reset() {
        files.cancel()
        fileHits = []
        query = ""
        field?.stringValue = ""
        let r = CommandBarProviders.shared.search("")
        base = r.results
        label = base.isEmpty ? nil : "Suggestions"
        merge(resetSelection: true)
    }

    func setQuery(_ q: String) {
        query = q
        fileHits = []
        files.update(q)
        let r = CommandBarProviders.shared.search(q)
        base = r.results
        label = r.scope ?? (q.trimmingCharacters(in: .whitespaces).isEmpty ? "Suggestions" : nil)
        merge(resetSelection: true)
    }

    private func merge(resetSelection: Bool) {
        var out = base
        let have = Set(out.map(\.id))
        for f in fileHits where !have.contains(f.id) { out.append(f) }
        results = out
        if resetSelection { selected = 0 } else { selected = min(selected, max(0, out.count - 1)) }
        onLayout?()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    func run(alt: Bool) {
        guard results.indices.contains(selected) else { return }
        run(results[selected], alt: alt)
    }

    func quickPick(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        run(results[index], alt: false)
    }

    private func run(_ r: CBResult, alt: Bool) {
        let action: @MainActor () -> Void
        if alt {
            guard let a = r.alt else { NSSound.beep(); return }
            action = a
        } else {
            action = r.perform
        }
        if !Self.noUsage.contains(r.kind) { CommandBarUsage.shared.record(id: r.id, query: query) }
        onClose?()
        // Let the panel go and focus return to the previous app first (paste actions need that).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { action() }
    }

    func close() { onClose?() }
}

// MARK: - Panel

final class CBPanel: NSPanel {
    var onQuickPick: ((Int) -> Void)?
    var onAlt: (() -> Void)?
    var onResign: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if flags == .command {
            if event.keyCode == 36 || event.keyCode == 76 { onAlt?(); return true }
            if let c = event.charactersIgnoringModifiers {
                if let d = Int(c), (1...9).contains(d) { onQuickPick?(d - 1); return true }
                switch c {
                case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
                case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
                case "w": onEscape?(); return true
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

// MARK: - Controller

@MainActor
final class CommandBarController {
    static let shared = CommandBarController()
    let model = CBModel()
    private var panel: CBPanel?
    private var topY: CGFloat = 0
    private var hiding = false

    var isVisible: Bool { panel?.isVisible ?? false }

    private init() {
        model.onLayout = { [weak self] in self?.resize() }
        model.onClose = { [weak self] in self?.hide() }
    }

    func toggle() { isVisible ? hide() : show() }

    func prewarm() { _ = ensurePanel() }

    func show() {
        guard CommandBarPrefs.enabled else { return }
        let p = ensurePanel()
        model.reset()
        let screen = Self.mouseScreen()
        let vf = screen.visibleFrame
        let h = Self.height(for: model)
        topY = vf.minY + vf.height * 0.78
        let x = vf.midX - CBLayout.width / 2
        p.setFrame(NSRect(x: x, y: topY - h, width: CBLayout.width, height: h), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        p.makeKey()
        if let f = model.field { p.makeFirstResponder(f) }
        CommandBarAppIndex.shared.refreshIfStale()
    }

    func hide() {
        guard let p = panel, p.isVisible, !hiding else { return }
        hiding = true
        model.files.cancel()
        p.orderOut(nil)
        hiding = false
    }

    private func resize() {
        guard let p = panel, p.isVisible else { return }
        let h = Self.height(for: model)
        var f = p.frame
        f.origin.y = topY - h
        f.size.height = h
        p.setFrame(f, display: true)
    }

    private static func height(for m: CBModel) -> CGFloat {
        CBLayout.height(rows: m.results.count, hasLabel: m.label != nil)
    }

    private static func mouseScreen() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func ensurePanel() -> CBPanel {
        if let panel { return panel }
        let h = CBLayout.height(rows: 6, hasLabel: true)
        let p = CBPanel(contentRect: NSRect(x: 0, y: 0, width: CBLayout.width, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.animationBehavior = .none
        p.title = "Command Bar"

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: CBLayout.width, height: h))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: CBRootView(model: model))
        host.sizingOptions = []
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect

        p.onQuickPick = { [weak self] i in self?.model.quickPick(i) }
        p.onAlt = { [weak self] in self?.model.run(alt: true) }
        p.onEscape = { [weak self] in self?.hide() }
        p.onResign = { [weak self] in
            // Defer: resignKey also fires while we are being ordered out, or when an action opens another window.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hide() } }
        }
        panel = p
        return p
    }
}

// MARK: - SwiftUI

struct CBRootView: View {
    var model: CBModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                CBSearchField(model: model)
                if let label = model.label, !model.query.isEmpty {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 20)
            .frame(height: CBLayout.header)

            if model.results.isEmpty {
                Divider().opacity(0.5)
                Text(model.query.isEmpty ? "Type to search" : "No results")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: CBLayout.empty)
            } else {
                Divider().opacity(0.5)
                if let label = model.label {
                    Text(label.uppercased())
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .frame(height: CBLayout.label, alignment: .bottom)
                        .padding(.bottom, 2)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, r in
                                CBRow(result: r, index: i, selected: i == model.selected)
                                    .id(r.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selected = i; model.run(alt: false) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selected) { _, new in
                        if model.results.indices.contains(new) { proxy.scrollTo(model.results[new].id) }
                    }
                }
                Spacer(minLength: 0)
                CBFooter(result: model.results.indices.contains(model.selected) ? model.results[model.selected] : nil)
            }
        }
        .frame(width: CBLayout.width)
    }
}

struct CBRow: View {
    let result: CBResult
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(result.kind.badge)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.8))
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 26, alignment: .trailing)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CBLayout.row)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.92))
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = result.iconPath {
            Image(nsImage: CBIcons.icon(forFile: path))
                .resizable().interpolation(.high)
                .frame(width: 30, height: 30)
        } else {
            IconTile(symbol: result.symbol, colors: result.colors, size: 30)
        }
    }
}

struct CBFooter: View {
    let result: CBResult?

    var body: some View {
        HStack(spacing: 14) {
            if let r = result {
                hint("↩", r.hint)
                if let alt = r.altHint { hint("⌘↩", alt) }
            }
            Spacer()
            hint("esc", "Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: CBLayout.footer)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text)
        }
    }
}

// MARK: - Search field

final class CBField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

struct CBSearchField: NSViewRepresentable {
    let model: CBModel

    func makeNSView(context: Context) -> CBField {
        let f = CBField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22, weight: .regular)
        f.placeholderString = "Search apps, actions, settings, or type a calculation"
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        model.field = f
        return f
    }

    func updateNSView(_ f: CBField, context: Context) {
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CBModel
        init(model: CBModel) { self.model = model }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            model.setQuery(f.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): model.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): model.move(1); return true
            case #selector(NSResponder.insertTab(_:)): model.move(1); return true
            case #selector(NSResponder.insertBacktab(_:)): model.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                let alt = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                model.run(alt: alt); return true
            case #selector(NSResponder.cancelOperation(_:)): model.close(); return true
            default: return false
            }
        }
    }
}

// MARK: - HUD

/// A small confirmation pill ("Copied 1024") that fades out by itself. Never takes focus.
@MainActor @Observable
private final class CBHUDModel {
    var text = ""
    var symbol = "checkmark.circle.fill"
}

private struct CBHUDView: View {
    var model: CBHUDModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SymbolKit.resolve(model.symbol))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 420)
    }
}

@MainActor
enum CommandBarHUD {
    private static let model = CBHUDModel()
    private static var panel: NSPanel?
    private static var hudHost: NSHostingView<CBHUDView>?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        guard !Services.isSnapshotRun else { return }
        model.text = text
        model.symbol = symbol
        let p = panel ?? makePanel()
        panel = p
        let host = hudHost
        let size = host?.fittingSize ?? NSSize(width: 260, height: 44)
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let w = max(120, min(size.width, 420)), h = max(36, size.height)
        p.setFrame(NSRect(x: vf.midX - w / 2, y: vf.minY + vf.height * 0.18, width: w, height: h), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideTask?.cancel()
        let life = min(4.5, 1.4 + Double(text.count) * 0.03)
        hideTask = Task {
            try? await Task.sleep(for: .seconds(life))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } }
            })
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none

        let host = NSHostingView(rootView: CBHUDView(model: model))
        hudHost = host
        host.sizingOptions = []
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        // Content view must be the hosting view for fittingSize; the blur sits behind it.
        host.autoresizingMask = [.width, .height]
        effect.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        effect.frame = container.bounds
        host.frame = container.bounds
        container.addSubview(effect)
        container.addSubview(host)
        p.contentView = container
        return p
    }
}
