// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
//
// Items are laid out in rows along the shorter side of the remaining space,
// greedily adding items to a row while doing so improves the worst aspect
// ratio in that row. This keeps tiles close to square, which makes sizes easy
// to compare by eye.

import CoreGraphics

enum Treemap {
    /// Lays out `weights` inside `bounds`, returning one rectangle per weight
    /// in input order. Weights should be sorted descending for best results;
    /// zero or negative weights get an empty rectangle.
    static func squarify(_ weights: [Double], in bounds: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: CGRect(origin: bounds.origin, size: .zero), count: weights.count)
        let total = weights.filter { $0 > 0 }.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        guard total > 0, area > 0 else { return out }

        // Scale weights to areas in the target coordinate space.
        let scale = area / total
        let items = weights.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }

        var free = bounds
        var start = 0
        while start < items.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var rowSum = items[start].area
            var best = worstRatio(items[start..<end], sum: rowSum, side: side)
            while end < items.count {
                let candidateSum = rowSum + items[end].area
                let candidate = worstRatio(items[start...end], sum: candidateSum, side: side)
                if candidate > best { break }
                best = candidate
                rowSum = candidateSum
                end += 1
            }
            free = place(items[start..<end], sum: rowSum, in: free, into: &out)
            start = end
        }
        return out
    }

    /// Worst (largest) aspect ratio of a row laid along a side of length `side`.
    private static func worstRatio(_ row: ArraySlice<(index: Int, area: Double)>, sum: Double, side: Double) -> Double {
        let areas = row.map(\.area)
        guard let smallest = areas.min(), let largest = areas.max(), smallest > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }

    /// Places a row along the shorter side of `free` and returns the space left over.
    private static func place(
        _ row: ArraySlice<(index: Int, area: Double)>,
        sum: Double,
        in free: CGRect,
        into out: inout [CGRect]
    ) -> CGRect {
        if free.width >= free.height {
            // Column on the left, items stacked top to bottom.
            let thickness = sum / Double(free.height)
            var y = Double(free.minY)
            for item in row {
                let height = item.area / thickness
                out[item.index] = CGRect(x: Double(free.minX), y: y, width: thickness, height: height)
                y += height
            }
            return CGRect(x: Double(free.minX) + thickness, y: Double(free.minY),
                          width: max(0, Double(free.width) - thickness), height: Double(free.height))
        } else {
            // Row along the top, items left to right.
            let thickness = sum / Double(free.width)
            var x = Double(free.minX)
            for item in row {
                let width = item.area / thickness
                out[item.index] = CGRect(x: x, y: Double(free.minY), width: width, height: thickness)
                x += width
            }
            return CGRect(x: Double(free.minX), y: Double(free.minY) + thickness,
                          width: Double(free.width), height: max(0, Double(free.height) - thickness))
        }
    }
}

extension CGRect {
    /// Shrinks every side by `amount`, never producing negative sizes.
    func shrunk(by amount: CGFloat) -> CGRect {
        let dx = min(amount, width / 2)
        let dy = min(amount, height / 2)
        return CGRect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}
