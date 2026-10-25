import CoreGraphics
import Foundation
import Vision

/// 拍后页面边界细化（page-preprocess P0 / FR-001）。
///
/// 与实时取景的 `VisionEdgeDetector` 分开：
/// - 实时路径要追帧率，矩形检测 + 条件性文档分割；
/// - 拍后/相册导入只跑一次，直接以 Apple 文档分割的页面四边形为首选。
///
/// 只做“页边候选 + 安全选择”，不做裁切/透视/OCR；调用方拿到 quad 后仍走
/// `PageLayoutMapper` / `ImagePipeline` 的确定性几何。这样即使模型/框架升级，
/// 也不会把文字裁掉：选择阶段用墨迹包围盒做否决。
enum PageBoundaryDetector {
    struct Detection: Equatable, Sendable {
        var quad: Quad
        /// Vision 文档分割置信度（0...1）。
        var confidence: Float
        var area: Double
    }

    /// 文档分割的页面四边形。`orientation` 与图片 EXIF 方向一致。
    static func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> Detection? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let quad = Quad(
            topLeft: flipY(observation.topLeft),
            topRight: flipY(observation.topRight),
            bottomRight: flipY(observation.bottomRight),
            bottomLeft: flipY(observation.bottomLeft)
        )
        guard !quad.isDegenerate,
              quad.area >= 0.12,
              quad.area <= 0.995
        else { return nil }
        return Detection(
            quad: quad,
            confidence: observation.confidence,
            area: quad.area
        )
    }

    /// 选择最终页面四边形：检测到的页面必须**包含**已知墨迹包围盒，
    /// 否则退回提议 quad（不裁字优先）。
    static func choose(
        proposed: Quad,
        detected: Detection?,
        inkBounds: CGRect?
    ) -> Quad {
        // 真机 iPhone 13 实测：`VNDetectDocumentSegmentationRequest` 的
        // `observation.confidence` 返回 0，但 area/边几何有效。置信度只作遥测，
        // 不能当硬门；真正否决靠退化检测 + 墨迹覆盖率。
        guard let detected,
              !detected.quad.isDegenerate
        else { return proposed }
        if let inkBounds, !inkBounds.isEmpty {
            let covered = intersectionArea(detected.quad.boundingRect, inkBounds)
                / max(inkBounds.width * inkBounds.height, 0.0001)
            guard covered >= 0.98 else { return proposed }
        }
        // 检测框与提议框几乎重合时保留提议（避免无意义抖动）。
        if detected.quad.meanVertexDistance(to: proposed) < 0.01 {
            return proposed
        }
        return detected.quad
    }

    private static func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
