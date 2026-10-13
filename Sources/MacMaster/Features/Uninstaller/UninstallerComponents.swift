import AppKit
import SwiftUI

// MARK: - Icon cache

@MainActor
enum UninstallerIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct UninstallerAppIcon: View {
    let url: URL
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: UninstallerIcons.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Helpers

enum UninstallerReveal {
    static func reveal(_ url: URL) {
        let target = UninstallerPaths.exists(url) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

struct UninstallerConfidencePill: View {
    let confidence: UninstallerConfidence
    var body: some View {
        Text(confidence.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(confidence.color)
            .background(confidence.color.opacity(0.15), in: Capsule())
            .help("Match confidence: \(confidence.title)")
    }
}

/// Tri-state checkbox button.
struct UninstallerTriCheck: View {
    enum State { case on, off, mixed }
    let state: State
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
    }
    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }
}

// MARK: - Item row

struct UninstallerItemRow: View {
    let item: UninstallerItem
    @Binding var isOn: Bool
    var showModified = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: item.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                    if item.isBroken { badge("Broken", .red) }
                    if item.requiresAdmin || item.launchSystemDomain { badge("Admin", .orange) }
                }
                Text(item.isReceipt ? "Installer receipt" : item.displayPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(item.reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    UninstallerConfidencePill(confidence: item.confidence)
                    Text(item.isReceipt ? "—" : Fmt.bytes(item.size))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 58, alignment: .trailing)
                    if !item.isReceipt {
                        Button { UninstallerReveal.reveal(item.url) } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                    }
                }
                if showModified, let m = item.modified {
                    Text("Modified \(m.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color).background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - App row

struct UninstallerAppRow: View {
    let app: UninstallerApp
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            UninstallerAppIcon(url: app.url, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                    if running { Circle().fill(.green).frame(width: 6, height: 6).help("Running") }
                    if app.isSystem { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary).help("System app – cannot be removed") }
                }
                Text(lastUsedText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let s = app.size {
                Text(Fmt.bytes(s)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private var lastUsedText: String {
        guard let d = app.lastUsed else { return app.version.isEmpty ? "Never opened" : "v\(app.version) · never opened" }
        let rel = d.formatted(.relative(presentation: .named))
        return app.version.isEmpty ? "Used \(rel)" : "v\(app.version) · used \(rel)"
    }
}
