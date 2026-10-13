import SwiftUI
import AppKit

struct CleanerCategoryRow: View {
    let id: CleanerCategoryID
    @Binding var expanded: Set<CleanerCategoryID>
    private let engine = CleanerEngine.shared
    private let maxShown = 25

    var body: some View {
        let items = engine.items(id)
        let isOpen = expanded.contains(id)
        let done = engine.finished.contains(id) || engine.phase != .scanning
        let selectable = items.contains(where: \.isSelectable)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CleanerCheckbox(state: engine.selectionState(id), enabled: selectable) {
                    let on = engine.selectionState(id) != .on
                    engine.setCategory(id, on: on)
                }
                IconTile(symbol: id.symbol, colors: id.colors, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(id.title).font(.headline)
                        CleanerSafetyPill(safety: id.safety)
                    }
                    Text(id.warning ?? id.summary)
                        .font(.caption).foregroundStyle(id.warning == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if !done {
                    ProgressView().controlSize(.small)
                } else {
                    Text(items.isEmpty ? "Clean" : Fmt.bytes(engine.total(id)))
                        .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(items.isEmpty ? .secondary : .primary)
                }
                if !items.isEmpty {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !items.isEmpty else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    if isOpen { expanded.remove(id) } else { expanded.insert(id) }
                }
            }

            if isOpen && !items.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(items.prefix(maxShown)) { item in CleanerItemRow(item: item) }
                    if items.count > maxShown {
                        let rest = items.dropFirst(maxShown)
                        Text("and \(rest.count) more (\(Fmt.bytes(rest.reduce(0) { $0 + $1.size }))) — selected with the category")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(.background.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

struct CleanerSafetyPill: View {
    let safety: CleanerSafety
    var body: some View {
        Text(safety.title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(safety.color.opacity(0.16), in: Capsule())
            .foregroundStyle(safety.color)
    }
}

struct CleanerItemRow: View {
    let item: CleanerItem
    private let engine = CleanerEngine.shared

    var body: some View {
        HStack(spacing: 10) {
            CleanerCheckbox(state: engine.selected.contains(item.id) && item.isSelectable ? .on : .off,
                            enabled: item.isSelectable) { engine.toggle(item) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Group {
                    if let reason = item.blockedReason {
                        Text(reason).foregroundStyle(.orange)
                    } else if let d = item.detail {
                        Text(d)
                    } else if let u = item.primaryURL {
                        Text(CleanerFormat.abbreviatedPath(u))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.action == .info, let u = item.primaryURL {
                Button("Open Folder") { NSWorkspace.shared.open(u) }.controlSize(.small)
            }
            if item.size > 0 {
                Text(Fmt.bytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            } else if item.isSelectable {
                Text("—").foregroundStyle(.tertiary)
            }
            if !item.urls.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(item.urls.filter { FileManager.default.fileExists(atPath: $0.path) })
                } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}
