import SwiftUI

/// Simple wrapping layout for feature chips.
struct PermissionsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowH), frames)
    }
}

private struct PermissionsChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// One permission: icon, status, explanation, unlocked features and the action button.
/// `compact` is used by onboarding (smaller, no feature chips).
struct PermissionsRow: View {
    let permission: Permission
    let granted: Bool
    var compact = false
    var note: String? = nil
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: permission.symbol, colors: granted ? Theme.Palette.green : permission.colors,
                     size: compact ? 36 : 44)
                .overlay(alignment: .bottomTrailing) {
                    if granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: compact ? 13 : 16))
                            .foregroundStyle(.white, Color(hex: 0x28B84A))
                            .background(Circle().fill(.background).padding(2))
                            .offset(x: 4, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                HStack(spacing: 8) {
                    Text(permission.title).font(.system(size: compact ? 14 : 16, weight: .semibold))
                    Text(permission.isRequired ? "Recommended" : "Optional")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    if !compact {
                        StatusPill(text: granted ? "Granted" : "Missing",
                                   color: granted ? Color(hex: 0x30D158) : Color(hex: 0xFF9F0A))
                    }
                }
                Text(permission.blurb)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(Color(hex: 0xFF9F0A))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !compact {
                    PermissionsFlowLayout(spacing: 6) {
                        ForEach(permission.features, id: \.self) { PermissionsChip(text: $0) }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        if granted {
            if compact {
                StatusPill(text: "Granted", color: Color(hex: 0x30D158))
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                if compact { StatusPill(text: "Missing", color: Color(hex: 0xFF9F0A)) }
                Button(note != nil && permission == .accessibility ? "Fix" : permission.actionTitle, action: onRequest)
                    .buttonStyle(.mmPrimary)
            }
        }
    }
}
