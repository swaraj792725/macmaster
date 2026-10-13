import SwiftUI
import AppKit
import QuickLookThumbnailing
import QuickLookUI

/// Popover content: every parked item with a thumbnail, drag-out, Quick Look and remove.
struct DropShelfPopoverView: View {
    let model: DropShelfModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.items) { DropShelfPopoverRow(item: $0, model: model, onClose: onClose) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 330)
                Divider()
                footer
            }
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
            Text("Drop Shelf").font(.headline)
            if !model.items.isEmpty {
                Text("\(model.items.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            Spacer()
            Button {
                if !DropShelf.shared.addFromPasteboard() { NSSound.beep() }
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.mmGhost).help("Add what is on the clipboard (files, image or text)")
            Button("Open shelf") { onClose(); DropShelf.shared.openNow() }
                .buttonStyle(.mmSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28)).symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
            Text("Nothing on the shelf").font(.callout.weight(.medium))
            Text("Drop files, images or text on the menu bar icon, or use Paste.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Drag a row out to drop it anywhere.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Clear all") { model.clear() }
                .buttonStyle(.mmGhost).help("Remove everything from the shelf (files are untouched)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct DropShelfPopoverRow: View {
    let item: DropShelfItem
    let model: DropShelfModel
    let onClose: () -> Void
    @State private var hover = false
    @State private var thumb: NSImage?
    @State private var detail = ""

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                Image(nsImage: thumb ?? item.icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))

            DropShelfDragSource(items: { [item] },
                                onBegan: { model.internalDragActive = true },
                                onEnded: { done, ok in
                                    model.internalDragActive = false
                                    DropShelf.shared.resyncDragMonitor()
                                    if ok { model.remove(done.map(\.url)) }
                                },
                                onOpen: { NSWorkspace.shared.open(item.url) })

            if hover {
                HStack(spacing: 10) {
                    Button { onClose(); DropShelfQuickLook.shared.show(item.url, among: model.urls) } label: { Image(systemName: "eye") }
                        .help("Quick Look")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Reveal in Finder")
                    Button { model.remove(id: item.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .help("Remove from shelf")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.trailing, 6)
            }
        }
        .onHover { hover = $0 }
        .help(item.url.path)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        let url = item.url
        let info = await Task.detached(priority: .utility) { () -> String in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .localizedTypeDescriptionKey])
            var parts: [String] = []
            if let t = v?.localizedTypeDescription { parts.append(t) }
            if v?.isDirectory != true, let n = v?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)) }
            return parts.joined(separator: " \u{00B7} ")
        }.value
        detail = info
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 36), scale: 2, representationTypes: .all)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = rep.nsImage }
    }
}

/// Quick Look for shelf items. The panel's data source is set directly; the preview opens in the
/// regular Quick Look window (Space/arrow keys step through the shelf).
@MainActor
final class DropShelfQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = DropShelfQuickLook()
    private var urls: [URL] = []

    func show(_ url: URL, among all: [URL]) {
        urls = all.isEmpty ? [url] : all
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: url) ?? 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { index >= 0 && index < urls.count ? urls[index] as NSURL : nil }
    }
}
