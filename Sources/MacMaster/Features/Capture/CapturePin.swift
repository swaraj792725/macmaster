import AppKit

/// Floating, always-on-top image. Drag to move, scroll to resize, ⌥ + scroll for opacity,
/// double-click or Esc to close. Right-click for copy / save / close.
@MainActor
final class CapturePinWindow: NSPanel {
    let source: CaptureImage
    private let baseSize: CGSize
    private var zoom: CGFloat = 1
    var onClose: ((CapturePinWindow) -> Void)?

    init(image: CaptureImage, near rect: CGRect?) {
        source = image
        let size = image.size
        baseSize = CGSize(width: max(40, size.width), height: max(40, size.height))
        let screen = NSScreen.screens.first(where: { rect.map($0.frame.intersects) ?? false }) ?? NSScreen.main
        var origin = rect?.origin ?? .zero
        if rect == nil, let vf = screen?.visibleFrame {
            origin = CGPoint(x: vf.midX - baseSize.width / 2, y: vf.midY - baseSize.height / 2)
        }
        super.init(contentRect: CGRect(origin: origin, size: baseSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let v = PinImageView(frame: CGRect(origin: .zero, size: baseSize), image: image)
        v.pin = self
        contentView = v
        fitToScreen()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shrinks an oversized pin so it fits the screen it appears on.
    private func fitToScreen() {
        guard let vf = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let fit = min(1, (vf.width - 40) / baseSize.width, (vf.height - 40) / baseSize.height)
        if fit < 1 { setZoom(fit, around: nil) }
        // Keep it on screen.
        var f = frame
        f.origin.x = min(max(f.origin.x, vf.minX + 8 - f.width + 60), vf.maxX - 60)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - 40)
        setFrame(f, display: false)
    }

    func present() {
        orderFrontRegardless()
        makeKey()
    }

    func setZoom(_ z: CGFloat, around anchor: CGPoint?) {
        let nz = min(max(z, 0.1), 8)
        let old = frame
        let size = CGSize(width: baseSize.width * nz, height: baseSize.height * nz)
        guard size.width >= 24, size.height >= 24 else { return }
        zoom = nz
        // Keep the point under the cursor fixed (anchor is in screen coordinates), else resize about the center.
        let a = anchor ?? CGPoint(x: old.midX, y: old.midY)
        let fx = old.width > 0 ? (a.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (a.y - old.minY) / old.height : 0.5
        let origin = CGPoint(x: a.x - fx * size.width, y: a.y - fy * size.height)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func scrolled(by dy: CGFloat, option: Bool) {
        if option {
            alphaValue = min(1, max(0.15, alphaValue + dy * 0.01))
        } else {
            setZoom(zoom * exp(dy * 0.012), around: NSEvent.mouseLocation)
        }
    }

    func closePin() {
        let cb = onClose
        onClose = nil
        contentView = nil
        orderOut(nil)
        close()
        cb?(self)
    }

    override func cancelOperation(_ sender: Any?) { closePin() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    func resetSize() { alphaValue = 1; setZoom(1, around: nil) }
}

private final class PinImageView: NSView {
    weak var pin: CapturePinWindow?
    private let image: CaptureImage

    init(frame: CGRect, image: CaptureImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image.cg
        layer?.contentsGravity = .resize
        layer?.contentsScale = image.scale
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.magnificationFilter = .trilinear
        layer?.minificationFilter = .trilinear
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { pin?.closePin(); return }
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.5 : 3)
        guard dy != 0 else { return }
        pin?.scrolled(by: dy, option: event.modifierFlags.contains(.option))
    }

    override func magnify(with event: NSEvent) {
        pin?.scrolled(by: event.magnification * 60, option: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Save…", action: #selector(saveImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Actual size", action: #selector(actualSize), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closeIt), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() { CaptureEngine.copyToClipboard(image) }
    @objc private func saveImage() { CaptureEngine.shared.savePanel(image) }
    @objc private func actualSize() { pin?.resetSize() }
    @objc private func closeIt() { pin?.closePin() }
}
