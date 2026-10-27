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
    /// P0.1 裁切候选来源（`content_envelope` / `paper_envelope` / `fold_trim` /
    /// `content_bounds` / `page_left_inset` / `detected` / `proposed`）。
    var cropSource: String? = nil
    /// P0.1 纸张边界（归一化，左上原点）；nil 表示没有可靠候选。
    var paperEnvelope: QuadPayload? = nil
    /// P0.1 纸内强内容包络；nil 表示没有可靠内容。
    var contentEnvelope: QuadPayload? = nil
    /// P0.1 候选外侧仍像纸面的像素比例；用于判断是否需要 refine。
    var envelopeBackgroundResidual: Double? = nil
    /// P0.1 候选内的文字包围盒覆盖率；<1 表示候选可能切到文字。
    var envelopeTextCoverage: Double? = nil
    /// 表格安全门拒绝裁切时，是否把候选框外背景刷成白色（保留原图缩放/表格）。
    var backgroundWhitened: Bool? = nil
    /// P0.1 是否执行了第二次几何 refine。
    var envelopeRefineApplied: Bool? = nil
    /// P0.1 候选未采用的原因（`too_large` / `too_small` / `degenerate` / `no_envelope`）。
    var envelopeSkipReason: String? = nil
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
    /// 表格安全门参照页的表格 bbox（左上原点），用于解释 refine。
    var tableSafetyOriginalRects: [QuadPayload]? = nil
    /// P1 纸面光照压平是否真正应用；nil/`false` 时底座写回原图。
    var illuminationApplied: Bool? = nil
    /// P1 回退原因（`no_paper` / `low_gain` / `low_variance_reduction` / `original_filter` 等）。
    var illuminationFallbackReason: String? = nil
    /// 判为纸面的像素覆盖率；用于解释是否做了强增益。
    var illuminationPaperCoverage: Double? = nil
    /// P1 目标纸白亮度与增益分位（p50/max），供 A/B 对比。
    var illuminationTargetLuminance: Double? = nil
    var illuminationGainP50: Double? = nil
    var illuminationGainMax: Double? = nil
    /// 背景场亮度方差（压平前/后）；Gate P1 的降幅证据。
    var illuminationVarianceBefore: Double? = nil
    var illuminationVarianceAfter: Double? = nil
    /// P1 自身耗时；`elapsedMilliseconds` 仍只统计边界裁切。
    var illuminationElapsedMilliseconds: Int? = nil
    /// P1 是否拿到可靠的表格保护信息；false 时不启用 P1（避免表结构回归）。
    var illuminationTableGuardAvailable: Bool? = nil
    /// 表格 guard 来源：`p0_crop_safety` / `vision_structure` / `content_fallback` / `grid_fallback` / `unavailable`。
    var illuminationTableGuardSource: String? = nil
    /// 通用表格 guard 自身的结构识别耗时（仅未裁切页）。
    var illuminationTableGuardElapsedMilliseconds: Int? = nil
    /// P1 禁用的表格区域数量（表格结构由 P0 表格安全门提供）。
    var illuminationProtectedTableCount: Int? = nil
    /// P2 前置测量：文字行数量、水平带数量与倾角分布（P2 T020/T022）。
    var textLineCount: Int? = nil
    var textLineBandCount: Int? = nil
    var textLineMedianAngleDegrees: Double? = nil
    var textLineP90AngleDegrees: Double? = nil
    var textLineMaxAngleDegrees: Double? = nil
    var textLineAnalysisElapsedMilliseconds: Int? = nil
    /// 裁切是否真正应用到底座；P0 表格 A/B 未过时为 false（只诊断）。
    var cropApplied: Bool = false
    var elapsedMilliseconds: Int
    var fallbackReason: String?
    var createdAt: Date
}
