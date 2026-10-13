import SwiftUI

/// One result in the sidebar search list: icon, title, breadcrumb path.
struct SearchResultRow: View {
    let entry: SearchEntry
    var highlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: entry.opensAppSettings ? "gearshape.fill" : entry.section.symbol,
                     colors: entry.opensAppSettings ? Theme.Palette.gray : entry.section.colors, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body).lineLimit(1)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(highlighted ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .help(entry.path)
    }
}

/// The result list shown in place of the grouped sidebar while a query is typed.
struct SearchResultsSection: View {
    let query: String
    let results: [SearchEntry]
    let highlightedIndex: Int
    var onOpen: (SearchEntry) -> Void

    var body: some View {
        if results.isEmpty {
            Text("No results for “\(query)”")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
                .selectionDisabled()
        } else {
            Section("Results") {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, entry in
                    Button { onOpen(entry) } label: {
                        SearchResultRow(entry: entry, highlighted: i == highlightedIndex)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                }
            }
        }
    }
}
