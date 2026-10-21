import SwiftUI

/// Scaffold: filled in by the App Updates work package.
struct AppUpdatesView: View {
    var body: some View {
        Page {
            PageHeader(title: AppSection.updates.title, subtitle: AppSection.updates.blurb,
                       symbol: AppSection.updates.symbol, colors: AppSection.updates.colors)
            EmptyStateView(symbol: AppSection.updates.symbol, title: "Coming soon")
        }
    }
}
