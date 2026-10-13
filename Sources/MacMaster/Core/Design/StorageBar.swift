import SwiftUI

struct StorageSegment: Identifiable {
    let id: String
    let label: String
    let bytes: Double
    let color: Color
    init(_ label: String, bytes: Double, color: Color) {
        self.id = label; self.label = label; self.bytes = bytes; self.color = color
    }
}

/// Segmented capacity bar like About This Mac › Storage. Remainder (free) is the empty track.
struct SegmentedBar: View {
    let segments: [StorageSegment]
    let total: Double
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    let w = total > 0 ? width * CGFloat(seg.bytes / total) : 0
                    if w > 0.5 {
                        Rectangle()
                            .fill(LinearGradient(colors: [seg.color.lighter(0.12), seg.color],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: max(2, w - 1.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: height, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
            .animation(.smooth, value: segments.map(\.bytes))
        }
        .frame(height: height)
    }
}

/// Dot + label (+ value) legend entries for a `SegmentedBar`.
struct SegmentLegend: View {
    let segments: [StorageSegment]
    var freeBytes: Double? = nil

    var body: some View {
        HStack(spacing: 14) {
            ForEach(segments) { seg in item(seg.color, seg.label, Fmt.bytes(Int64(seg.bytes))) }
            if let freeBytes { item(Color.primary.opacity(0.18), "Free", Fmt.bytes(Int64(freeBytes))) }
        }
        .font(.caption)
    }

    private func item(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
