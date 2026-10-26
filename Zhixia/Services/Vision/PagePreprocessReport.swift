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
    /// 页内最左文字行框的 x（全图归一化）；用于解释左缘内收。
    var pageTextLeft: Double? = nil
    /// 页级左缘实际内收量（占页宽比例）；nil 表示未内收。
    var pageLeftInset: Double? = nil
    /// 表格安全门的参照图来源（`page_quad` / `full_original`）。
    var tableSafetyReference: String? = nil
    /// 表格安全门判定（`signature_match` / `geometry_clear` / `mismatch` / `no_tables`）。
    var tableSafetyDecision: String? = nil
    /// 表格安全门读取的参照页/裁切页表格形状（[rows, columns]）。
    var tableSafetyOriginalShapes: [[Int]]? = nil
    var tableSafetyCroppedShapes: [[Int]]? = nil
    /// 裁切是否真正应用到底座；P0 表格 A/B 未过时为 false（只诊断）。
    var cropApplied: Bool = false
    var elapsedMilliseconds: Int
    var fallbackReason: String?
    var createdAt: Date
}
