import SwiftUI
import UniformTypeIdentifiers

/// The shelf UI: header, file tiles, drop target and stack actions.
struct DropShelfContentView: View {
    let model: DropShelfModel
    let controller: DropShelfPanelController
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                emptyBody
            } else {
                grid
                footer
            }
        }
        .frame(width: DropShelfLayout.width, height: DropShelfLayout.height(count: model.items.count), alignment: .top)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: targeted ? 2 : 0.5)
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in handleDrop(providers) }
        .animation(.smooth(duration: 0.2), value: model.items.count)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
            Text("Shelf").font(.system(size: 14, weight: .semibold))
            if model.items.count > 1 {
                Text("\(model.items.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            Spacer()
            Button { controller.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(DropShelfIconButtonStyle(size: 22))
            .help("Close shelf")
        }
        .padding(.horizontal, 14)
        .frame(height: DropShelfLayout.header)
    }

    private var emptyBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 30)).symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
            Text("Drop files here").font(.callout.weight(.medium))
            Text("Park them, then drag them out anywhere.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: DropShelfLayout.emptyBody - 20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(height: DropShelfLayout.emptyBody, alignment: .top)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DropShelfLayout.gap),
                                GridItem(.flexible(), spacing: DropShelfLayout.gap)],
                      spacing: DropShelfLayout.gap) {
                ForEach(model.items) { item in
                    DropShelfTile(item: item, model: model, controller: controller)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(height: DropShelfLayout.gridHeight(count: model.items.count))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            ZStack {
                Capsule().fill(Color.accentColor.opacity(0.16))
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                Label(model.notice ?? "Drag all (\(model.items.count))",
                      systemImage: model.notice == nil ? "square.stack.3d.up.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1).padding(.horizontal, 10)
                if model.notice == nil {
                    DropShelfDragSource(items: { model.items },
                                        onBegan: { model.internalDragActive = true },
                                        onEnded: { items, ok in finishDrag(items, ok) })
                        .clipShape(Capsule())
                }
            }
            .frame(height: 30)
            .help("Drag every item out at once")

            HStack(spacing: 4) {
                action("magnifyingglass", "Reveal in Finder") { controller.reveal() }
                action("doc.on.doc", "Copy") { controller.copyToPasteboard() }
                action("square.and.arrow.up", "Share") { controller.share() }
                Menu {
                    Button("Move to…") { controller.transfer(move: true) }
                    Button("Copy to…") { controller.transfer(move: false) }
                } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 26)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .help("Move or copy to a folder")
                Spacer(minLength: 0)
                Button("Clear") { model.clear() }
                    .buttonStyle(.mmGhost).help("Remove everything from the shelf (files are untouched)")
            }
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
        .frame(height: DropShelfLayout.footer, alignment: .top)
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 34, height: 26)
        }
        .buttonStyle(DropShelfIconButtonStyle(size: 26))
        .help(help)
    }

    // MARK: Drop / drag-out

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.internalDragActive else { return false }
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !wanted.isEmpty else { return false }
        model.pendingLoads += wanted.count
        for p in wanted {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                else if let u = item as? NSURL { url = u as URL }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        model.pendingLoads -= 1
                        if let url { model.add([url]) }
                        DropShelf.shared.noteShelfDrop()
                    }
                }
            }
        }
        return true
    }

    private func finishDrag(_ items: [DropShelfItem], _ accepted: Bool) {
        model.internalDragActive = false
        DropShelf.shared.resyncDragMonitor()
        if accepted { model.remove(items.map(\.url)) }
    }
}

/// One file: icon + name, drag source, remove button.
private struct DropShelfTile: View {
    let item: DropShelfItem
    let model: DropShelfModel
    let controller: DropShelfPanelController
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Image(nsImage: item.icon).resizable().interpolation(.high)
                    .frame(width: 48, height: 48)
                Text(item.name)
                    .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: DropShelfLayout.tile, maxHeight: DropShelfLayout.tile)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.10 : 0.05)))

            DropShelfDragSource(items: { [item] },
                                onBegan: { model.internalDragActive = true },
                                onEnded: { done, ok in
                                    model.internalDragActive = false
                                    DropShelf.shared.resyncDragMonitor()
                                    if ok { model.remove(done.map(\.url)) }
                                },
                                onOpen: { NSWorkspace.shared.open(item.url) })

            Button { model.remove(id: item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(hover ? 1 : 0.35)
            .help("Remove from shelf")
        }
        .onHover { hover = $0 }
        .help(item.url.path)
    }
}

/// Small round hover-wash button used for shelf chrome.
private struct DropShelfIconButtonStyle: ButtonStyle {
    var size: CGFloat
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(0.8))
            .frame(minWidth: size, minHeight: size)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hover ? 0.09 : 0))))
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}
