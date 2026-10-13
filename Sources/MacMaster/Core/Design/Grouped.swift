import SwiftUI

// MARK: - Hairline

/// 0.5pt separator that matches the grouped card style.
struct HairlineDivider: View {
    var leadingInset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Grouped section

/// Inset grouped list container (System Settings style): optional header, rounded card,
/// hairline separators between rows, optional footer. Put `SettingsRow`s (or any views) inside.
struct GroupedSection<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var footer: String? = nil
    /// Row horizontal padding. Separators are inset by this amount.
    var rowInset: CGFloat = 14
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, symbol: String? = nil, footer: String? = nil,
         rowInset: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.footer = footer
        self.rowInset = rowInset; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: SymbolKit.resolve(symbol)).font(.system(size: 12, weight: .semibold))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            _VariadicView.Tree(GroupedRowsLayout(inset: rowInset)) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardFill, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
                .clipShape(shape)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lays out children vertically, inserting hairlines between them.
private struct GroupedRowsLayout: _VariadicView_UnaryViewRoot {
    var inset: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(.horizontal, inset)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if child.id != last { HairlineDivider(leadingInset: inset) }
            }
        }
    }
}

// MARK: - Settings row

/// Row for `GroupedSection`: optional icon tile, title + subtitle, trailing control or value.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var colors: [Color] = Theme.Palette.gray
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, symbol: String? = nil, colors: [Color] = Theme.Palette.gray,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.colors = colors; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if let symbol { IconTile(symbol: symbol, colors: colors, size: 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: 28)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, colors: [Color] = Theme.Palette.gray) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, colors: colors) { EmptyView() }
    }
}

extension SettingsRow where Trailing == SettingsRowValue {
    /// Row with a right-aligned secondary value (`monospacedDigit`).
    init(title: String, value: String, subtitle: String? = nil, symbol: String? = nil,
         colors: [Color] = Theme.Palette.gray) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, colors: colors) { SettingsRowValue(text: value) }
    }
}

struct SettingsRowValue: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}
