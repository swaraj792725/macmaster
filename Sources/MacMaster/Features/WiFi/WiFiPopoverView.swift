import SwiftUI

/// Menu bar popover. Created on open and torn down on close, so nothing here costs anything while closed.
struct WiFiPopoverView: View {
    var onClose: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                WiFiHeroCard()
                WiFiHotspotCard()
                if WiFiModel.shared.link.isConnected {
                    WiFiThroughputCard()
                    WiFiAppTrafficCard(limit: 4)
                    WiFiDetailsCard(showsLink: false)
                    WiFiLatencyCard()
                    WiFiSpeedTestCard()
                }
                WiFiNetworksCard(limit: 8)
                WiFiActionsCard()
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: 384)
        .wifiPresence()
    }
}
