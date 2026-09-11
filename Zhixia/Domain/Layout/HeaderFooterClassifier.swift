import CoreGraphics
import Foundation

/// 把 bands 的首/末端判定为 pageHeader / pageFooter。
///
/// 规则（**全部**满足才算）：
/// 1. 靠近版心顶/底（contentBounds 的 10% 内）；
/// 2. 带**短**（height < 2.5 × medianLineHeight 且行数 ≤ 4）；
/// 3. 与下一/上一带纵向隔离（gap > 1.6 × medianLineHeight）。
///
/// 三条同时满足是必须的：避免大段正文（height 大、行数多）被误标为 footer。
/// 返回的是 (header 行下标, footer 行下标)，可为 nil。
enum HeaderFooterClassifier {
    static func classify(
        bands: [LayoutBand],
        contentBounds: CGRect,
        medianH: CGFloat
    ) -> (header: [Int]?, footer: [Int]?) {
        guard !bands.isEmpty, contentBounds.height > 0 else { return (nil, nil) }
        let nearTop = contentBounds.maxY - 0.10 * contentBounds.height
        let nearBottom = contentBounds.minY + 0.10 * contentBounds.height

        var header: [Int]? = nil
        if let first = bands.first {
            let nearTopHit = first.frame.maxY > nearTop
            let short = first.frame.height < 2.5 * medianH && first.lineIndices.count <= 4
            let isolated = gapToNext(of: 0, in: bands) > 1.6 * medianH
            if nearTopHit && short && isolated {
                header = first.lineIndices
            }
        }

        var footer: [Int]? = nil
        if bands.count > 1, let last = bands.last {
            let nearBottomHit = last.frame.minY < nearBottom
            let short = last.frame.height < 2.5 * medianH && last.lineIndices.count <= 4
            let isolated = gapToPrev(of: bands.count - 1, in: bands) > 1.6 * medianH
            if nearBottomHit && short && isolated {
                footer = last.lineIndices
            }
        }
        return (header, footer)
    }

    private static func gapToNext(of i: Int, in bands: [LayoutBand]) -> CGFloat {
        guard i + 1 < bands.count else { return 0 }
        return bands[i].frame.minY - bands[i + 1].frame.maxY
    }
    private static func gapToPrev(of i: Int, in bands: [LayoutBand]) -> CGFloat {
        guard i - 1 >= 0 else { return 0 }
        return bands[i - 1].frame.minY - bands[i].frame.maxY
    }
}

