// Renders the MacMaster app icon. Run: swift scripts/make-icon.swift <outDir>
// Produces <outDir>/AppIcon.iconset (+ preview.png); turn into .icns with iconutil.
import AppKit

/// macOS icon squircle (superellipse, n = 5) inside the standard 824/1024 grid.
func squircle(_ r: CGRect) -> NSBezierPath {
    let p = NSBezierPath()
    let n = 4.6, a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...360 {
        let t = Double(i) * .pi / 180
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
    }
    p.close()
    return p
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let cg = ctx.cgContext
    let u = s / 1024                                   // design unit
    let rect = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let body = squircle(rect)

    // Drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.32)
    sh.shadowBlurRadius = 28 * u
    sh.shadowOffset = NSSize(width: 0, height: -12 * u)
    sh.set()
    rgb(0x1E1B4B).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: deep indigo to electric blue, with a violet glow bottom-right.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [rgb(0x3B82F6), rgb(0x4F46E5), rgb(0x1E1B4B)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: rect, angle: -90)
    NSGradient(colors: [rgb(0xC026D3, 0.55), rgb(0xC026D3, 0)])!
        .draw(fromCenter: NSPoint(x: rect.maxX - 120 * u, y: rect.minY + 110 * u), radius: 0,
              toCenter: NSPoint(x: rect.maxX - 120 * u, y: rect.minY + 110 * u), radius: 520 * u, options: [])
    NSGradient(colors: [rgb(0x22D3EE, 0.35), rgb(0x22D3EE, 0)])!
        .draw(fromCenter: NSPoint(x: rect.minX + 150 * u, y: rect.maxY - 120 * u), radius: 0,
              toCenter: NSPoint(x: rect.minX + 150 * u, y: rect.maxY - 120 * u), radius: 460 * u, options: [])
    // Glassy sheen on the top half.
    NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Inner hairline.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    rgb(0xFFFFFF, 0.28).setStroke()
    body.lineWidth = 3 * u
    body.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let c = CGPoint(x: rect.midX, y: rect.midY - 6 * u)
    let ringR = 270 * u, ringW = 58 * u

    // Ring track.
    cg.setLineWidth(ringW)
    cg.setLineCap(.round)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    cg.addArc(center: c, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    // Gauge arc (≈80%) with mint → cyan → white gradient, drawn by masking a conic sweep.
    let start = CGFloat.pi / 2 + 0.0, sweep = CGFloat.pi * 2 * 0.80
    cg.saveGState()
    let arc = CGMutablePath()
    arc.addArc(center: c, radius: ringR, startAngle: start, endAngle: start - sweep, clockwise: true)
    let stroked = arc.copy(strokingWithWidth: ringW, lineCap: .round, lineJoin: .round, miterLimit: 10)
    cg.addPath(stroked)
    cg.clip()
    cg.setFillColor(NSColor(srgbRed: 0.20, green: 0.90, blue: 0.62, alpha: 1).cgColor)
    cg.fill(CGRect(x: c.x - ringR - ringW, y: c.y - ringR - ringW, width: (ringR + ringW) * 2, height: (ringR + ringW) * 2))
    let steps = 180
    for i in 0..<steps {
        let f = CGFloat(i) / CGFloat(steps)
        let a0 = start - sweep * f - 0.25, a1 = start - sweep * (f + 1 / CGFloat(steps)) - 0.25
        let col = NSColor(srgbRed: 0.20 + 0.80 * f * f, green: 0.90 + 0.10 * f, blue: 0.62 + 0.38 * f, alpha: 1)
        cg.setFillColor(col.cgColor)
        cg.move(to: c)
        cg.addArc(center: c, radius: ringR + ringW, startAngle: a0 + 0.3, endAngle: a1 - 0.02, clockwise: true)
        cg.closePath()
        cg.fillPath()
    }
    cg.restoreGState()

    // Glowing end cap.
    let endA = start - sweep
    let end = CGPoint(x: c.x + ringR * cos(endA), y: c.y + ringR * sin(endA))
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 30 * u, color: NSColor.white.withAlphaComponent(0.9).cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: end.x - ringW / 2, y: end.y - ringW / 2, width: ringW, height: ringW))
    cg.restoreGState()

    // Monogram "M" in SF Pro Rounded Heavy.
    let font = NSFont.systemFont(ofSize: 330 * u, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 330 * u) } ?? font
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x1E1B4B, 0.45)
    shadow.shadowBlurRadius = 18 * u
    shadow.shadowOffset = NSSize(width: 0, height: -8 * u)
    let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor.white, .shadow: shadow]
    let str = NSAttributedString(string: "M", attributes: attrs)
    let b = str.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let glyphH = rounded.capHeight
    str.draw(at: NSPoint(x: c.x - b.width / 2, y: c.y - glyphH / 2 + rounded.descender))

    // Sparkle, top-right.
    let spark = NSImage.SymbolConfiguration(pointSize: 120 * u, weight: .bold)
        .applying(.init(paletteColors: [.white, rgb(0xA5F3FC)]))
    if let sp = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(spark) {
        let z = sp.size
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow(); g.shadowColor = .white.withAlphaComponent(0.8); g.shadowBlurRadius = 20 * u; g.set()
        sp.draw(in: NSRect(x: rect.maxX - z.width - 92 * u, y: rect.maxY - z.height - 92 * u, width: z.width, height: z.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("preview.png"))
print(iconset.path)
