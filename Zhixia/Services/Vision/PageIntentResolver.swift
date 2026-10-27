import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 自动取景的页面意图解析（P0.2 / CU-T003）。
///
/// 检测器给出的只是“某个四边形”，摊开书场景里它可能是整书外框，也可能
/// 已经是右页内框。`PageIntentResolver` 把用户选择的“左页 / 右页 / 整页”
/// 变成**可执行的候选**：
/// - 整书外框：在透视矫正图上找书脊（复用 `SpreadSplitter`），生成左右页；
/// - 右页内框：如果左缘仍带折页/左页窄条，用左侧折痕裁切把条带去掉；
/// - 单页（A4 等）：没有书脊时直接作为该意图的候选，不做中心硬拆。
///
/// 纯几何/图像规则，不依赖 LLM，也不生成像素；找不到可靠目标时返回 nil，
/// 调用方应保持搜索态而不是拿整摊图凑数。
enum PageIntentResolver {
    enum Source: String, Sendable, Equatable {
        case pageCandidate
        case leftFoldTrim
        case spine
    }

    struct Resolution: Equatable, Sendable {
        var quad: Quad
        var source: Source
        var confidence: Double
    }

    /// 整书外框的归一化宽高比下限。单页通常是 0.5–0.9，摊开书 >0.95；
    /// 阈值只用于“是否值得尝试拆书脊”，最终仍由 `SpreadSplitter` 的
    /// 谷深/贯穿性判定把关。
    static let spreadAspectThreshold: Double = 0.95
    /// 单页候选的宽高比上限（超过它时不把该候选当作已经正确的单页）。
    static let pageAspectMax: Double = 0.98
    /// 目标页最小面积，与 `DetectionStrategy.minArea` 同口径。
    static let minimumTargetArea: Double = 0.15
    /// 书脊置信度低于该值时仍可返回候选，但调用方可据此显示虚线/建议态。
    static let minimumConfidence: Double = 0.30

    static func isSpreadLike(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate else { return false }
        let rect = quad.boundingRect
        guard rect.width >= 0.45, rect.height >= 0.35, quad.area >= 0.20 else {
            return false
        }
        return rect.width / max(rect.height, 0.0001) >= spreadAspectThreshold
    }

    static func isPageLike(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate, quad.area >= minimumTargetArea else { return false }
        let rect = quad.boundingRect
        return rect.width / max(rect.height, 0.0001) <= pageAspectMax
    }

    /// 解析目标页。`selection` 是当前逐帧择优，`candidates` 是同一帧的
    /// 候选池（可包含整书分割、左右页矩形等）。
    ///
    /// 次序刻意是“先信已经贴边的单页，再拆整书”：右页内框通常比整书外框
    /// 拆出来的右半页更贴合；只有当前候选是整书或左页时，才尝试书脊拆分。
    static func resolve(
        selection: Quad?,
        candidates: [Quad],
        intent: CaptureIntent,
        image: CGImage,
        ciContext: CIContext
    ) -> Resolution? {
        guard intent != .wholePage else { return nil }
        let pool = uniqueQuads(([selection].compactMap { $0 } + candidates))

        // ① 当前择优已经是符合意图的单页：优先使用；右页额外尝试去掉
        //    左缘折页/左页窄条（视频 3 的典型成片问题）。
        if let selection, isPageLike(selection), matchesSide(selection, intent: intent) {
            if intent == .rightPage,
               let trimmed = trimLeftFold(selection, image: image, ciContext: ciContext) {
                return trimmed
            }
            return Resolution(quad: selection, source: .pageCandidate, confidence: 0.90)
        }

        // ② 整书外框：在矫正图上找书脊，拆出目标页。按面积从大到小尝试，
        //    避免把页面里的大表格外框当成整书（`isSpreadLike` 已先过滤）。
        let spreads = pool.filter(isSpreadLike).sorted { $0.area > $1.area }
        for spread in spreads {
            if let split = splitSpread(spread, intent: intent, image: image, ciContext: ciContext) {
                return split
            }
        }

        // ③ 没有整书、当前目标也不是选中的单页：池里找符合侧别的单页
        //    （矩形检测有时直接给出左页/右页）。
        let pages = pool
            .filter(isPageLike)
            .filter { matchesSide($0, intent: intent) }
            .sorted { $0.score() > $1.score() }
        if let page = pages.first {
            if intent == .rightPage,
               let trimmed = trimLeftFold(page, image: image, ciContext: ciContext) {
                return trimmed
            }
            return Resolution(quad: page, source: .pageCandidate, confidence: 0.80)
        }

        // ④ 只有一张单页且没有整书候选：A4/单页场景。左右页意图都允许
        //    直接拍这张单页（用户选意图只是为了锁定页面，不是要求硬拆）。
        if spreads.isEmpty,
           let onlyPage = pool
               .filter(isPageLike)
               .filter({ matchesSide($0, intent: intent) })
               .max(by: { $0.area < $1.area }) {
            return Resolution(quad: onlyPage, source: .pageCandidate, confidence: 0.70)
        }
        return nil
    }

