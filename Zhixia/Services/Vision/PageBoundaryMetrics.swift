import CoreGraphics
import Foundation

/// 页边/裁切的确定性指标（page-preprocess P0 / SC-001~003）。
///
/// 只做几何计算，不读像素；输出供 `PagePreprocessReport`、真机 A/B 和测试共用。
enum PageBoundaryMetrics {
    /// 四条边相对水平/垂直的绝对角度（度）：top/bottom vs 水平，left/right vs 垂直。
    static func edgeAnglesDegrees(_ quad: Quad) -> [Double] {
        [
            angleDegrees(from: quad.topLeft, to: quad.topRight, axis: .horizontal),
            angleDegrees(from: quad.bottomLeft, to: quad.bottomRight, axis: .horizontal),
            angleDegrees(from: quad.topLeft, to: quad.bottomLeft, axis: .vertical),
            angleDegrees(from: quad.topRight, to: quad.bottomRight, axis: .vertical)
        ]
    }

    /// 对边角度差（度）：上/下、左/右。越小越平行。
    static func parallelErrorsDegrees(_ quad: Quad) -> (horizontal: Double, vertical: Double) {
        let angles = edgeAnglesDegrees(quad)
        return (
            horizontal: abs(angles[0] - angles[1]),
            vertical: abs(angles[2] - angles[3])
        )
    }

    /// 页外面积比例（以整页/提议页为 1）：1 − 最终 quad 面积。
    /// 不是“背景像素”本身，P0 先作为可复现的裁切量指标。
    static func outsideAreaRatio(_ quad: Quad) -> Double {
        max(0, min(1, 1 - Double(quad.area)))
    }

    private enum Axis { case horizontal, vertical }

    private static func angleDegrees(from a: CGPoint, to b: CGPoint, axis: Axis) -> Double {
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        guard abs(dx) + abs(dy) > 1e-12 else { return 0 }
        let radians: Double
        switch axis {
        case .horizontal:
            radians = atan2(dy, dx)
        case .vertical:
            // 与竖直方向的夹角：atan2(dx, dy)
            radians = atan2(dx, dy)
        }
        return radians * 180 / .pi
    }
}
