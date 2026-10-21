import SwiftUI

/// Scaffold: filled in by the Sound work package.
struct SoundView: View {
    var body: some View {
        Page {
            PageHeader(title: AppSection.sound.title, subtitle: AppSection.sound.blurb,
                       symbol: AppSection.sound.symbol, colors: AppSection.sound.colors)
            EmptyStateView(symbol: AppSection.sound.symbol, title: "Coming soon")
        }
    }
}
