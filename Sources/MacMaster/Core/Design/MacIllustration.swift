import SwiftUI

/// Light-weight vector Mac illustration (laptop or desktop display) for hero areas.
struct MacIllustration: View {
    var isLaptop: Bool = true
    var width: CGFloat = 150
    var wallpaper: [Color] = [Color(hex: 0x5E5CE6), Color(hex: 0x0A84FF), Color(hex: 0x64D2FF)]

    var body: some View {
        let screenW = width * 0.84
        let screenH = screenW * 0.64
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: width * 0.045, style: .continuous)
                    .fill(Color(hex: 0x1C1C1E))
                RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(width * 0.014)
                // soft glow blob
                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: screenH * 0.9)
                    .blur(radius: 14)
                    .offset(x: screenW * 0.18, y: -screenH * 0.2)
                    .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
                    .padding(width * 0.014)
                if isLaptop {
                    Capsule().fill(.black.opacity(0.9))
                        .frame(width: width * 0.07, height: width * 0.016)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, width * 0.02)
                }
            }
            .frame(width: screenW, height: screenH)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            if isLaptop {
                RoundedRectangle(cornerRadius: width * 0.02, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xE5E5EA), Color(hex: 0xB8B8BF)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: width, height: width * 0.05)
                    .padding(.top, -1)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xD1D1D6), Color(hex: 0x9A9AA0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.12, height: width * 0.14)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(hex: 0xC7C7CC))
                    .frame(width: width * 0.36, height: width * 0.028)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

/// Describes this Mac for display: marketing-ish form factor derived from the model identifier.
enum MacIdentity {
    /// True for MacBook identifiers and for any Mac that reports an internal battery.
    static func isLaptop(modelIdentifier: String, hasBattery: Bool) -> Bool {
        if hasBattery { return true }
        return modelIdentifier.lowercased().contains("book")
    }

    /// SF Symbol for the Mac family.
    static func symbol(modelIdentifier: String, hasBattery: Bool) -> String {
        let m = modelIdentifier.lowercased()
        if hasBattery || m.contains("book") { return SymbolKit.firstAvailable(["laptopcomputer", "macbook"]) }
        if m.contains("macmini") || m.contains("mac mini") { return SymbolKit.firstAvailable(["macmini.fill", "macmini", "desktopcomputer"]) }
        if m.contains("macstudio") { return SymbolKit.firstAvailable(["macstudio.fill", "macstudio", "desktopcomputer"]) }
        if m.contains("imac") { return "desktopcomputer" }
        return "desktopcomputer"
    }
}