    /// 右页从左缘折痕处裁掉折页/左页窄条（`SpreadSplitter.leftFoldTrim`）。
    /// 找不到折痕就返回 nil，不改动原候选。
    static func trimLeftFold(
        _ quad: Quad,
        image: CGImage,
        ciContext: CIContext
    ) -> Resolution? {
        guard isPageLike(quad),
              let rectified = rectifiedImage(quad, image: image, ciContext: ciContext)
        else { return nil }
        // 折页有两种真实形态：暗折条（背面/阴影）和亮折条（折起页仍有
        // 印刷内容，视频 3 的左页窄条属于后者）。两种都尝试，取首个落在
        // 合法左缘范围的折痕；找不到就保持原候选。
        let trims = [
            SpreadSplitter.leftFoldTrim(inRectified: rectified),
            SpreadSplitter.leftBrightFoldTrim(inRectified: rectified)
        ].compactMap { $0 }
        guard let trim = trims.first(where: { $0.u >= 0.03 && $0.u <= 0.35 }) else {
            return nil
        }
        let target = SpreadSplitter.split(quad, at: trim.u).right
        // 折条裁切通常只去掉 5–15% 宽度，不能用整书拆分的 85% 面积门。
        guard isValidTarget(target, within: quad, maxAreaRatio: 0.99) else { return nil }
        let confidence = max(0.35, min(1, SplitProposalConfidence.leftFold(stripDepth: trim.stripDepth)))
        return Resolution(quad: target, source: .leftFoldTrim, confidence: confidence)
    }

    static func splitSpread(
        _ spread: Quad,
        intent: CaptureIntent,
        image: CGImage,
        ciContext: CIContext
    ) -> Resolution? {
        guard isSpreadLike(spread),
              let rectified = rectifiedImage(spread, image: image, ciContext: ciContext)
        else { return nil }
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        guard let spine = analysis.spine else { return nil }
        let parts = SpreadSplitter.split(spread, at: spine.u)
        let target = intent == .leftPage ? parts.left : parts.right
        guard isValidTarget(target, within: spread) else { return nil }
        let confidence = SplitProposalConfidence.spine(
            prominence: analysis.diagnosis.prominence,
            continuity: analysis.diagnosis.continuity
        )
        guard confidence >= minimumConfidence else { return nil }
        return Resolution(quad: target, source: .spine, confidence: confidence)
    }

    /// 目标页必须是非退化、面积达标，并且明显小于整书（避免书脊误判后
    /// 把整页再返回一次）。
    private static func isValidTarget(
        _ target: Quad,
        within source: Quad,
        maxAreaRatio: Double = 0.85
    ) -> Bool {
        !target.isDegenerate
            && target.area >= minimumTargetArea
            && target.area < source.area * maxAreaRatio
            && isPageLike(target)
    }

    static func matchesSide(_ quad: Quad, intent: CaptureIntent) -> Bool {
        let centerX = quad.boundingRect.midX
        switch intent {
        case .rightPage:
            return centerX >= 0.45
        case .leftPage:
            return centerX <= 0.55
        case .wholePage:
            return true
        }
    }

    private static func uniqueQuads(_ quads: [Quad]) -> [Quad] {
        var result: [Quad] = []
        for quad in quads where !quad.isDegenerate {
            if result.contains(where: { $0.iou(with: quad) >= 0.98 }) { continue }
            result.append(quad)
        }
        return result
    }

    /// 四边形 → 透视矫正图（与 `ReviewViewModel` / `ImagePipeline` 同源语义：
    /// y 翻转到 Core Image 坐标，长边限 600px，只供书脊亮度扫描）。
    static func rectifiedImage(
        _ quad: Quad,
        image: CGImage,
        ciContext: CIContext,
        maxLongestEdge: CGFloat = 600
    ) -> CGImage? {
        guard !quad.isDegenerate else { return nil }
        let ciImage = CIImage(cgImage: image)
        let size = ciImage.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = quad.pixelPoints(imageSize: size)
        func ciPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: size.height - point.y)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = ciPoint(pixels.0)
        filter.topRight = ciPoint(pixels.1)
        filter.bottomRight = ciPoint(pixels.2)
        filter.bottomLeft = ciPoint(pixels.3)
        guard var output = filter.outputImage else { return nil }
        let longest = max(output.extent.width, output.extent.height)
        if longest > maxLongestEdge {
            let scale = maxLongestEdge / longest
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(output, from: output.extent)
    }
}
