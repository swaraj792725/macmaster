import SwiftUI
import AppKit
import Observation

/// Optional status item: output volume icon (red mic.slash while the mic is muted) with a popover for switching
/// devices, volume and mic mute. Redraws only when the observed engine state changes.
@MainActor
final class SoundMenuBar: NSObject, NSPopoverDelegate {
    static let shared = SoundMenuBar()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var lastKey = ""

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Creates or removes the status item to match the setting. Idempotent.
    func update() {
        if SoundSettings.menuBar && !Services.isSnapshotRun {
            if item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let b = it.button {
                    b.imagePosition = .imageOnly
                    b.target = self
                    b.action = #selector(toggle)
                }
                item = it
                lastKey = ""
            }
            track()
        } else if let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            lastKey = ""
        }
    }

    /// Re-reads the engine inside an observation scope; the change handler re-arms it.
    private func track() {
        guard item != nil else { return }
        let engine = SoundEngine.shared
        let (key, symbol, muted): (String, String, Bool) = withObservationTracking {
            let out = engine.defaultOutput
            let vol = out?.outVolume ?? 0
            let m = out?.outMuted == true
            let sym = SoundFormat.speakerSymbol(volume: vol, muted: m)
            return ("\(sym)|\(engine.micMuted)", sym, engine.micMuted)
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { SoundMenuBar.shared.track() } }
        }
        guard key != lastKey, let b = item?.button else { return }
        lastKey = key
        let name = muted ? "mic.slash.fill" : symbol
        let img = NSImage(systemSymbolName: SymbolKit.resolve(name), accessibilityDescription: muted ? "Microphone muted" : "Sound")
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let out = img?.withSymbolConfiguration(cfg)
        if muted, let out {
            b.image = out.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? out
        } else {
            out?.isTemplate = true
            b.image = out
        }
        b.toolTip = muted ? "Microphone muted" : "Sound"
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        SoundEngine.shared.setObserving("popover", true)
        let host = NSHostingController(rootView: SoundPopoverView { [weak self] in self?.popover.performClose(nil) })
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: SoundPopoverView.width, height: 360)
        popover.contentViewController = host
        popover.showFromStatusItem(button)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        SoundEngine.shared.setObserving("popover", false)
    }
}

struct SoundPopoverView: View {
    static let width: CGFloat = 320
    var close: () -> Void
    @State private var engine = SoundEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Output", "speaker.wave.2.fill")
            ForEach(engine.outputs) { d in
                SoundDeviceRow(device: d, scope: .output, selected: d.id == engine.defaultOutputID, compact: true) {
                    engine.selectOutput(d)
                }
            }
            if let cur = engine.defaultOutput {
                SoundOutputVolumeRow(device: cur, compact: true).padding(.horizontal, 8)
            }
            Divider()
            header("Input", "mic.fill")
            ForEach(engine.inputs) { d in
                SoundDeviceRow(device: d, scope: .input, selected: d.id == engine.defaultInputID, compact: true) {
                    engine.selectInput(d)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: engine.micMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(engine.micMuted ? Color.red : .secondary).frame(width: 20)
                Text("Mute microphone").font(.callout)
                Spacer()
                Toggle("", isOn: Binding(get: { engine.micMuted }, set: { engine.setMicMuted($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 8)
            if let p = engine.micMuteProblem {
                Text(p).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button {
                close()
                MainWindow.show(section: .sound)
            } label: {
                Label("Open Sound settings", systemImage: "slider.horizontal.3").font(.callout)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: Self.width)
    }

    private func header(_ t: String, _ symbol: String) -> some View {
        Label(t, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }
}
