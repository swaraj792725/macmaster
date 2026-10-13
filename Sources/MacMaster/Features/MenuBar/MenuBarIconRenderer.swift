import AppKit
import SwiftUI

/// Draws the status-bar icon. All images are drawn with a drawing handler so they stay crisp on retina.
@MainActor
enum MenuBarIconRenderer {
    nonisolated static let height: CGFloat = 18

    /// Image for the stored/explicit style. Live styles read current monitor values.
    static func image(style: MenuBarIconStyle) -> NSImage {
        switch style {
        case .logo: return logoImage()
        case .health: return healthImage()
        case .cpu: return cpuImage()
        case .text: return textImage(metric: MenuBarPrefs.textMetric)
        }
    }

    /// Template logo only (also used for the popover header tile).
    static func logoImage(size: CGFloat = height) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.set()
            drawLogo(in: rect)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "MacMaster"
        return img
    }

    // MARK: Styles

    private static func cpuImage() -> NSImage {
        let load = min(max(SystemMonitor.shared.cpu.total, 0), 1)
        let logoW = height, gap: CGFloat = 3, barW: CGFloat = 4
        let size = NSSize(width: logoW + gap + barW, height: height)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            drawLogo(in: NSRect(x: 0, y: 0, width: logoW, height: height))
            let track = NSRect(x: logoW + gap, y: 2, width: barW, height: height - 4)
            NSColor.black.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: track, xRadius: barW / 2, yRadius: barW / 2).fill()
            let fillH = max(barW, track.height * CGFloat(load))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: barW, height: fillH),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "MacMaster, CPU \(Int(load * 100)) percent"
        return img
    }

    private static func healthImage() -> NSImage {
        let score = HealthMonitor.shared.score
        let color: NSColor = score >= 80 ? .systemGreen : score >= 60 ? .systemOrange : .systemRed
        let size = NSSize(width: height + 3, height: height)
        // Non-template: logo drawn in the dynamic label color, resolved when drawn.
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.set()
            drawLogo(in: NSRect(x: 0, y: 0, width: height, height: height))
            let d: CGFloat = 7
            let dot = NSRect(x: size.width - d, y: 0.5, width: d, height: d)
            // Knock a halo out of the logo so the dot reads cleanly.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.4, dy: -1.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "MacMaster, health \(score)"
        return img
    }

    private static func textImage(metric: MenuBarTextMetric) -> NSImage {
        let value: Int
        switch metric {
        case .cpu: value = Int((SystemMonitor.shared.cpu.total * 100).rounded())
        case .memory: value = Int((SystemMonitor.shared.memory.usedFraction * 100).rounded())
        case .gpu: value = Int((SystemMonitor.shared.gpu * 100).rounded())
        case .battery: value = Int((BatteryMonitor.shared.reading.percent * 100).rounded())
        case .health: value = HealthMonitor.shared.score
        }
        let text = metric == .health ? "\(value)" : "\(min(max(value, 0), 999))%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let str = NSAttributedString(string: text, attributes: attrs)
        let w = ceil(str.size().width) + 2
        let img = NSImage(size: NSSize(width: w, height: height), flipped: false) { rect in
            let s = str.size()
            str.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "MacMaster \(metric.title) \(text)"
        return img
    }

    // MARK: Logo geometry

    /// Rounded-square outline, a bold "M" and a sparkle in the top-right corner. Draws in the current fill color.
    nonisolated private static func drawLogo(in rect: NSRect) {
        let u = rect.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * u, y: rect.minY + y * u) }

        // Rounded square outline
        let box = NSRect(x: rect.minX + 1.2 * u, y: rect.minY + 1.2 * u, width: 15.6 * u, height: 15.6 * u)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.7 * u, dy: 0.7 * u), xRadius: 4.6 * u, yRadius: 4.6 * u)
        outline.lineWidth = 1.5 * u
        outline.stroke()

        // "M"
        let m = NSBezierPath()
        m.move(to: p(4.9, 4.9))
        m.line(to: p(4.9, 12.2))
        m.line(to: p(9, 7.4))
        m.line(to: p(13.1, 12.2))
        m.line(to: p(13.1, 4.9))
        m.lineWidth = 1.7 * u
        m.lineCapStyle = .round
        m.lineJoinStyle = .round
        m.stroke()

        // Sparkle with a knocked-out halo
        let c = p(14.3, 14.3)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: c.x - 4.4 * u, y: c.y - 4.4 * u, width: 8.8 * u, height: 8.8 * u)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let r = 3.6 * u, k = 0.9 * u
        let star = NSBezierPath()
        star.move(to: NSPoint(x: c.x, y: c.y + r))
        star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k * 0.3, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k * 0.3))
        star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k * 0.3), controlPoint2: NSPoint(x: c.x + k * 0.3, y: c.y - k))
        star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k * 0.3, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k * 0.3))
        star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k * 0.3), controlPoint2: NSPoint(x: c.x - k * 0.3, y: c.y + k))
        star.close()
        star.fill()
    }
}

/// Keeps the status item button image in sync with the chosen style.
/// Static style: renders once. Live styles: refreshes every few seconds.
@MainActor
final class MenuBarIconUpdater {
    static let shared = MenuBarIconUpdater()

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastPrefs = ""
    private var lastSignature = ""

    private init() {}

    /// Pass the status item too if you want the width to follow the image (live styles are wider than the logo).
    func attach(to button: NSStatusBarButton, statusItem: NSStatusItem? = nil) {
        self.button = button
        statusItem?.length = NSStatusItem.variableLength
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prefsMaybeChanged() }
            }
        }
        lastPrefs = MenuBarPrefs.signature()
        refresh(force: true)
        updateTimer()
    }

    func detach() {
        timer?.invalidate(); timer = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        button = nil
        lastSignature = ""
    }

    /// Re-renders now (no-op when nothing visible changed, unless `force`).
    func refresh(force: Bool = false) {
        guard let button else { return }
        let style = MenuBarPrefs.iconStyle
        let sig = signature(style)
        guard force || sig != lastSignature else { return }
        lastSignature = sig
        button.image = MenuBarIconRenderer.image(style: style)
    }

    private func prefsMaybeChanged() {
        let s = MenuBarPrefs.signature()
        guard s != lastPrefs else { return }
        lastPrefs = s
        refresh(force: true)
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard button != nil, MenuBarPrefs.iconStyle.isLive else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func signature(_ style: MenuBarIconStyle) -> String {
        switch style {
        case .logo: return "logo"
        case .health: return "health\(HealthMonitor.shared.score >= 80 ? 2 : HealthMonitor.shared.score >= 60 ? 1 : 0)"
        case .cpu: return "cpu\(Int(SystemMonitor.shared.cpu.total * 20))"
        case .text:
            let m = MenuBarPrefs.textMetric
            switch m {
            case .cpu: return "t\(Int((SystemMonitor.shared.cpu.total * 100).rounded()))"
            case .memory: return "m\(Int((SystemMonitor.shared.memory.usedFraction * 100).rounded()))"
            case .gpu: return "g\(Int((SystemMonitor.shared.gpu * 100).rounded()))"
            case .battery: return "b\(Int((BatteryMonitor.shared.reading.percent * 100).rounded()))"
            case .health: return "h\(HealthMonitor.shared.score)"
            }
        }
    }
}
