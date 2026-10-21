import AppKit
import QuartzCore

/// Full-screen region picker. One borderless panel per display, each showing that display's frozen image dimmed,
/// with a clear selection rectangle, live size label and a pixel loupe. Everything is released in `finish`.
@MainActor
final class CaptureOverlay {
    struct Selection {
        /// The selected pixels.
        let image: CaptureImage
        /// Selection in global Cocoa screen coordinates (points).
        let rect: CGRect
    }

    private var panels: [RegionPanel] = []
    private var completion: ((Selection?) -> Void)?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var finished = false

    /// - Parameters:
    ///   - frames: frozen images, one per display.
    ///   - windowRects: on-screen window frames in global Cocoa coordinates, front to back (for click-to-pick-a-window).
    ///   - hint: short instruction shown until the first click.
    init(frames: [CaptureFrame], windowRects: [CGRect], hint: String) {
        for f in frames {
            let panel = RegionPanel(contentRect: f.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            let local = windowRects.compactMap { r -> CGRect? in
                let rr = r.offsetBy(dx: -f.frame.minX, dy: -f.frame.minY)
                let clipped = rr.intersection(CGRect(origin: .zero, size: f.frame.size))
                return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : clipped
            }
            let view = RegionView(frame: CGRect(origin: .zero, size: f.frame.size), info: f, windowRects: local, hint: hint)
            view.owner = self
            panel.contentView = view
            panel.setFrame(f.frame, display: false)
            panels.append(panel)
        }
    }

    func begin(completion: @escaping (Selection?) -> Void) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        var keyPanel: RegionPanel?
        for p in panels {
            p.orderFrontRegardless()
            if p.frame.contains(mouse) { keyPanel = p }
        }
        let kp = keyPanel ?? panels.first
        kp?.makeKey()
        if let v = kp?.contentView { kp?.makeFirstResponder(v) }
        for p in panels { (p.contentView as? RegionView)?.start(mouse: mouse) }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !self.finished else { return e }
            if e.keyCode == 53 { self.finish(nil); return nil }
            return e
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.finish(nil) } }
    }

    /// Called by a view when it is the one being dragged on: the other displays stop showing guides.
    fileprivate func activate(_ view: RegionView) {
        for p in panels {
            if let v = p.contentView as? RegionView, v !== view { v.becomeIdle() }
        }
    }

    fileprivate func finish(_ selection: Selection?) {
        guard !finished else { return }
        finished = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        NSCursor.arrow.set()
        for p in panels {
            (p.contentView as? RegionView)?.teardown()
            p.contentView = nil
            p.orderOut(nil)
            p.close()
        }
        panels.removeAll()
        let done = completion
        completion = nil
        done?(selection)
    }

    /// Escape hatch if the owner is dropped mid-capture.
    func cancel() { finish(nil) }
}

// MARK: - Panel

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Keep the panel exactly over the display, including the menu bar strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Region view

