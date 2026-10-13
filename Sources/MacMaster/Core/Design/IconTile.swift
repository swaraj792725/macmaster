import SwiftUI
import AppKit

// MARK: - Symbol safety

/// Resolves SF Symbol names, falling back when a symbol does not exist on the running OS.
enum SymbolKit {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        cache[name] = ok
        return ok
    }

    /// First candidate that exists, else `fallback`.
    static func resolve(_ name: String, fallback: String = "square.dashed") -> String {
        exists(name) ? name : fallback
    }

    /// First existing name from a list of candidates (newest first).
    static func firstAvailable(_ names: [String], fallback: String = "square.dashed") -> String {
        names.first(where: exists) ?? fallback
    }
}

// MARK: - Icon tile

enum IconTileStyle {
    /// Solid gradient squircle with white glyph (System Settings).
    case filled
    /// Soft hue-tinted squircle with a hue-colored glyph.
    case tinted
    /// Just the glyph, painted with the hue gradient.
    case plain
}

/// macOS System Settings style icon: continuous squircle, top-to-bottom hue gradient,
/// inner highlight, hairline stroke, crisp white SF Symbol and a gentle shadow.
struct IconTile: View {
    let symbol: String
    var colors: [Color] = Theme.Palette.neutral
    var size: CGFloat = 28
    var style: IconTileStyle = .filled

    private var top: Color { colors.first ?? .gray }
    private var bottom: Color { colors.last ?? .gray }
    private var radius: CGFloat { size * 0.225 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            switch style {
            case .filled: filled(shape)
            case .tinted: tinted(shape)
            case .plain: glyph(.hue).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private enum GlyphPaint { case white, hue }

    private func glyph(_ paint: GlyphPaint) -> some View {
        let font = Font.system(size: size * 0.5, weight: .semibold)
        return Text(Image(systemName: SymbolKit.resolve(symbol)))
            .font(font)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(width: size * 0.76, height: size * 0.76)
            .foregroundStyle(paint == .white
                             ? AnyShapeStyle(.white)
                             : AnyShapeStyle(Theme.verticalGradient([top, bottom])))
    }

    private func filled(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(Theme.verticalGradient([top, bottom]))
            // soft top highlight
            shape.fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
            glyph(.white)
                .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.02)
        }
        .overlay(
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .black.opacity(0.14)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.5)
        )
        .shadow(color: size >= 30 ? bottom.opacity(0.28) : .black.opacity(0.12),
                radius: size >= 30 ? size * 0.09 : 0.8,
                y: size >= 30 ? size * 0.045 : 0.5)
    }

    private func tinted(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(bottom.opacity(0.16))
            glyph(.hue)
        }
        .overlay(shape.strokeBorder(bottom.opacity(0.22), lineWidth: 0.5))
    }
}
