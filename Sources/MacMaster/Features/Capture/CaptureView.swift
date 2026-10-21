import SwiftUI

/// Scaffold: filled in by the Capture work package.
struct CaptureView: View {
    var body: some View {
        Page {
            PageHeader(title: AppSection.capture.title, subtitle: AppSection.capture.blurb,
                       symbol: AppSection.capture.symbol, colors: AppSection.capture.colors)
            EmptyStateView(symbol: AppSection.capture.symbol, title: "Coming soon")
        }
    }
}
