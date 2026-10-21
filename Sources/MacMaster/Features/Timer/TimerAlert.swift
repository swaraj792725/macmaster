import SwiftUI
import AppKit

/// "Time's up" banner plus a soft screen flash. Windows exist only while an alert is pending.
@MainActor
final class TimerAlertController {
    static let shared = TimerAlertController()
    private var banner: NSPanel?
    private var flash: NSPanel?
    private var flashTask: Task<Void, Never>?
    private var shownCount = 0

    private init() {}

    /// Shows, updates or closes the banner to match the engine's pending alerts.
    func refresh() {
        let engine = TimerEngine.shared
        let wanted = TimerPrefs.bool(TimerPrefs.banner, true) && !engine.alerts.isEmpty && !Services.isSnapshotRun
        if engine.alerts.isEmpty { engine.stopAlertSound() }
        guard wanted else { closeBanner(); return }
        let isNew = banner == nil || engine.alerts.count > shownCount
        shownCount = engine.alerts.count
        if banner == nil { makeBanner() }
        if isNew { pulse() }
    }

    private func makeBanner() {
        let size = NSSize(width: 380, height: 190)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TimerAlertView())
        host.sizingOptions = []
        p.contentView = host
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.18))
        }
        p.orderFrontRegardless()
        banner = p
    }

    private func closeBanner() {
        shownCount = 0
        flashTask?.cancel(); flashTask = nil
        if let p = banner { p.orderOut(nil); p.contentView = nil; banner = nil }
        closeFlash()
    }

    // MARK: Flash

    /// Two slow fades of a warm tint over the main screen. Skipped when Reduce Motion is on.
    private func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        flashTask?.cancel()
        closeFlash()
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = NSColor.systemOrange
        p.alphaValue = 0
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.setFrame(screen.frame, display: false)
        p.orderFrontRegardless()
        flash = p
        flashTask = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                guard !Task.isCancelled, let panel = self?.flash else { return }
                self?.fade(panel, to: 0.22, duration: 0.5)
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled, let panel = self?.flash else { return }
                self?.fade(panel, to: 0, duration: 0.7)
                try? await Task.sleep(for: .milliseconds(750))
            }
            self?.closeFlash()
        }
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = duration
        panel.animator().alphaValue = alpha
        NSAnimationContext.endGrouping()
    }

    private func closeFlash() {
        if let p = flash { p.orderOut(nil); flash = nil }
    }
}

private struct TimerAlertView: View {
    private let engine = TimerEngine.shared

    var body: some View {
        let alert = engine.alerts.first
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "timer", colors: Theme.Palette.orange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time's up").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(alert?.label ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let d = alert?.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if engine.alerts.count > 1 {
                Text("+\(engine.alerts.count - 1) more finished")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("Stop") {
                    if engine.alerts.count > 1 { if let a = alert { engine.dismissAlert(a.id) } } else { engine.dismissAllAlerts() }
                }
                .buttonStyle(.mmPrimary(tint: .orange))
                if let a = alert, a.snoozable {
                    Button("Snooze 5 min") { engine.snooze(a.id, seconds: 300) }
                        .buttonStyle(.mmSecondary)
                }
                Spacer(minLength: 0)
                if engine.alerts.count > 1 {
                    Button("Stop all") { engine.dismissAllAlerts() }.buttonStyle(.mmGhost)
                }
            }
        }
        .padding(18)
        .frame(width: 380, height: 190, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}
