import CoreGraphics
import Foundation

/// 页面预处理的可观测报告（page-preprocess FR-007）。
///
/// 只写 sidecar JSON，不参与识别/导出决策；用于真机 A/B、回退归因和后续
/// `preprocess.json` 指标汇总。
struct PagePreprocessReport: Codable, Equatable, Sendable {
    struct QuadPayload: Codable, Equatable, Sendable {
        var topLeft: [Double]
        var topRight: [Double]
        var bottomRight: [Double]
        var bottomLeft: [Double]

        init(CGRectPayload rect: CGRect) {
            topLeft = [rect.minX, rect.minY]
            topRight = [rect.maxX, rect.minY]
            bottomRight = [rect.maxX, rect.maxY]
            bottomLeft = [rect.minX, rect.maxY]
        }

        init(_ quad: Quad) {
            topLeft = [quad.topLeft.x, quad.topLeft.y]
            topRight = [quad.topRight.x, quad.topRight.y]
            bottomRight = [quad.bottomRight.x, quad.bottomRight.y]
            bottomLeft = [quad.bottomLeft.x, quad.bottomLeft.y]
        }
    }

    var source: String
    var proposed: QuadPayload
    var detected: QuadPayload?
    var chosen: QuadPayload
    var detectionConfidence: Float? = nil
    var detectedArea: Double? = nil
    var textBounds: QuadPayload? = nil
    var textCoverage: Double? = nil
    var outsideAreaRatio: Double? = nil
    var edgeAnglesDegrees: [Double]? = nil
    var parallelErrorsDegrees: [Double]? = nil
    var safetyMarginRatio: Double
    var foldTrimU: Double?
    /// 折页裁切来源（`dark_fold` / `bright_fold`）；nil 表示未触发。
    var foldTrimSource: String?
    /// 折页裁切会丢弃的左侧文字面积比例（相对全部文字包围盒）。
    var foldTrimTextLossRatio: Double?
    /// 矫正图上检测到的纸面右缘（归一化 u）；用于解释右缘收边。
    var paperRightEdge: Double?
    /// 裁切是否真正应用到底座；P0 表格 A/B 未过时为 false（只诊断）。
    var cropApplied: Bool = false
    var elapsedMilliseconds: Int
    var fallbackReason: String?
    var createdAt: Date
}
