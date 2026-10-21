import SwiftUI

/// Scaffold: filled in by the Command Bar work package.
struct CommandBarView: View {
    var body: some View {
        Page {
            PageHeader(title: AppSection.commandbar.title, subtitle: AppSection.commandbar.blurb,
                       symbol: AppSection.commandbar.symbol, colors: AppSection.commandbar.colors)
            EmptyStateView(symbol: AppSection.commandbar.symbol, title: "Coming soon")
        }
    }
}
