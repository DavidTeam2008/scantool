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
    var detectionConfidence: Float?
    var detectedArea: Double?
    var safetyMarginRatio: Double
    var elapsedMilliseconds: Int
    var fallbackReason: String?
    var createdAt: Date
}
