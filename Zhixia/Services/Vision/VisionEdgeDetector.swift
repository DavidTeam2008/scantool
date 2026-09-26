import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// 候选择优策略（spec/scan-edge-accuracy，plan D4/D5，FR-001~003）——纯函数，
/// live（`detect(frame:)`）与 still（`detect(imageData:)`）两条路径共用，也便于单测。
///
/// 两项修复：
/// 1. **两级面积兜底**：一级维持现状上限 0.96；为空时二级放宽到 ≤1.0
///    （允许贴边/近满幅——近拍书占满画面的真实外框不再被静默过滤）。
///    混合候选池下 0.96 上限照旧生效（整幅误检防护不变）。
/// 2. **包含降权**：被另一候选高度包含（≥0.9）的内部矩形评分 ×0.35，
///    使外框候选在同一候选集内必胜（封面设计框/文字块不再反超）。
enum DetectionStrategy {
    /// 一级面积上限（现状值，过滤整幅误检）。
    static let primaryMaxArea: Double = 0.96
    /// 二级面积上限（一级为空时放宽到近满幅）。
    static let fallbackMaxArea: Double = 1.0
    /// 触发包含降权的包含度阈值。
    static let containmentThreshold: Double = 0.9
    /// 被包含候选的评分乘数（plan D5：约 0.35）。
    static let containmentPenalty: Double = 0.35
    /// 候选面积下限（现状值）。
    static let minArea: Double = 0.08

    struct Selection: Equatable {
        var quad: Quad
        /// 1 = 常规 0.96 上限；2 = 放宽 ≤1.0 兜底（经 `ZhixiaLog.detectionTier` 记录）。
        var tier: Int
    }

    /// 对原始候选集执行「非退化/面积下限过滤 → 两级面积兜底 → 包含降权择优」。
    /// 证件窗口（比例窗）路径保持现状语义：IoU 匹配优先，无匹配返回窗口本身（FR-013）。
    static func select(rawCandidates: [Quad], idCardWindow: Quad?) -> Selection? {
        let viable = rawCandidates.filter { !$0.isDegenerate && $0.area > minArea }
        let (pool, tier) = twoTierPool(viable)

        if let window = idCardWindow {
            if let match = pool
                .filter({ $0.iou(with: window) > 0.45 })
                .max(by: { $0.score() < $1.score() })
            {
                return Selection(quad: match, tier: tier)
            }
            return Selection(quad: window, tier: tier)
        }

        guard let best = bestCandidate(in: pool) else { return nil }
        return Selection(quad: best, tier: tier)
    }

    /// 两级面积兜底（plan D4）：一级 0.96 上限过滤；为空时二级放宽至 ≤1.0。
    private static func twoTierPool(_ viable: [Quad]) -> (pool: [Quad], tier: Int) {
        let tier1 = viable.filter { $0.area < primaryMaxArea }
        if !tier1.isEmpty {
            return (tier1, 1)
        }
        return (viable.filter { $0.area <= fallbackMaxArea }, 2)
    }

    /// live 条件性文档分割门控（plan D6 / FR-004）：仅当矩形检测**无可信候选**
    /// （无非退化、面积达标的候选）时才补跑 `VNDetectDocumentSegmentationRequest`。
    ///
    /// 文档分割是神经网络请求，逐帧必跑在部分设备上会压帧率；矩形检测「找不到」
    /// 恰是书类目标（圆角/低对比度）的失效信号——条件触发把算力花在需要的帧上。
    /// 检测器 actor 忙时丢帧机制（ViewModel 侧 `isDetecting`）不受影响。
    static func needsDocumentSegmentation(rectangles: [Quad]) -> Bool {
        !rectangles.contains { !$0.isDegenerate && $0.area > minArea }
    }

    /// live 第三级「放宽矩形」门控（spec/live-edge-crop，plan D2 / FR-001~002）：
    /// 仅当严格矩形无可信候选（复用 `needsDocumentSegmentation` 的判定口径）
    /// **且**文档分割也无结果（`segmented == nil`）时返回 true。
    ///
    /// 折页厚书的曲面页边缘不满足矩形检测的直线假设——前两级长期落空正是
    /// 该场景的失效信号；把放宽参数的重跑算力只花在两级都失败的帧上，
    /// 不得逐帧常开（FR-002）。与 `needsDocumentSegmentation` 同风格、同位置，
    /// 触发组合可穷举单测（见 `EdgeDetectionStrategyTests`）。
    static func needsRelaxedRectangles(rectangles: [Quad], segmented: Quad?) -> Bool {
        needsDocumentSegmentation(rectangles: rectangles) && segmented == nil
    }

