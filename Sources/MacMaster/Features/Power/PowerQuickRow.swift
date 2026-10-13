import SwiftUI

/// Compact (about 320 x 60) row for the menu bar Control Center: Sleep / Restart / Shut Down / Timer,
/// with the active countdown in place of the Timer button. Destructive actions confirm via NSAlert.
struct PowerQuickRow: View {
    private let scheduler = PowerScheduler.shared

    var body: some View {
        HStack(spacing: 8) {
            quick(.sleep)
            quick(.restart)
            quick(.shutDown)
            timerControl
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 60)
        .onAppear { scheduler.start() }
    }

    private func quick(_ kind: PowerActionKind) -> some View {
        Button { Task { await PowerConfirm.run(kind) } } label: {
            VStack(spacing: 3) {
                IconTile(symbol: kind.symbol, colors: kind.colors, size: 26)
                Text(kind.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mmCard)
        .help(kind.subtitle)
    }

    @ViewBuilder
    private var timerControl: some View {
        if let p = scheduler.pending {
            Menu {
                Text("Mac will \(p.action.progressive) at \(PowerFmt.time(p.fireDate))")
                Button("Cancel") { scheduler.cancelPending() }
            } label: {
                VStack(spacing: 3) {
                    IconTile(symbol: p.action.symbol, colors: p.action.colors, size: 26)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(PowerFmt.clock(p.remaining))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("Cancel the countdown")
        } else {
            Menu {
                Section("Sleep in") {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button(m >= 60 ? "\(m / 60) hour\(m == 60 ? "" : "s")" : "\(m) minutes") {
                            scheduler.schedule(.sleep, inMinutes: m)
                        }
                    }
                }
                Section("Shut down in") {
                    ForEach([30, 60], id: \.self) { m in
                        Button(m >= 60 ? "1 hour" : "\(m) minutes") { confirmSchedule(.shutDown, minutes: m) }
                    }
                }
            } label: {
                VStack(spacing: 3) {
                    IconTile(symbol: "timer", colors: Theme.Palette.orange, size: 26)
                    Text("Timer").font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
    }

    private func confirmSchedule(_ action: PowerTimedAction, minutes: Int) {
        let date = Date().addingTimeInterval(Double(minutes) * 60)
        guard PowerConfirm.confirmSchedule(action, at: date) else { return }
        scheduler.schedule(action, at: date)
    }
}
