import SwiftUI
import AppKit
import QuickLookThumbnailing
import QuickLookUI

/// Popover content: every parked item with a thumbnail, drag-out, Quick Look and remove.
/// The whole popover is a drop zone (files, images, text, links).
struct DropShelfPopoverView: View {
    let model: DropShelfModel
    let onClose: () -> Void
    @State private var targeted = false

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
        .frame(width: 340)
        .overlay { dropHighlight }
        .onDrop(of: DropShelf.dropTypes, isTargeted: $targeted) { DropShelf.shared.addFromProviders($0) }
        .animation(.smooth(duration: 0.18), value: targeted)
        .animation(.smooth(duration: 0.2), value: model.items.count)
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
            Spacer(minLength: 4)
            Button {
                if !DropShelf.shared.addFromPasteboard() { NSSound.beep() }
            } label: { Label("Paste", systemImage: "doc.on.clipboard").contentShape(Capsule()) }
                .buttonStyle(.mmGhost).help("Add what is on the clipboard (files, image or text)")
            Button { onClose(); DropShelf.shared.openNow() } label: { Text("Open shelf").contentShape(Capsule()) }
                .buttonStyle(.mmSecondary).help("Open the floating shelf next to the cursor")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "arrow.down.doc")
                .font(.system(size: 30)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.6))
            Text(targeted ? "Release to add" : "Drop files here").font(.callout.weight(.medium))
            Text("Files, images, text or links. Drop them here or on the menu bar icon, or use Paste.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Color.accentColor.opacity(targeted ? 0.10 : 0)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4])))
        .padding(12)
    }

    /// Accent ring + hint while something is dragged over a non-empty shelf.
    @ViewBuilder private var dropHighlight: some View {
        if targeted && !model.items.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                Label("Drop to add", systemImage: "tray.and.arrow.down.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(3).allowsHitTesting(false).transition(.opacity)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.notice ?? "Drag a row out to drop it anywhere.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { model.clear() } label: { Text("Clear all").contentShape(Capsule()) }
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
        HStack(spacing: 0) {
            // The drag source covers only this part so it never sits over the buttons.
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
            .padding(.leading, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .overlay {
                DropShelfDragSource(items: { [item] },
                                    onBegan: { model.internalDragActive = true },
                                    onEnded: { done, ok in
                                        model.internalDragActive = false
                                        DropShelf.shared.resyncDragMonitor()
                                        if ok { model.remove(done.map(\.url)) }
                                    },
                                    onOpen: { NSWorkspace.shared.open(item.url) })
            }

            if hover {
                HStack(spacing: 2) {
                    rowButton("eye", "Quick Look") { onClose(); DropShelfQuickLook.shared.show(item.url, among: model.urls) }
                    rowButton("magnifyingglass", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    rowButton("xmark.circle.fill", "Remove from shelf") { model.remove(id: item.id) }
                }
                .padding(.horizontal, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        .onHover { hover = $0 }
        .help(item.url.path)
        .task(id: item.id) { await load() }
    }

    private func rowButton(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
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