    /// 择优：`score = 面积 × 居中 × 方正`（评分函数不动），叠加包含降权。
    ///
    /// - 近重复候选（互包含 ≥0.9，如矩形检测与文档分割命中同一外框）不互相压分。
    /// - FR-003 保障：降权不得让结果退化到比「未降权最优」更小的框——
    ///   未降权最优被降权、且降权后赢家反而更小时，改选其最大容器（外框必胜）。
    static func bestCandidate(in pool: [Quad]) -> Quad? {
        guard let plainBest = pool.max(by: { $0.score() < $1.score() }) else { return nil }

        func isPenalized(_ candidate: Quad) -> Bool {
            pool.contains { other in
                other != candidate
                    && candidate.containment(in: other) >= containmentThreshold
                    && other.containment(in: candidate) < containmentThreshold
            }
        }

        let adjusted = pool.map { candidate -> (quad: Quad, score: Double) in
            var score = candidate.score()
            if isPenalized(candidate) {
                score *= containmentPenalty
            }
            return (candidate, score)
        }
        guard let winner = adjusted.max(by: { $0.score < $1.score })?.quad else { return nil }

        if isPenalized(plainBest), winner.area < plainBest.area {
            let containers = pool.filter {
                $0 != plainBest
                    && plainBest.containment(in: $0) >= containmentThreshold
                    && $0.containment(in: plainBest) < containmentThreshold
            }
            if let largestContainer = containers.max(by: { $0.area < $1.area }) {
                return largestContainer
            }
        }
        return winner
    }
}

