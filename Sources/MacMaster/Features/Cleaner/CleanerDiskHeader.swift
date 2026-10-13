import SwiftUI

/// Disk usage ring + storage breakdown bar.
struct CleanerDiskHeader: View {
    private let monitor = SystemMonitor.shared
    private let storage = CleanerStorage.shared

    var body: some View {
        let disk = monitor.disk
        HStack(alignment: .center, spacing: 22) {
            RingGauge(fraction: disk.usedFraction, lineWidth: 12, colors: nil,
                      label: "used", valueText: Fmt.percent(disk.usedFraction))
                .frame(width: 116, height: 116)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.bytes(disk.available))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("available of \(Fmt.bytes(disk.total))").foregroundStyle(.secondary)
                    Spacer()
                    if storage.isLoading { ProgressView().controlSize(.small) }
                }
                breakdownBar(total: disk.total)
                CleanerFlow(spacing: 14) {
                    ForEach(storage.segments) { s in
                        HStack(spacing: 5) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                            Text("\(s.title) \(Fmt.bytes(s.bytes))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .card()
        .onAppear { storage.refresh() }
    }

    private func breakdownBar(total: Int64) -> some View {
        GeometryReader { geo in
            let t = Double(max(total, 1))
            HStack(spacing: 2) {
                ForEach(storage.segments) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color)
                        .frame(width: max(0, geo.size.width * Double(s.bytes) / t - 2))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .animation(.smooth, value: storage.segments.map(\.bytes))
        }
        .frame(height: 14)
    }
}
