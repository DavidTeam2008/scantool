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

    /// 内容裁切框：文字包围盒外扩 `margin`，夹回页面。
    /// 用于“页外木桌/折页”场景；不改变 OCR/表格识别输入，只作为裁切候选。
    static func contentQuad(
        textBounds: CGRect,
        margin: CGFloat = 0.02
    ) -> Quad? {
        guard !textBounds.isEmpty else { return nil }
        var rect = textBounds.insetBy(dx: -margin, dy: -margin)
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

    /// 轻量文字行框（`VNDetectTextRectanglesRequest`，不跑识别）。
    /// 坐标系已翻转为左上原点，与 `Quad` 一致。
    static func textBoxes(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> [CGRect] {
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
            return []
        }
        return (request.results ?? []).map { observation -> CGRect in
            let box = observation.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    /// 多个文字行框的并集；无文字时返回 nil。
    static func textBounds(boxes: [CGRect]) -> CGRect? {
        guard let first = boxes.first else { return nil }
        return boxes.reduce(first) { $0.union($1) }
    }

    /// 轻量文字包围盒；无文字时返回 nil。
    static func textBounds(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> CGRect? {
        textBounds(boxes: textBoxes(in: image, orientation: orientation))
    }

    /// 落在页面内的文字行框。用**框中心**过滤，避免把页面左缘外的折条
    /// 文字/左页文字算进页内墨迹召回；这是页级左缘内收的标题守卫基础。
    static func textBoxes(in page: Quad, from boxes: [CGRect]) -> [CGRect] {
        let rect = page.boundingRect
        return boxes.filter { box in
            rect.contains(CGPoint(x: box.midX, y: box.midY))
        }
    }

    /// 页级左缘内收结果。
    struct LeftInset: Equatable, Sendable {
        var quad: Quad
        var targetX: CGFloat
        /// 实际内收量占页宽的比例（例如 0.01 = 1% 页宽）。
        var ratio: Double
        /// 页面内最左文字行框的 x；用于证据/回归。
        var textLeft: CGFloat
    }

    /// 真机页级边缘框的最后 1% 左页边内收。
    ///
    /// 只处理已经是页面级（area 0.25..<0.95）的框；内收量默认最多 1% 页宽，
    /// 且必须给页内最左文字保留 `textMargin`（0.3% 图宽）安全边。找不到
    /// 页内文字时不做内收——宁可留页边，不裁字。
    static func pageLeftInset(
        in page: Quad,
        allTextBoxes: [CGRect],
        maxRatio: CGFloat = 0.01,
        textMargin: CGFloat = 0.003
    ) -> LeftInset? {
        guard !page.isDegenerate, page.area >= 0.25, page.area < 0.95 else {
            return nil
        }
        let inside = textBoxes(in: page, from: allTextBoxes)
        guard let textLeft = inside.map(\.minX).min() else { return nil }

        let left = min(page.topLeft.x, page.bottomLeft.x)
        let width = max(
            page.topRight.x - page.topLeft.x,
            page.bottomRight.x - page.bottomLeft.x
        )
        guard width > 0.1 else { return nil }
        let desired = left + width * maxRatio
        let target = min(desired, textLeft - textMargin)
        guard target > left + 0.002 else { return nil }

        var inset = page
        inset.topLeft.x = max(inset.topLeft.x, target)
        inset.bottomLeft.x = max(inset.bottomLeft.x, target)
        guard !inset.isDegenerate,
              inset.area < page.area - 0.0001,
              inset.topLeft.x < inset.topRight.x - 0.1,
              inset.bottomLeft.x < inset.bottomRight.x - 0.1
        else { return nil }

        return LeftInset(
            quad: inset,
            targetX: target,
            ratio: Double((target - left) / width),
            textLeft: textLeft
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
