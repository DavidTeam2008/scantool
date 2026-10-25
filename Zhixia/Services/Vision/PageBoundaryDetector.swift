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

    /// 内容裁切框：文字包围盒外扩 `margin`，可选与纸张 mask 相交，夹回页面。
    /// 用于“页外木桌/折页”场景；不改变 OCR/表格识别输入，只作为裁切候选。
    static func contentQuad(
        textBounds: CGRect,
        paperBounds: CGRect?,
        margin: CGFloat = 0.02
    ) -> Quad? {
        guard !textBounds.isEmpty else { return nil }
        var rect = textBounds.insetBy(dx: -margin, dy: -margin)
        // 不用 paperBounds 直接相交：木桌/折页 mask 可能切掉左/右文字。
        // 纸张 mask 只作页面范围的旁证；内容裁切以文字框 + 安全边为准。
        _ = paperBounds
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0.1, rect.height > 0.1,
              rect.width * rect.height >= 0.15
        else { return nil }
        return Quad(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        )
    }

    /// 轻量文字包围盒（`VNDetectTextRectanglesRequest`，不跑识别）。
    /// 用于裁切前的墨迹召回否决；无文字时返回 nil。
    static func textBounds(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> CGRect? {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
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
        let boxes = (request.results ?? []).map { observation -> CGRect in
            let box = observation.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        guard !boxes.isEmpty else { return nil }
        return boxes.reduce(boxes[0]) { $0.union($1) }
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