private final class RegionView: NSView {
    weak var owner: CaptureOverlay?
    private let info: CaptureFrame
    private let windowRects: [CGRect]

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let loupe = LoupeView(frame: .zero)
    private let sizeLabel = PillView(frame: .zero)
    private let hintPill = PillView(frame: .zero)

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoverRect: CGRect?
    private var cursor: CGPoint?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, info: CaptureFrame, windowRects: [CGRect], hint: String) {
        self.info = info
        self.windowRects = windowRects
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        imageLayer.contents = info.image
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = info.scale
        imageLayer.magnificationFilter = .linear
        imageLayer.frame = bounds
        root.addSublayer(imageLayer)

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.frame = bounds
        root.addSublayer(dimLayer)

        guideLayer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        guideLayer.lineWidth = 1 / info.scale
        guideLayer.fillColor = nil
        guideLayer.frame = bounds
        root.addSublayer(guideLayer)

        frameLayer.fillColor = nil
        frameLayer.frame = bounds
        root.addSublayer(frameLayer)

        for v in [sizeLabel, hintPill, loupe] as [NSView] { v.isHidden = true; addSubview(v) }
        hintPill.setText(hint, size: 13, weight: .medium)
        hintPill.frame.origin = CGPoint(x: (bounds.width - hintPill.frame.width) / 2, y: bounds.height - 76)
        hintPill.isHidden = false
        updateLayers()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    func start(mouse: CGPoint) {
        guard info.frame.contains(mouse) else { return }
        let p = CGPoint(x: mouse.x - info.frame.minX, y: mouse.y - info.frame.minY)
        pointerMoved(to: p)
        NSCursor.crosshair.set()
    }

    func becomeIdle() {
        cursor = nil
        hoverRect = nil
        loupe.isHidden = true
        updateLayers()
    }

    func teardown() {
        owner = nil
        imageLayer.contents = nil
        loupe.image = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        subviews.forEach { $0.removeFromSuperview() }
        if let t = tracking { removeTrackingArea(t); tracking = nil }
    }

    // MARK: Tracking and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else { return }
        cursor = nil
        hoverRect = nil
        loupe.isHidden = true
        updateLayers()
    }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        pointerMoved(to: point(event))
    }

    private func pointerMoved(to p: CGPoint) {
        cursor = p
        if dragStart == nil { hoverRect = windowRects.first(where: { $0.contains(p) }) }
        updateLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        dragStart = p
        selection = nil
        hintPill.isHidden = true
        owner?.activate(self)
        pointerMoved(to: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = point(event)
        cursor = p
        hoverRect = nil
        var r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        if event.modifierFlags.contains(.shift) {   // square
            let side = max(r.width, r.height)
            r = CGRect(x: p.x < s.x ? s.x - side : s.x, y: p.y < s.y ? s.y - side : s.y, width: side, height: side)
            r = r.intersection(bounds)
        }
        selection = r
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        defer { dragStart = nil }
        if let r = selection, r.width >= 4, r.height >= 4 {
            complete(with: r)
        } else if dragStart != nil, let w = windowRects.first(where: { $0.contains(p) }) {
            complete(with: w)
        } else {
            selection = nil
            pointerMoved(to: p)
        }
    }

    override func rightMouseDown(with event: NSEvent) { owner?.cancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.cancel() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { owner?.cancel() }

    private func complete(with viewRect: CGRect) {
        let img = info.image
        let sx = CGFloat(img.width) / bounds.width, sy = CGFloat(img.height) / bounds.height
        let px = CGRect(x: viewRect.minX * sx,
                        y: (bounds.height - viewRect.maxY) * sy,
                        width: viewRect.width * sx,
                        height: viewRect.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !px.isNull, px.width >= 1, px.height >= 1, let cropped = img.cropping(to: px) else {
            owner?.cancel()
            return
        }
        let global = viewRect.offsetBy(dx: info.frame.minX, dy: info.frame.minY)
        owner?.finish(.init(image: CaptureImage(cg: cropped, scale: info.scale), rect: global))
    }

    // MARK: Drawing

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let highlight = selection ?? hoverRect
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let h = highlight { dim.addRect(h) }
        dimLayer.path = dim

        // Guides: only while nothing is highlighted.
        if let c = cursor, highlight == nil {
            let g = CGMutablePath()
            let x = (c.x * info.scale).rounded(.down) / info.scale + 0.5 / info.scale
            let y = (c.y * info.scale).rounded(.down) / info.scale + 0.5 / info.scale
            g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: bounds.width, y: y))
            g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: bounds.height))
            guideLayer.path = g
        } else {
            guideLayer.path = nil
        }

        if let h = highlight {
            let isSel = selection != nil
            frameLayer.path = CGPath(rect: h, transform: nil)
            frameLayer.strokeColor = (isSel ? NSColor.white : NSColor.systemBlue).cgColor
            frameLayer.lineWidth = isSel ? 1 : 2
            frameLayer.fillColor = isSel ? nil : NSColor.systemBlue.withAlphaComponent(0.14).cgColor
            sizeLabel.setText("\(Int(h.width.rounded())) × \(Int(h.height.rounded()))", size: 12, weight: .semibold, mono: true)
            sizeLabel.frame.origin = labelOrigin(for: h)
            sizeLabel.isHidden = false
        } else {
            frameLayer.path = nil
            sizeLabel.isHidden = true
        }

        if let c = cursor {
            let s = sample(at: c)
            loupe.image = s.image
            loupe.hex = s.hex
            loupe.coords = "\(Int(c.x.rounded())), \(Int((bounds.height - c.y).rounded()))"
            loupe.needsDisplay = true
            var o = CGPoint(x: c.x + 22, y: c.y - 22 - loupe.frame.height)
            if o.x + loupe.frame.width > bounds.width - 6 { o.x = c.x - 22 - loupe.frame.width }
            if o.y < 6 { o.y = c.y + 22 }
            if o.y + loupe.frame.height > bounds.height - 6 { o.y = bounds.height - 6 - loupe.frame.height }
            loupe.frame.origin = CGPoint(x: max(6, o.x), y: o.y)
            loupe.isHidden = false
        } else {
            loupe.isHidden = true
        }
    }

    private func labelOrigin(for r: CGRect) -> CGPoint {
        let w = sizeLabel.frame.width, h = sizeLabel.frame.height
        var x = min(r.maxX - w, bounds.width - w - 4)
        x = max(4, x)
        var y = r.minY - h - 6
        if y < 4 { y = r.maxY + 6 }
        if y + h > bounds.height - 4 { y = r.minY + 6 }
        return CGPoint(x: x, y: y)
    }

    // MARK: Pixel sampling

    private static let grid = 15

    /// A `grid`×`grid` pixel window around the cursor, plus the center pixel as hex.
    private func sample(at p: CGPoint) -> (image: CGImage?, hex: String) {
        let img = info.image
        let W = img.width, H = img.height
        let n = Self.grid, half = n / 2
        let px = min(max(Int((p.x / bounds.width * CGFloat(W)).rounded(.down)), 0), W - 1)
        let py = min(max(Int(((bounds.height - p.y) / bounds.height * CGFloat(H)).rounded(.down)), 0), H - 1)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, "") }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.interpolationQuality = .none
        let want = CGRect(x: px - half, y: py - half, width: n, height: n)
        let crop = want.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        if !crop.isNull, let c = img.cropping(to: crop) {
            let dx = crop.minX - want.minX
            let dyTop = crop.minY - want.minY
            ctx.draw(c, in: CGRect(x: dx, y: CGFloat(n) - (dyTop + crop.height), width: crop.width, height: crop.height))
        }
        var hex = ""
        if let d = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let o = (half * n + half) * 4
            hex = String(format: "#%02X%02X%02X", d[o], d[o + 1], d[o + 2])
        }
        return (ctx.makeImage(), hex)
    }
}

