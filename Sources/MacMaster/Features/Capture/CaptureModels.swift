import SwiftUI
import AppKit

/// Wraps a `CGImage` so it can cross task boundaries (CGImage is immutable once created).
struct CaptureImage: @unchecked Sendable {
    let cg: CGImage
    /// Pixels per point of the screen the image came from.
    var scale: CGFloat
    var size: CGSize { CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale) }
}

// MARK: - Preferences

/// UserDefaults keys and typed reads. The page uses `@AppStorage` with the same keys.
enum CapturePrefs {
    static let keepLineBreaks = "mm.capture.keepLineBreaks"
    static let detectCodes = "mm.capture.detectCodes"
    static let sound = "mm.capture.sound"
    static let languageMode = "mm.capture.languageMode"   // "auto" | "preferred"
    static let saveFolder = "mm.capture.saveFolder"
    static let afterShot = "mm.capture.afterShot"
    static let menuBar = "mm.capture.menuBar"
    static let colorFormat = "mm.capture.colorFormat"
    static let colorHistory = "mm.capture.colors"
    static let contrastText = "mm.capture.contrastText"
    static let contrastBackground = "mm.capture.contrastBackground"

    static func hotKeyKey(_ a: CaptureAction) -> String { "mm.capture.hotkey.\(a.rawValue)" }

    static var keepBreaks: Bool { bool(keepLineBreaks, true) }
    static var alsoCodes: Bool { bool(detectCodes, false) }
    static var playSound: Bool { bool(sound, true) }
    static var preferredLanguages: Bool { UserDefaults.standard.string(forKey: languageMode) == "preferred" }
    static var after: AfterShot { AfterShot(rawValue: UserDefaults.standard.string(forKey: afterShot) ?? "") ?? .copy }
    static var format: ColorFormat { ColorFormat(rawValue: UserDefaults.standard.string(forKey: colorFormat) ?? "") ?? .hex }

    /// Folder screenshots are saved in (default Desktop).
    static var saveFolderURL: URL {
        if let p = UserDefaults.standard.string(forKey: saveFolder), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop", isDirectory: true)
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }
}

enum CaptureAction: String, CaseIterable, Identifiable {
    case text, code, color, shot, pin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "Capture Text"
        case .code: "Scan Code"
        case .color: "Pick Color"
        case .shot: "Screenshot"
        case .pin: "Pin Last Screenshot"
        }
    }
    var hotKeyName: String { "capture.\(rawValue)" }
}

enum AfterShot: String, CaseIterable, Identifiable {
    case copy, save, both, pin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: "Copy to clipboard"
        case .save: "Save to folder"
        case .both: "Copy and save"
        case .pin: "Pin to screen"
        }
    }
}

// MARK: - Color

enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, hsl, swiftUI, nsColor, css
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .swiftUI: "SwiftUI"
        case .nsColor: "NSColor"
        case .css: "CSS rgb()"
        }
    }
}

/// An sRGB color, stored as 8-bit channels so it round-trips through a hex string.
struct PickedColor: Hashable, Identifiable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8
    var id: String { hex }

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        func ch(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: ch(c.redComponent), g: ch(c.greenComponent), b: ch(c.blueComponent))
    }

    /// Parses "#RRGGBB" / "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1) }

    var hsl: (h: Int, s: Int, l: Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        let d = mx - mn
        if d > 0 {
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case rf: h = (gf - bf) / d + (gf < bf ? 6 : 0)
            case gf: h = (bf - rf) / d + 2
            default: h = (rf - gf) / d + 4
            }
            h *= 60
        }
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    func string(_ f: ColorFormat) -> String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        switch f {
        case .hex: return hex
        case .rgb: return "rgb(\(r), \(g), \(b))"
        case .hsl: let v = hsl; return "hsl(\(v.h), \(v.s)%, \(v.l)%)"
        case .swiftUI: return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", rf, gf, bf)
        case .nsColor: return String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)", rf, gf, bf)
        case .css: return "rgb(\(r) \(g) \(b))"
        }
    }

    // MARK: WCAG

    /// Relative luminance per WCAG 2.x.
    var luminance: Double {
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: PickedColor, _ b: PickedColor) -> Double {
        let l1 = max(a.luminance, b.luminance), l2 = min(a.luminance, b.luminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

// MARK: - Recent items

struct CaptureRecent: Identifiable, Hashable {
    enum Kind { case text, code }
    let id = UUID()
    let kind: Kind
    let text: String
    let date: Date
    var isURL: Bool { CaptureRecent.url(from: text) != nil }

    var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }

    /// A web URL, if `s` is exactly one.
    static func url(from s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), let u = URL(string: t),
              let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return nil }
        return u
    }
}

enum CaptureText {
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
