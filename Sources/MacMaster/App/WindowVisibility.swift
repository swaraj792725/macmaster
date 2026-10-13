import AppKit
import SwiftUI

/// Reports whether the hosting window is actually on screen. Goes `false` once the window has been
/// closed, minimized or fully covered for longer than `grace`, so pages can stop rendering live data.
struct WindowVisibilityObserver: NSViewRepresentable {
    @Binding var visible: Bool
    var grace: TimeInterval = 20

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.grace = grace
        v.onChange = { visible = $0 }
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.onChange = { visible = $0 } }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        var grace: TimeInterval = 20
        private var tokens: [NSObjectProtocol] = []
        private var pending: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                              NSWindow.didBecomeKeyNotification]
            for n in names {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.evaluate(closing: note.name == NSWindow.willCloseNotification) }
                })
            }
        }

        private func evaluate(closing: Bool) {
            guard let w = window else { return }
            let shown = !closing && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
            pending?.cancel()
            if shown { onChange?(true); return }
            let item = DispatchWorkItem { [weak self] in self?.onChange?(false) }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (closing ? 1 : grace), execute: item)
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
