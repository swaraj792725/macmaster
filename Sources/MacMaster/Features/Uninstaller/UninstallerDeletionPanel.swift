import SwiftUI
import AppKit
import Observation

// MARK: - Model

@Observable
@MainActor
final class UninstallerDeletionModel {
    enum Stage { case ready, removing, done(String) }

    let app: UninstallerApp
    let items: [UninstallerItem]
    let icon: NSImage
    let test: Bool
    var selection: Set<String>
    var stage: Stage = .ready
    @ObservationIgnored var close: () -> Void = {}

    init(app: UninstallerApp, icon: NSImage, items: [UninstallerItem], test: Bool) {
        self.app = app
        self.items = items
        self.icon = icon
        self.test = test
        // Only high-confidence, user-level items are ticked automatically.
        selection = Set(items.filter { $0.confidence == .high && !$0.requiresAdmin && !$0.isReceipt && !$0.launchSystemDomain }.map(\.id))
    }

    var selectedItems: [UninstallerItem] { items.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func toggle(_ id: String, _ on: Bool) {
        if on { selection.insert(id) } else { selection.remove(id) }
    }

    func remove() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        stage = .removing
        Task {
            // Always the Trash here; permanent deletion stays an explicit choice in the Uninstaller itself.
            let r = await Task.detached(priority: .userInitiated) {
                await UninstallerRemover.run(items: chosen, deleteImmediately: false) { _ in }
            }.value
            var text = "Moved \(r.removedCount) item\(r.removedCount == 1 ? "" : "s") to the Trash"
            if r.freed > 0 { text += " · \(ByteCountFormatter.string(fromByteCount: r.freed, countStyle: .file)) freed" }
            if let f = r.failures.first { text += "\n\(r.failures.count) failed: \(f.reason)" }
            stage = .done(text)
        }
    }
}

// MARK: - Panel controller

@MainActor
final class UninstallerDeletionPanelController: NSObject, NSWindowDelegate {
    private var panels: [String: NSPanel] = [:]

    func show(app: UninstallerApp, iconPath: String?, items: [UninstallerItem], test: Bool) {
        panels[app.bundleID]?.close()
        let path = iconPath ?? (FileManager.default.fileExists(atPath: app.url.path) ? app.url.path : nil)
        let icon = path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let model = UninstallerDeletionModel(app: app, icon: icon, items: items, test: test)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "\(app.name) was moved to the Trash"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: UninstallerDeletionView(model: model))
        model.close = { [weak panel] in panel?.close() }
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 20, y: vf.maxY - panel.frame.height - 20))
        } else {
            panel.center()
        }
        panels[app.bundleID] = panel
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSPanel else { return }
        panels = panels.filter { $0.value !== w }
    }
}

// MARK: - View

private struct UninstallerDeletionView: View {
    let model: UninstallerDeletionModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.stage {
            case .done(let text):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 38)).foregroundStyle(.green)
                    Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                Divider()
                HStack { Spacer(); Button("Done") { model.close() }.buttonStyle(.mmPrimary).keyboardShortcut(.defaultAction) }
                    .padding(12)
            default:
                list
                Divider()
                footer
            }
        }
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove \(model.app.name)'s leftovers?").font(.headline)
                Text("\(model.items.count) leftover file\(model.items.count == 1 ? "" : "s") found" + (model.test ? " (test mode)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder
    private var list: some View {
        if model.items.isEmpty {
            Text("No leftover files found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        UninstallerDeletionRow(item: item, on: model.selection.contains(item.id)) { model.toggle(item.id, $0) }
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .removing = model.stage {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(model.selection.count) selected · \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Keep") { model.close() }.buttonStyle(.mmSecondary).keyboardShortcut(.cancelAction)
            Button("Remove Selected") { model.remove() }
                .buttonStyle(.mmPrimary(tint: Color(hex: 0xFF3B30)))
                .keyboardShortcut(.defaultAction)
                .disabled(model.selection.isEmpty || { if case .removing = model.stage { true } else { false } }())
        }
        .padding(12)
    }
}

private struct UninstallerDeletionRow: View {
    let item: UninstallerItem
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { on }, set: set)).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: item.category.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Circle().fill(item.confidence.color).frame(width: 6, height: 6).help("\(item.confidence.title) confidence")
                    if item.requiresAdmin || item.isReceipt || item.launchSystemDomain {
                        Text("Admin").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(item.displayPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(item.isReceipt ? "" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { set(!on) }
    }
}
