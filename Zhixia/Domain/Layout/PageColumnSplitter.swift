import CoreGraphics
import Foundation

/// 把一页的行按**分栏**切开，供还原链路按栏排阅读序。
///
/// **为什么必须做**（真机实测，2026-09-12）：教材 / 练习册普遍是左右两栏。
/// 而还原链路里有两处都假设「页面是单栏」——
/// 1. `OnDeviceReadingOrder.clusterParagraphs` 会把**同一视觉行**的碎片合并成一段；
/// 2. `OnDeviceDocumentParser` 最后把所有块按 `(maxY 降序, minX 升序)` **全局**排序。
///
/// 两者叠加的后果是左右栏**逐行交错**：左栏第 4 题的后半句会和右栏第 2 段拼在一起，
/// 再交替输出。用户看到的 Word / PDF 读起来完全是乱的。
///
/// 与 `ColumnResolver` 的分工：那个是给 `PageLayout` **描述**版面的（只吃 body 行、
/// 会丢弃窄栏、要求 gutter 占比 ≥ 6%）；本类型是给**阅读顺序**用的切分器，
/// 语义要求不同 —— **必须无损**：每一行都要落进恰好一栏，否则内容会静默消失。
/// 所以这里只切一刀、不做窄栏丢弃，找不到 gutter 就把全部行当成单栏返回。
enum PageColumnSplitter {
    struct Column: Sendable, Equatable {
        var lines: [OCRLine]
        /// 该栏所有行的 x 外接范围。用于把表格 / 配图 / 条码块归位到正确的栏。
        var xRange: ClosedRange<CGFloat>
    }

    /// 直方图分箱数。120 箱在版心宽 0.9 的页面上约每箱 0.75% 页宽，够细。
    static let bins = 120
    /// gutter 至少要占版心宽度的这个比例才认作分栏。真机两栏教材的 gutter 通常在 4%~8%。
    static let minGutterRatio: CGFloat = 0.035
    /// gutter 中心必须落在版心横向的这个区间内 —— 排除页边留白造成的假 gutter。
    static let innerBand: ClosedRange<CGFloat> = 0.25...0.75
    /// 每栏至少这么多行才认分栏，避免被一行超长标题切成两半。
    static let minLinesPerColumn = 4
    /// 版心太窄（内容基本占满）时不考虑分栏。
    static let minContentWidth: CGFloat = 0.15

    /// 切分。**单栏页面返回恰好一个 `Column`，内含传入的全部行** ——
    /// 调用方在单栏时与改动前完全一致。
    static func split(_ lines: [OCRLine]) -> [Column] {
        let bounds = contentRange(of: lines)
        let whole = [Column(lines: lines, xRange: bounds)]

        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard usable.count >= minLinesPerColumn * 2 else { return whole }

        let width = bounds.upperBound - bounds.lowerBound
        guard width > minContentWidth else { return whole }

        var histogram = [Int](repeating: 0, count: bins)
        for line in usable {
            let low = binIndex(of: line.boundingBox.minX, in: bounds, width: width)
            let high = binIndex(of: line.boundingBox.maxX, in: bounds, width: width)
            for index in low...max(low, high) { histogram[index] += 1 }
        }

        guard let gutter = widestInnerGutter(histogram, bounds: bounds, width: width) else {
            return whole
        }
        // 切点取 gutter 的中点
        let splitX = bounds.lowerBound
            + (CGFloat(gutter.start + gutter.end) / 2 / CGFloat(bins)) * width

        let left = lines.filter { $0.boundingBox.midX < splitX }
        let right = lines.filter { $0.boundingBox.midX >= splitX }
        guard left.count >= minLinesPerColumn, right.count >= minLinesPerColumn else {
            return whole
        }
        return [
            Column(lines: left, xRange: contentRange(of: left)),
            Column(lines: right, xRange: contentRange(of: right))
        ]
    }

    // MARK: - 内部

    private static func contentRange(of lines: [OCRLine]) -> ClosedRange<CGFloat> {
        guard let first = lines.first else { return 0...1 }
        var low = first.boundingBox.minX
        var high = first.boundingBox.maxX
        for line in lines.dropFirst() {
            low = min(low, line.boundingBox.minX)
            high = max(high, line.boundingBox.maxX)
        }
        return low...max(low, high)
    }

    private static func binIndex(of x: CGFloat, in bounds: ClosedRange<CGFloat>, width: CGFloat) -> Int {
        let raw = Int(((x - bounds.lowerBound) / width) * CGFloat(bins))
        return max(0, min(bins - 1, raw))
    }

    /// 找**最宽**的、且中心落在版心内侧区间的全空 run。
    private static func widestInnerGutter(
        _ histogram: [Int],
        bounds: ClosedRange<CGFloat>,
        width: CGFloat
    ) -> (start: Int, end: Int)? {
        var best: (start: Int, end: Int)?
        var index = 0
        while index < bins {
            guard histogram[index] == 0 else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < bins, histogram[end + 1] == 0 { end += 1 }

            let startX = bounds.lowerBound + (CGFloat(index) / CGFloat(bins)) * width
            let endX = bounds.lowerBound + (CGFloat(end + 1) / CGFloat(bins)) * width
            let center = (startX + endX) / 2
            let relative = (center - bounds.lowerBound) / width
            if (endX - startX) >= width * minGutterRatio, innerBand.contains(relative) {
                if best == nil || (end - index) > (best!.end - best!.start) {
                    best = (index, end)
                }
            }
            index = end + 1
        }
        return best
    }
}
