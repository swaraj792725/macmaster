import SwiftUI

/// Geometry of the popover grid: 4 columns of 76pt cells, rows counted in 34pt half rows.
enum ControlCenterMetrics {
    static let columns = 4
    static let cell: CGFloat = 76
    static let gap: CGFloat = 8
    static let halfRow: CGFloat = 34
    static let innerWidth: CGFloat = CGFloat(columns) * cell + CGFloat(columns - 1) * gap   // 328
    static let padding: CGFloat = 14
    static let width: CGFloat = innerWidth + padding * 2                                    // 356

    static func width(cols: Int) -> CGFloat { CGFloat(cols) * cell + CGFloat(cols - 1) * gap }
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * halfRow + CGFloat(rows - 1) * gap }
}

struct ControlCenterPacked: Equatable {
    var frames: [ControlCenterTile: CGRect] = [:]
    var height: CGFloat = 0
}

/// First-fit packing: each tile takes the first free spot (row-major) big enough for it,
/// so small tiles fill holes left by wider ones.
enum ControlCenterPacker {
    /// Packs tiles at the sizes the user chose.
    @MainActor
    static func pack(_ tiles: [ControlCenterTile]) -> ControlCenterPacked {
        let s = ControlCenterSettings.shared
        return pack(tiles.map { ($0, $0.span(s.size($0))) })
    }

    static func pack(_ items: [(tile: ControlCenterTile, span: (cols: Int, rows: Int))]) -> ControlCenterPacked {
        let columns = ControlCenterMetrics.columns
        var used: [[Bool]] = []
        var out = ControlCenterPacked()
        var rowsUsed = 0

        func fits(_ r: Int, _ c: Int, _ cols: Int, _ rows: Int) -> Bool {
            for rr in r..<(r + rows) {
                guard rr < used.count else { continue }
                for cc in c..<(c + cols) where used[rr][cc] { return false }
            }
            return true
        }

        for (tile, span) in items {
            let cols = min(span.cols, columns), rows = span.rows
            var r = 0
            search: while true {
                for c in 0...(columns - cols) where fits(r, c, cols, rows) {
                    while used.count < r + rows { used.append(Array(repeating: false, count: columns)) }
                    for rr in r..<(r + rows) { for cc in c..<(c + cols) { used[rr][cc] = true } }
                    rowsUsed = max(rowsUsed, r + rows)
                    let pitch = ControlCenterMetrics.cell + ControlCenterMetrics.gap
                    out.frames[tile] = CGRect(x: CGFloat(c) * pitch,
                                              y: CGFloat(r) * (ControlCenterMetrics.halfRow + ControlCenterMetrics.gap),
                                              width: ControlCenterMetrics.width(cols: cols),
                                              height: ControlCenterMetrics.height(rows: rows))
                    break search
                }
                r += 1
            }
        }
        out.height = rowsUsed == 0 ? 0 : ControlCenterMetrics.height(rows: rowsUsed)
        return out
    }
}

/// Lays tiles out on the packed grid. In edit mode each tile gets a hide button, a size button
/// and can be dragged onto another tile to reorder.
struct ControlCenterGrid<Content: View>: View {
    let tiles: [ControlCenterTile]
    let editing: Bool
    @ViewBuilder let content: (ControlCenterTile, ControlCenterTileSize) -> Content

    private let settings = ControlCenterSettings.shared
    private static var spring: Animation { .spring(response: 0.38, dampingFraction: 0.78) }

    @State private var dragging: ControlCenterTile?
    @State private var grab: CGSize = .zero
    @State private var pointer: CGPoint = .zero

    var body: some View {
        let packed = ControlCenterPacker.pack(tiles)
        ZStack(alignment: .topLeading) {
            ForEach(tiles) { t in
                let f = packed.frames[t] ?? .zero
                let lifted = dragging == t
                tileBody(t, frame: f, packed: packed)
                    .frame(width: f.width, height: f.height)
                    .scaleEffect(lifted ? 1.05 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: 12, y: 6)
                    .offset(x: lifted ? pointer.x - grab.width : f.minX,
                            y: lifted ? pointer.y - grab.height : f.minY)
                    .zIndex(lifted ? 10 : 0)
                    .animation(lifted ? nil : Self.spring, value: f)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(width: ControlCenterMetrics.innerWidth, height: packed.height, alignment: .topLeading)
        .coordinateSpace(name: "ccgrid")
        .animation(Self.spring, value: tiles)
    }

    @ViewBuilder
    private func tileBody(_ t: ControlCenterTile, frame f: CGRect, packed: ControlCenterPacked) -> some View {
        let size = settings.size(t)
        if editing {
            content(t, size)
                .allowsHitTesting(false)
                .opacity(dragging == t ? 0.92 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .overlay(Color.clear.contentShape(Rectangle()).gesture(drag(t, frame: f, packed: packed)))
                .overlay(alignment: .topLeading) {
                    Button { withAnimation(Self.spring) { settings.setVisible(t, false) } } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 17)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.red)
                            .background(Circle().fill(.white).padding(3))
                    }
                    .buttonStyle(.plain).offset(x: -5, y: -5).help("Hide \(t.title)")
                }
                .overlay(alignment: .topTrailing) {
                    if t.sizes.count > 1 {
                        Button { withAnimation(Self.spring) { settings.cycleSize(t) } } label: {
                            Text(size.detail)
                                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain).padding(5).help("Change size of \(t.title)")
                    }
                }
        } else {
            content(t, size)
        }
    }

    private func drag(_ t: ControlCenterTile, frame f: CGRect, packed: ControlCenterPacked) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("ccgrid"))
            .onChanged { g in
                if dragging == nil {
                    dragging = t
                    grab = CGSize(width: g.startLocation.x - f.minX, height: g.startLocation.y - f.minY)
                }
                guard dragging == t else { return }
                pointer = g.location
                // Reorder once the pointer is well inside another tile, so tiles don't flip back and forth.
                let hit = tiles.first { other in
                    guard other != t, let r = packed.frames[other] else { return false }
                    return r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2).contains(g.location)
                }
                if let hit { settings.move(t, onto: hit) }
            }
            .onEnded { _ in
                withAnimation(Self.spring) { dragging = nil }
            }
    }
}
