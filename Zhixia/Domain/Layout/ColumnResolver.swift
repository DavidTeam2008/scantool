import CoreGraphics
import Foundation

/// 基于 x-projection 的栏解析。
///
/// 步骤：
/// 1. 用 `bins`（默认 80）等分 contentBounds 宽度，把 body lines 的 x 区间投影到 histogram；
/// 2. 找连续空槽（gutter）：长度 ≥ 4 个 bin 视作「页面沟槽」；
/// 3. 用沟槽划分栏；总沟槽宽度 / 总宽 < 6% 或切不出 ≥ 2 栏 → 视作单栏。
///
/// 重要边界：
/// - 边上的空槽（页边）会被合并到最近栏的 x0/x1，不单独成栏；
/// - 过窄栏（< 4% contentBounds 宽）丢弃；
/// - 置信度 = `min(1, 沟槽占比 × 4)`。
enum ColumnResolver {
    static func resolve(
        lines: [OCRLine],
        bodyIndices: [Int],
        contentBounds: CGRect,
        bins: Int = 80
    ) -> [LayoutColumn] {
        // 行太少或版心太窄 → 直接单栏
        guard bodyIndices.count >= 4, contentBounds.width > 0.01 else {
            return [LayoutColumn(
                id: 0,
                frame: contentBounds,
                isPrimary: true,
                confidence: 0.4,
                lineIndices: bodyIndices
            )]
        }
        let x0 = contentBounds.minX
        let x1 = contentBounds.maxX
        let width = x1 - x0
        guard width > 0.001 else { return [] }

        // 1. projection
        var occ = [Int](repeating: 0, count: bins)
        for i in bodyIndices {
            let l = lines[i].boundingBox.minX
            let r = lines[i].boundingBox.maxX
            let li = max(0, min(bins - 1, Int(((l - x0) / width) * CGFloat(bins))))
            let ri = max(li + 1, min(bins, Int(ceil(((r - x0) / width) * CGFloat(bins)))))
            for b in li..<ri { occ[b] += 1 }
        }

        // 2. 找连续空槽
        var gutters: [(start: Int, end: Int)] = []
        var i = 0
        while i < bins {
            if occ[i] == 0 {
                var j = i
                while j < bins && occ[j] == 0 { j += 1 }
                if j - i >= 4 { gutters.append((i, j)) }
                i = j
            } else {
                i += 1
            }
        }
        let gutterTotalBins = gutters.reduce(0) { $0 + ($1.end - $1.start) }
        let gutterRatio = Double(gutterTotalBins) / Double(bins)

        if gutters.isEmpty || gutterRatio < 0.06 {
            return [LayoutColumn(
                id: 0,
                frame: contentBounds,
                isPrimary: true,
                confidence: 0.4,
                lineIndices: bodyIndices
            )]
        }

        // 3. 切栏：把沟槽作分隔
        var cuts: [CGFloat] = [x0]
        for g in gutters {
            let cutStart = x0 + (CGFloat(g.start) / CGFloat(bins)) * width
            let cutEnd = x0 + (CGFloat(g.end) / CGFloat(bins)) * width
            cuts.append(cutStart)
            cuts.append(cutEnd)
        }
        cuts.append(x1)
        var xs = cuts.filter { $0 >= x0 && $0 <= x1 }
        xs.sort()
        var merged: [CGFloat] = []
        for v in xs {
            if let last = merged.last, v - last < 0.005 { continue }
            merged.append(v)
        }
        // 必须能切出 ≥ 2 段才叫分栏
        guard merged.count >= 3 else {
            return [LayoutColumn(
                id: 0,
                frame: contentBounds,
                isPrimary: true,
                confidence: 0.35,
                lineIndices: bodyIndices
            )]
        }

        // 4. 构造栏，丢过窄的
        var columns: [LayoutColumn] = []
        for c in 0..<(merged.count - 1) {
            let l = merged[c], r = merged[c + 1]
            let frame = CGRect(x: l, y: contentBounds.minY, width: r - l, height: contentBounds.height)
            if frame.width < width * 0.04 { continue }
            let indices = bodyIndices.filter { i in
                let cx = lines[i].boundingBox.midX
                return cx >= l && cx < r
            }
            columns.append(LayoutColumn(
                id: columns.count,
                frame: frame,
                isPrimary: false,
                confidence: min(1, gutterRatio * 4),
                lineIndices: indices
            ))
        }
        if columns.isEmpty {
            return [LayoutColumn(
                id: 0,
                frame: contentBounds,
                isPrimary: true,
                confidence: 0.35,
                lineIndices: bodyIndices
            )]
        }
        // 标主栏：最宽
        if let widest = columns.indices.max(by: { columns[$0].frame.width < columns[$1].frame.width }) {
            columns[widest].isPrimary = true
        }
        return columns
    }
}
