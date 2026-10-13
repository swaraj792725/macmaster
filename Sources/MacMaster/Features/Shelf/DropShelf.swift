import AppKit

/// Drop Shelf entry point: owns the drag monitor and the shelf window.
/// `start()` is idempotent and honours the enable setting.
@MainActor
final class DropShelf {
    static let shared = DropShelf()

    private let settings = DropShelfSettings.shared
    private let model = DropShelfModel()
    private let monitor = DropShelfDragMonitor()
    private lazy var controller = DropShelfPanelController(model: model)
    private var started = false

    private init() {
        settings.onChange = { [weak self] in self?.apply() }
        model.onChange = { [weak self] in self?.modelChanged() }
        monitor.onTrigger = { [weak self] in self?.dragTriggered($0) }
        monitor.onDragEnded = { [weak self] in self?.dragEnded() }
    }

    var isVisible: Bool { controller.isVisible }

    /// Begins watching for file drags if the feature is enabled.
    func start() {
        guard !started else { return }
        started = true
        apply()
    }

    func stop() {
        started = false
        monitor.stop()
        controller.hide()
    }

    /// Shows the shelf near the cursor, or hides it if already visible.
    func toggle() {
        if controller.isVisible {
            controller.hide()
        } else {
            controller.openedByDrag = false
            controller.show(.nearCursor)
        }
    }

    func openNow() {
        controller.openedByDrag = false
        controller.show(.nearCursor)
    }

    // MARK: Internals

    /// Installs the global monitor only when a trigger (shake or edge) is on.
    private func apply() {
        guard started else { return }
        monitor.shakeEnabled = settings.shakeToOpen
        monitor.edge = settings.edge
        let wanted = settings.enabled && (settings.shakeToOpen || settings.edge != .off)
        if wanted { monitor.start() } else { monitor.stop() }
        if !settings.enabled { controller.hide() }
    }

    private func dragTriggered(_ placement: DropShelfPlacement) {
        guard !controller.isVisible else { return }
        controller.openedByDrag = true
        controller.show(placement)
    }

    /// Global mouse-up: close a drag-opened shelf nobody dropped onto.
    private func dragEnded() {
        guard controller.openedByDrag, controller.isVisible else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.controller.openedByDrag, self.model.items.isEmpty, self.model.pendingLoads == 0 else { return }
            self.controller.hide()
        }
    }

    private func modelChanged() {
        if !model.items.isEmpty { controller.openedByDrag = false }
        controller.resize()
        if model.items.isEmpty, settings.autoCloseWhenEmpty, controller.isVisible, !model.internalDragActive {
            controller.hide()
        }
    }

    func noteShelfDrop() { monitor.resync() }
    func resyncDragMonitor() { monitor.resync() }
}
