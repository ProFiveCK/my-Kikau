import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk 1999) — lays out
/// rectangles proportional to a set of values, choosing row breaks that keep
/// each rectangle's aspect ratio close to square rather than letting small
/// items degenerate into unreadable slivers.
public enum SquarifiedTreemap {
    /// Returns one rect per input value, same order/count as `values`.
    /// Non-positive values get `.zero` (skipped entirely by callers).
    public static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        guard rect.width > 0, rect.height > 0 else { return result }

        let positiveIndices = values.indices.filter { values[$0] > 0 }
        guard !positiveIndices.isEmpty else { return result }

        let total = positiveIndices.reduce(0.0) { $0 + values[$1] }
        guard total > 0 else { return result }

        let area = Double(rect.width) * Double(rect.height)
        let areas = values.map { $0 > 0 ? ($0 / total) * area : 0 }

        squarify(indices: positiveIndices, areas: areas, rect: rect, result: &result)
        return result
    }

    /// Worst (largest) width:height ratio among a candidate row, at a given
    /// fixed short-side length. Lower is squarer / more legible.
    private static func worst(_ rowAreas: [Double], side: Double) -> Double {
        guard !rowAreas.isEmpty, side > 0 else { return .infinity }
        let rowSum = rowAreas.reduce(0, +)
        guard rowSum > 0 else { return .infinity }
        let thickness = rowSum / side
        guard thickness > 0 else { return .infinity }
        var maxRatio = 0.0
        for a in rowAreas {
            let length = (a / rowSum) * side
            guard length > 0 else { continue }
            maxRatio = max(maxRatio, max(length, thickness) / min(length, thickness))
        }
        return maxRatio
    }

    private static func squarify(indices: [Int], areas: [Double], rect: CGRect, result: inout [CGRect]) {
        guard !indices.isEmpty, rect.width > 0.5, rect.height > 0.5 else { return }
        if indices.count == 1 {
            result[indices[0]] = rect
            return
        }

        // Grow a row greedily while it keeps improving (or not worsening) the
        // worst aspect ratio in that row; stop and start a new row otherwise.
        let side = Double(min(rect.width, rect.height))
        var row: [Int] = [indices[0]]
        var rowAreas: [Double] = [areas[indices[0]]]
        var bestWorst = worst(rowAreas, side: side)

        var consumed = 1
        while consumed < indices.count {
            let nextIdx = indices[consumed]
            let candidateAreas = rowAreas + [areas[nextIdx]]
            let candidateWorst = worst(candidateAreas, side: side)
            if candidateWorst <= bestWorst {
                row.append(nextIdx)
                rowAreas = candidateAreas
                bestWorst = candidateWorst
                consumed += 1
            } else {
                break
            }
        }

        let rowSum = rowAreas.reduce(0, +)
        let thickness = rowSum / side
        // Rows run along the shorter side; "vertical" here means the row is a
        // full-height strip on the left (short side = height), items stacked
        // within it top-to-bottom. Otherwise it's a full-width strip on top,
        // items placed left-to-right.
        let layoutVertically = rect.width >= rect.height

        let rowRect: CGRect
        let remainderRect: CGRect
        if layoutVertically {
            let stripWidth = CGFloat(min(thickness, Double(rect.width)))
            rowRect = CGRect(x: rect.minX, y: rect.minY, width: stripWidth, height: rect.height)
            remainderRect = CGRect(x: rect.minX + stripWidth, y: rect.minY,
                                    width: max(0, rect.width - stripWidth), height: rect.height)
        } else {
            let stripHeight = CGFloat(min(thickness, Double(rect.height)))
            rowRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: stripHeight)
            remainderRect = CGRect(x: rect.minX, y: rect.minY + stripHeight,
                                    width: rect.width, height: max(0, rect.height - stripHeight))
        }

        var offset: CGFloat = 0
        for idx in row {
            let fraction = rowSum > 0 ? areas[idx] / rowSum : 0
            if layoutVertically {
                let h = rowRect.height * CGFloat(fraction)
                result[idx] = CGRect(x: rowRect.minX, y: rowRect.minY + offset, width: rowRect.width, height: h)
                offset += h
            } else {
                let w = rowRect.width * CGFloat(fraction)
                result[idx] = CGRect(x: rowRect.minX + offset, y: rowRect.minY, width: w, height: rowRect.height)
                offset += w
            }
        }

        squarify(indices: Array(indices[consumed...]), areas: areas, rect: remainderRect, result: &result)
    }
}
