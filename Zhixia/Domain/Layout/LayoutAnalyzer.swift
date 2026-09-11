import CoreGraphics
import Foundation

/// M1 总入口。输入 OCRLine + Vision 检出的条码 box，输出 PageLayout：
/// - contentBounds / medianLineHeight / medianGap（基本统计）
/// - bands（按大间隙或表标题切出的水平内容带）
/// - regions（header / body / footer）
/// - columns（栏 + 置信度）
/// - anchors（语义锚点）
/// - lineSemantics（与输入 lines 对齐的标签）
///
/// 不读图像像素 —— M1 是纯几何启发式；显著性/边缘等图像信号留给 M3 的配图模块。
enum LayoutAnalyzer {
    static func analyze(
        lines: [OCRLine],
        barcodes: [CGRect] = []
    ) -> PageLayout? {        guard !lines.isEmpty else { return nil }
        let n = lines.count
        let heights = lines.map { $0.boundingBox.height }
        let medianH = LayoutMath.median(of: heights, fallback: 0.02)

        // 0. 先抽锚点（bands 切分需要「遇到表标题就断」）
        let (anchors, semantics, tableTitleIndices) = AnchorExtractor.extract(lines: lines, barcodes: barcodes)

        // 1. 按视觉 Y 排序
        let order = (0..<n).sorted { a, b in
            let la = lines[a].boundingBox, lb = lines[b].boundingBox
            if abs(la.minY - lb.minY) > 0.002 { return la.minY > lb.minY }
            return la.minX < lb.minX
        }

        // 2. 计算 gap 中位数与切带阈值
        var gaps: [CGFloat] = []
        for k in 1..<order.count {
            let prev = lines[order[k - 1]].boundingBox
            let cur = lines[order[k]].boundingBox
            let g = prev.minY - cur.maxY
            if g > 0 { gaps.append(g) }
        }
        let medianGap = gaps.isEmpty ? medianH * 0.4 : LayoutMath.median(of: gaps, fallback: 0.01)
        let gapThreshold = max(medianH * 1.6, medianGap * 2.0, 0.012)

        // 3. 切带
        var bands: [LayoutBand] = []
        var current: [Int] = []
        func flush() {
            if !current.isEmpty {
                let frame = LayoutMath.unionBounds(of: current.map { lines[$0] })
                bands.append(LayoutBand(frame: frame, lineIndices: current))
                current.removeAll(keepingCapacity: true)
            }
        }
        for k in 0..<order.count {
            let i = order[k]
            if k == 0 {
                current = [i]
                continue
            }
            let prev = lines[order[k - 1]].boundingBox
            let cur = lines[i].boundingBox
            let gap = prev.minY - cur.maxY
            let isTitle = tableTitleIndices.contains(i)
            if gap > gapThreshold || isTitle {
                flush()
                current = [i]
            } else {
                current.append(i)
            }
        }
        flush()

        // 4. regions
        let contentBounds = LayoutMath.unionBounds(of: lines)
        let (headerLines, footerLines) = HeaderFooterClassifier.classify(
            bands: bands,
            contentBounds: contentBounds,
            medianH: medianH
        )
        var regions: [LayoutRegion] = []
        if let headerLines, let first = bands.first {
            regions.append(LayoutRegion(kind: .header, frame: first.frame, lineIndices: headerLines))
        }
        for (bi, b) in bands.enumerated() {
            let isHeader = bi == 0 && headerLines != nil
            let isFooter = bi == bands.count - 1 && footerLines != nil
            if isHeader || isFooter { continue }
            regions.append(LayoutRegion(kind: .body, frame: b.frame, lineIndices: b.lineIndices))
        }
        if let footerLines, let last = bands.last, bands.count > 0 {
            // 避免头/尾同时为同一带时重复添加
            if !(bands.count == 1 && headerLines != nil) {
                regions.append(LayoutRegion(kind: .footer, frame: last.frame, lineIndices: footerLines))
            }
        }

        // 5. columns（只看 body）
        let bodyIndices = regions.filter { $0.kind == .body }.flatMap(\.lineIndices)
        let columns = ColumnResolver.resolve(
            lines: lines,
            bodyIndices: bodyIndices,
            contentBounds: contentBounds
        )

        return PageLayout(
            contentBounds: contentBounds,
            medianLineHeight: medianH,
            medianGap: medianGap,
            bands: bands,
            regions: regions,
            columns: columns,
            anchors: anchors,
            lineSemantics: semantics
        )
    }

    /// 零 layout —— 给那些 LayoutAnalyzer.analyze 返回 nil 的边角场景兜底。
    /// `FigureRegionsV2` 仍可消费（只有 anchors 字段必看，bands/columns 都不强依赖）。
    static func zeroLayout() -> PageLayout {
        PageLayout(
            contentBounds: .zero,
            medianLineHeight: 0,
            medianGap: 0,
            bands: [],
            regions: [],
            columns: [],
            anchors: [],
            lineSemantics: []
        )
    }
}
