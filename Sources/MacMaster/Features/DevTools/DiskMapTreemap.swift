import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing, van Wijk). Pure math, no UI.
enum DiskMapTreemap {
    /// Lays out `values` (any positive numbers) inside `rect`.
    /// Returns one rect per input value, in the same order. Zero or negative values get an empty rect.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: values.count)
        guard rect.width > 0, rect.height > 0 else { return out }
        // Work on indices with positive weight, largest first.
        let idx = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        let total = idx.reduce(0.0) { $0 + values[$1] }
        guard total > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var i = 0
        while i < idx.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            guard shortSide > 0 else { break }
            // Grow the row while the worst aspect ratio keeps improving.
            let first = values[idx[i]] * scale
            var rowEnd = i + 1
            var rowSum = first
            var worst = worstRatio(sum: rowSum, minArea: first, maxArea: first, side: shortSide)
            while rowEnd < idx.count {
                let a = values[idx[rowEnd]] * scale     // sorted descending: the newest is the smallest
                let newSum = rowSum + a
                let w = worstRatio(sum: newSum, minArea: a, maxArea: first, side: shortSide)
                if w > worst { break }
                worst = w; rowSum = newSum; rowEnd += 1
            }
            // Lay the row along the short side.
            let wide = remaining.width >= remaining.height   // row becomes a column on the left when wide
            let thickness = rowSum / shortSide
            var offset = 0.0
            for k in i..<rowEnd {
                let a = values[idx[k]] * scale
                let len = thickness > 0 ? a / thickness : 0
                if wide {
                    out[idx[k]] = CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: len)
                } else {
                    out[idx[k]] = CGRect(x: remaining.minX + offset, y: remaining.minY, width: len, height: thickness)
                }
                offset += len
            }
            if wide {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            i = rowEnd
        }
        return out
    }

    private static func worstRatio(sum: Double, minArea: Double, maxArea: Double, side: Double) -> Double {
        guard sum > 0, minArea > 0, side > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
    }
}
