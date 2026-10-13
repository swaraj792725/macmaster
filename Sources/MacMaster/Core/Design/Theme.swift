import SwiftUI

/// Central design tokens. Every feature uses these so the app feels like one product.
enum Theme {
    /// Liquid Glass can't be captured by `cacheDisplay`; debug snapshots fall back to material.
    static let glassEnabled = ProcessInfo.processInfo.environment["MM_SNAPSHOT_DIR"] == nil

    static let cornerRadius: CGFloat = 14
    static let smallRadius: CGFloat = 10
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 24

    /// Radius scale (continuous corners everywhere).
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let card: CGFloat = 14
        static let hero: CGFloat = 20
    }

    /// Spacing scale.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Accent gradients. Each is `[lighter top, base bottom]` in System Settings hues,
    /// so `IconTile` and gauges get the familiar macOS look.
    enum Palette {
        // System Settings hues
        static let blue    = [Color(hex: 0x4DA3FF), Color(hex: 0x0A7AFF)]
        static let green   = [Color(hex: 0x5FDB78), Color(hex: 0x28B84A)]
        static let orange  = [Color(hex: 0xFFB340), Color(hex: 0xFF8A00)]
        static let red     = [Color(hex: 0xFF6B62), Color(hex: 0xFF3B30)]
        static let purple  = [Color(hex: 0xC77DEB), Color(hex: 0xAF52DE)]
        static let pink    = [Color(hex: 0xFF6B8E), Color(hex: 0xFF2D55)]
        static let gray    = [Color(hex: 0xA5A5AB), Color(hex: 0x76767C)]
        static let teal    = [Color(hex: 0x6AD4EC), Color(hex: 0x30B0C7)]
        static let indigo  = [Color(hex: 0x7D7AFF), Color(hex: 0x5856D6)]
        static let yellow  = [Color(hex: 0xFFDD55), Color(hex: 0xFFC400)]
        static let mint    = [Color(hex: 0x6EE0C6), Color(hex: 0x00C7BE)]

        // Feature areas
        static let uninstaller = red
        static let cleaner     = teal
        static let battery     = green
        static let stats       = indigo
        static let health      = pink
        static let mouse       = gray
        static let windows     = purple
        static let tools       = orange
        static let dashboard   = blue
        static let neutral     = gray

        // Single metric colors
        static let cpu     = Color(hex: 0x0A84FF)
        static let memory  = Color(hex: 0xBF5AF2)
        static let disk    = Color(hex: 0xFF9F0A)
        static let network = Color(hex: 0x30D158)
        static let gpu     = Color(hex: 0xFF375F)
        static let thermal = Color(hex: 0xFF6A3D)
    }

    /// Level → color used for gauges and status (good / warn / bad).
    static func levelColor(_ fraction: Double, warn: Double = 0.7, critical: Double = 0.9) -> Color {
        if fraction >= critical { return Color(hex: 0xFF453A) }
        if fraction >= warn { return Color(hex: 0xFF9F0A) }
        return Color(hex: 0x30D158)
    }

    static func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Top → bottom gradient, as used by System Settings icons.
    static func verticalGradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors.isEmpty ? [.gray] : colors, startPoint: .top, endPoint: .bottom)
    }

    /// Card fill: near-white in light mode, a faint lift in dark mode.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 1, alpha: 0.78)
    })

    /// Hairline stroke / separator color for both appearances.
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0, alpha: 0.07)
    })
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// Mix toward white (amount 0…1).
    func lighter(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let a = max(0, min(1, amount))
        return Color(.sRGB,
                     red: Double(ns.redComponent) + (1 - Double(ns.redComponent)) * a,
                     green: Double(ns.greenComponent) + (1 - Double(ns.greenComponent)) * a,
                     blue: Double(ns.blueComponent) + (1 - Double(ns.blueComponent)) * a,
                     opacity: Double(ns.alphaComponent))
    }

    /// Mix toward black (amount 0…1).
    func darker(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let f = 1 - max(0, min(1, amount))
        return Color(.sRGB,
                     red: Double(ns.redComponent) * f,
                     green: Double(ns.greenComponent) * f,
                     blue: Double(ns.blueComponent) * f,
                     opacity: Double(ns.alphaComponent))
    }
}

// MARK: - Formatting helpers

enum Fmt {
    /// "1 item", "3 items".
    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    // Formatters are thread-safe for formatting; reuse them instead of building one per call.
    nonisolated(unsafe) private static let fileFormatter = makeByteFormatter(.file)
    nonisolated(unsafe) private static let decimalFormatter = makeByteFormatter(.decimal)
    private static func makeByteFormatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f
    }

    static func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        switch style {
        case .file: fileFormatter.string(fromByteCount: value)
        case .decimal: decimalFormatter.string(fromByteCount: value)
        default: ByteCountFormatter.string(fromByteCount: value, countStyle: style)
        }
    }
    static func bytes(_ value: UInt64) -> String { bytes(Int64(clamping: value)) }
    /// RAM in binary units, so 16 GiB reads "16 GB" like About This Mac (not "17.18 GB").
    static func memory(_ value: UInt64) -> String { bytes(Int64(clamping: value), style: .memory) }

    /// Throughput like "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond)), style: .decimal) + "/s"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", fraction * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.0f°C", celsius)
    }
}