actor VisionEdgeDetector: EdgeDetecting {
    /// 候选粘滞状态（仅 live 文档路径使用；actor 串行访问保证状态安全）。
    private var sticky = CandidateSticky()

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        detect(
            cgImage: frame.cgImage,
            orientation: .up,
            idCardWindow: idCardWindow,
            stillImage: false
        )
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return detect(
            cgImage: image,
            orientation: imageOrientation(from: source),
            idCardWindow: idCardWindow,
            stillImage: true
        )
    }

    private func detect(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        idCardWindow: Quad?,
        stillImage: Bool
    ) -> Quad? {
        let rectangles = detectRectangles(
            cgImage: cgImage,
            orientation: orientation,
            relaxed: stillImage
        )
        // 分割来源：still 必跑；live 仅在矩形检测无可信候选时条件触发（plan D6），
        // 两条路径的结果并入同一 `DetectionStrategy.select` 统一择优。
        let segmented: Quad?
        if stillImage {
            segmented = detectDocumentQuad(cgImage: cgImage, orientation: orientation)
        } else if DetectionStrategy.needsDocumentSegmentation(rectangles: rectangles) {
            segmented = detectDocumentQuad(cgImage: cgImage, orientation: orientation)
        } else {
            segmented = nil
        }
        // 三级兜底（spec/live-edge-crop，plan D1 / FR-001~002）：live 文档模式在
        // 「严格矩形无可信候选 ∧ 文档分割无结果」时（needsRelaxedRectangles 门控），
        // 以 still 路径同源的放宽参数集再跑一次矩形检测（置信度 0.35 / 最小尺寸
        // 0.08 / 直角容差 28° / 候选上限 8——`detectRectangles(relaxed:)` 单一参数源，
        // 零新参数）；候选并入同一池统一择优——折页厚书的曲面页不满足直线假设，
        // 前两级长期落空的场景由此兜底出框。放宽档不做贴边吸附（still 专属）；
        // 证件模式（idCardWindow）不参与第三级，检测路径保持不变。
        var relaxedRectangles: [Quad] = []
        if !stillImage, idCardWindow == nil {
            let relaxedTriggered = DetectionStrategy.needsRelaxedRectangles(
                rectangles: rectangles,
                segmented: segmented
            )
            if relaxedTriggered {
                relaxedRectangles = detectRectangles(
                    cgImage: cgImage,
                    orientation: orientation,
                    relaxed: true
                )
            }
            ZhixiaLog.relaxedLiveProbe(
                triggered: relaxedTriggered,
                candidates: relaxedRectangles.count
            )
        }
        let rawCandidates = [segmented].compactMap { $0 } + rectangles + relaxedRectangles
        let selection = DetectionStrategy.select(rawCandidates: rawCandidates, idCardWindow: idCardWindow)
        // US3 候选粘滞（spec/wysiwyg-crop，plan D3，FR-006~007）：仅 live 文档
        // 路径（`!stillImage && idCardWindow == nil`）在逐帧独立择优后应用——
        // 摊开书从中线取景时右页与整书外轮廓逐帧交替胜出（面积比 ≈2:1，超
        // smoother 的 areaJump 重置阈值），取景框因此持续跳动、永不锁定；
        // 粘滞让与上次择优相似（IoU ≥ 0.60）的候选优先延续（先稳者胜），
        // 连续 3 帧无相似候选即逃逸清锚（不粘死）。still（快门重检）与证件
        // 模式路径不参与——still 是单帧无振荡问题，证件有比例窗语义。
        let effective: DetectionStrategy.Selection?
        if !stillImage, idCardWindow == nil {
            let gated = sticky.apply(selection: selection, pool: rawCandidates)
            if let selection, let gated, gated.quad != selection.quad {
                ZhixiaLog.stickyOverride(iou: gated.quad.iou(with: selection.quad))
            }
            effective = gated
        } else {
            effective = selection
        }
        ZhixiaLog.detectionTier(
            still: stillImage,
            tier: effective?.tier ?? 0,
            candidates: rawCandidates.count,
            selectedArea: effective?.quad.area ?? 0
        )
        guard var quad = effective?.quad else { return nil }
        // US6（plan D7）：still 路径择优后贴边吸附——检出框普遍内缩 1~3%，
        // 沿外法线恢复真实边缘。证件模式比例窗保持语义不变；live 路径不动。
        // 快门检测与整理页 refine 都经由本方法，单点接入全部受益。
        if stillImage, idCardWindow == nil {
            quad = snapped(quad, cgImage: cgImage, orientation: orientation)
        }
        return quad
    }

    /// still 吸附：quad 是 EXIF 校正后的直立归一化空间，像素采样需要「直立」光栅
    /// （与 `ImagePipeline.loadUpright` 同语义）。非 up 方向先做小尺寸直立缩略，
    /// 失败则放弃吸附——宁可不修，不可错修。
    private func snapped(
        _ quad: Quad,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Quad {
        if orientation == .up {
            return EdgeSnapper.snap(quad: quad, image: cgImage, maxShiftRatio: 0.05)
        }
        guard let upright = uprightThumbnail(of: cgImage, orientation: orientation) else {
            return quad
        }
        return EdgeSnapper.snap(quad: quad, image: upright, maxShiftRatio: 0.05)
    }

    /// EXIF 直立化的小尺寸缩略图（吸附栅格只要 ~160 列，无需全分辨率）。
    private func uprightThumbnail(
        of image: CGImage,
        orientation: CGImagePropertyOrientation,
        maxDimension: CGFloat = 480
    ) -> CGImage? {
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    private func detectRectangles(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        relaxed: Bool
    ) -> [Quad] {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = relaxed ? 0.35 : 0.6
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = relaxed ? 0.08 : 0.25
        request.maximumObservations = relaxed ? 8 : 4
        request.quadratureTolerance = relaxed ? 28 : 20

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.debug("Vision rectangle failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).map(observationToQuad)
    }

    private func detectDocumentQuad(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.debug("Document segmentation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let quad = observationToQuad(observation)
        // 上限交给 DetectionStrategy 的两级兜底：近满幅的文档分割结果
        // （近拍书占满画面）必须能进入二级候选池，而非在此被静默丢弃。
        guard !quad.isDegenerate, quad.area > DetectionStrategy.minArea else {
            return nil
        }
        return quad
    }

    private func observationToQuad(_ observation: VNRectangleObservation) -> Quad {
        Quad(
            topLeft: flipY(observation.topLeft),
            topRight: flipY(observation.topRight),
            bottomRight: flipY(observation.bottomRight),
            bottomLeft: flipY(observation.bottomLeft)
        )
    }

    private func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    private func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }
}