// MARK: - Small views

/// Dark rounded label. Never takes mouse events.
private final class PillView: NSView {
    private var text = NSAttributedString()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ s: String, size: CGFloat, weight: NSFont.Weight, mono: Bool = false) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white])
        guard a.string != text.string else { return }
        text = a
        let sz = a.size()
        setFrameSize(CGSize(width: ceil(sz.width) + 18, height: ceil(sz.height) + 8))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = text.size()
        text.draw(at: CGPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// Magnified pixels around the cursor with the center pixel's hex and position.
private final class LoupeView: NSView {
    var image: CGImage?
    var hex = ""
    var coords = ""
    private static let cell: CGFloat = 8
    private static let side: CGFloat = CGFloat(15) * cell

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side + 4, height: Self.side + 4 + 44))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgRect = CGRect(x: 2, y: bounds.height - Self.side - 2, width: Self.side, height: Self.side)
        let shape = NSBezierPath(roundedRect: imgRect, xRadius: 14, yRadius: 14)

        ctx.saveGState()
        shape.addClip()
        if let image {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: imgRect)
        }
        ctx.restoreGState()

        // Center cell
        let c = CGRect(x: imgRect.midX - Self.cell / 2, y: imgRect.midY - Self.cell / 2, width: Self.cell, height: Self.cell)
        NSColor.black.setStroke()
        let outer = NSBezierPath(rect: c.insetBy(dx: -0.5, dy: -0.5)); outer.lineWidth = 1.5; outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: c.insetBy(dx: 0.5, dy: 0.5)); inner.lineWidth = 1; inner.stroke()

        NSColor.white.setStroke()
        shape.lineWidth = 2
        shape.stroke()

        // Info pill
        let pill = CGRect(x: 2, y: 2, width: Self.side, height: 38)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        if let sw = PickedColor(hex: hex) {
            NSColor(srgbRed: CGFloat(sw.r) / 255, green: CGFloat(sw.g) / 255, blue: CGFloat(sw.b) / 255, alpha: 1).setFill()
            let dot = NSBezierPath(ovalIn: CGRect(x: pill.minX + 8, y: pill.midY - 9, width: 18, height: 18))
            dot.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            dot.lineWidth = 1; dot.stroke()
        }
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                                                  .foregroundColor: NSColor.white]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
        (hex as NSString).draw(at: CGPoint(x: pill.minX + 32, y: pill.midY + 1), withAttributes: big)
        (coords as NSString).draw(at: CGPoint(x: pill.minX + 32, y: pill.midY - 13), withAttributes: small)
    }
}
