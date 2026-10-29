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
        /// 亮缝/文字间隙（白内边距、无阴影书脊——视频 8）。
        case gutter
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
    /// 拆分目标的宽高比上限。照片是 3:4，竖版书页在**归一化**坐标里的
    /// 宽高比可以接近 1.0（视频 9 左页 0.991）；这里只挡整摊（>1.2），
    /// 不沿用页面候选的 0.98。
    static let targetAspectMax: Double = 1.10
    /// 目标页最小面积，与 `DetectionStrategy.minArea` 同口径。
    static let minimumTargetArea: Double = 0.15
    /// 意图拆分（书脊/亮缝）的目标页最小面积：小书/远距离/边缘裁切时
    /// 一页只占画面 6%~12%（视频 10 左页 0.071、视频 9 左页 0.098）。
    static let splitTargetMinimumArea: Double = 0.06
    /// 书脊置信度低于该值时仍可返回候选，但调用方可据此显示虚线/建议态。
    static let minimumConfidence: Double = 0.30

    static func isSpreadLike(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate, !isScreenEdgeFrame(quad) else { return false }
        let rect = quad.boundingRect
        guard rect.width >= 0.45, rect.height >= 0.35, quad.area >= 0.20 else {
            return false
        }
        return rect.width / max(rect.height, 0.0001) >= spreadAspectThreshold
    }

    /// 检测器兜底把“整个画面外框”当成文档时，会得到一个近满幅/四边贴边的
    /// 矩形。它不是书页，也不是整摊：用它当包络会画出贴屏一周的假框，用它
    /// 拍/拆会把整张照片当成页面（视频 7 的 00:55 场景）。
    ///
    /// 判据只拒绝**近满幅**或**同时贴满左右与上下**的框；书本真实占满宽度、
    /// 但上下仍有页边距时不会被误杀。
    static func isScreenEdgeFrame(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate else { return true }
        if quad.area >= 0.97 { return true }
        let rect = quad.boundingRect
        let fillsWidth = rect.minX <= 0.005 && rect.maxX >= 0.995
        let fillsHeight = rect.minY <= 0.005 && rect.maxY >= 0.995
        return fillsWidth && fillsHeight
    }

    static func isPageLike(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate, quad.area >= minimumTargetArea else { return false }
        let rect = quad.boundingRect
        return rect.width / max(rect.height, 0.0001) <= pageAspectMax
    }

    /// 近距单页判定（CF-T011a）：用于“贴画幅边时是否允许拍单页”。
    ///
    /// **不要复用 `isSpreadLike`**：它用的是同一归一化宽高比，而 3:4 照片里
    /// 一页竖版书页的归一化宽高比本来就 ≈1.0（视频 9 左页 0.991），
    /// `spreadAspectThreshold=0.95` 会把单页也判成整摊。整摊是**两页并排**，
    /// 归一化宽高比通常 ≥1.5（视频 13 实测 ≈2.1、视频 12 裁切整摊 ≈2.3）。
    /// 因此近距单页用独立阈值 1.30：<1.30 视为单页，≥1.30 视为整摊/整书。
    static let singlePageAspectMax: Double = 1.30

    static func isSinglePageForCapture(_ quad: Quad) -> Bool {
        guard !quad.isDegenerate, quad.area >= minimumTargetArea else { return false }
        let rect = quad.boundingRect
        return rect.width / max(rect.height, 0.0001) < singlePageAspectMax
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
        let envelopeQuad = envelope(selection: selection, candidates: candidates)
        func accept(_ resolution: Resolution) -> Resolution? {
            acceptTarget(resolution, envelope: envelopeQuad, intent: intent)
        }

        // ① 当前择优已经是符合意图的单页：优先使用；右页额外尝试去掉
        //    左缘折页/左页窄条（视频 3 的典型成片问题）。
        if let selection, isPageLike(selection), matchesSide(selection, intent: intent) {
            if intent == .rightPage,
               let trimmed = trimLeftFold(selection, image: image, ciContext: ciContext),
               let accepted = accept(trimmed) {
                return accepted
            }
            if let accepted = accept(Resolution(
                quad: selection,
                source: .pageCandidate,
                confidence: 0.90
            )) {
                return accepted
            }
        }

        // ①b 池里已有符合意图的单页候选：优先于整摊拆分。
        //    视频 10：整摊包络把背景墙也包进来（top≈0.05，书页 top≈0.34），
        //    拆包络得到的目标会带墙；池里的右页/左页矩形本身是干净的，
        //    应当先信它。面积门用目标门的 8%（左页小到 0.087），宽高比用
        //    目标上限 1.10 挡掉整摊；`acceptTarget` 再做包络/意图侧校验。
        let targetPages = pool
            .filter { !$0.isDegenerate && $0.area >= 0.06 }
            .filter { !isSpreadLike($0) }
            .filter { matchesSide($0, intent: intent) }
            .filter {
                let rect = $0.boundingRect
                let aspect = rect.width / max(rect.height, 0.0001)
                return aspect >= 0.45 && aspect <= targetAspectMax
            }
            .sorted { $0.score() > $1.score() }
        for page in targetPages {
            // 页候选必须“够一整页”：以包络的一半为期望面积（整摊）或整页
            // （单页）。视频 10 左页候选只有 0.071，是页内左栏，不是整页；
            // 这种窄条要留给整摊拆分（②c），否则左页右栏会被切掉。
            if let envelopeQuad,
               page.meanVertexDistance(to: envelopeQuad) > 0.01 {
                let expected = isSpreadLike(envelopeQuad)
                    ? envelopeQuad.area / 2
                    : envelopeQuad.area
                guard expected > 0, page.area >= expected * 0.85 else { continue }
            }
            if let accepted = accept(Resolution(
                quad: page,
                source: .pageCandidate,
                confidence: 0.85
            )) {
                return accepted
            }
        }

        // ② 整书外框：在矫正图上找书脊，拆出目标页。按面积从大到小尝试，
        //    避免把页面里的大表格外框当成整书（`isSpreadLike` 已先过滤）。
        let spreads = pool.filter(isSpreadLike).sorted { $0.area > $1.area }
        for spread in spreads {
            if let split = splitSpread(spread, intent: intent, image: image, ciContext: ciContext),
               let accepted = accept(split) {
                return accepted
            }
        }

        // ②b 被屏幕裁掉的整摊：宽高比还在整摊档，但面积/宽度不够
        // `isSpreadLike`（预览只有 9:16，摊开书右页常被裁到屏幕外）。
        // 目标页一侧完整可见时，亮缝模型仍能拆出它（视频 8 的左页）。
        if let envelopeQuad,
           isClippedSpread(envelopeQuad, intent: intent),
           let split = splitClippedSpread(
               envelopeQuad,
               intent: intent,
               image: image,
               ciContext: ciContext
           ),
           let accepted = accept(split) {
            return accepted
        }

        // ②c 用页对包络本身拆分：② 的 spreads 来自候选池，页对包络是
        //    构造出来的，不在池里；它才是视频 10 的书。没有“够一整页”的
        //    页候选时（左页被裁成 0.071），在这里按书脊/亮缝拆。
        if let envelopeQuad,
           isSpreadLike(envelopeQuad),
           let split = splitSpread(
               envelopeQuad,
               intent: intent,
               image: image,
               ciContext: ciContext
           ),
           let accepted = accept(split) {
            return accepted
        }

        // ③ 没有整书、当前目标也不是选中的单页：池里找符合侧别的单页
        //    （矩形检测有时直接给出左页/右页）。
        let pages = pool
            .filter(isPageLike)
            .filter { matchesSide($0, intent: intent) }
            .sorted { $0.score() > $1.score() }
        for page in pages {
            if intent == .rightPage,
               let trimmed = trimLeftFold(page, image: image, ciContext: ciContext),
               let accepted = accept(trimmed) {
                return accepted
            }
            if let accepted = accept(Resolution(
                quad: page,
                source: .pageCandidate,
                confidence: 0.80
            )) {
                return accepted
            }
        }

        // ④ 只有一张单页且没有整书候选：A4/单页场景。左右页意图都允许
        //    直接拍这张单页（用户选意图只是为了锁定页面，不是要求硬拆）。
        if spreads.isEmpty,
           let onlyPage = pool
               .filter(isPageLike)
               .filter({ matchesSide($0, intent: intent) })
               .max(by: { $0.area < $1.area }),
           let accepted = accept(Resolution(
               quad: onlyPage,
               source: .pageCandidate,
               confidence: 0.70
           )) {
            return accepted
        }
        return nil
    }

    /// 目标页与包络的一致性校验（视频 9：右页栏间距/画面边缘的假目标）。
    ///
    /// - 目标就是包络（单页/A4）：直接接受；
    /// - 目标必须在包络内（2% 贴边容差），否则是画面边缘/桌面矩形；
    /// - 目标必须落在意图侧（右页在包络中心右侧、左页在左侧），
    ///   否则是“右页意图却给了左页/页内栏”；
    /// - 目标宽高比 0.45~0.98：窄竖条是页内文字栏/照片栏，不是书页。
    private static func acceptTarget(
        _ resolution: Resolution,
        envelope: Quad?,
        intent: CaptureIntent
    ) -> Resolution? {
        guard let envelope else { return nil }
        let target = resolution.quad
        guard !target.isDegenerate else { return nil }
        if target.meanVertexDistance(to: envelope) <= 0.01 {
            return resolution
        }
        let rect = target.boundingRect
        let aspect = rect.width / max(rect.height, 0.0001)
        guard target.area >= 0.06, aspect >= 0.45, aspect <= targetAspectMax else {
            return nil
        }
        let envelopeRect = envelope.boundingRect.insetBy(dx: -0.02, dy: -0.02)
        guard envelopeRect.contains(rect) else { return nil }
        switch intent {
        case .leftPage:
            guard target.center.x < envelope.center.x else { return nil }
        case .rightPage:
            guard target.center.x > envelope.center.x else { return nil }
        case .wholePage:
            return nil
        }
        return resolution
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
        if let split = splitRectified(
            spread,
            intent: intent,
            rectified: rectified,
            minTargetArea: Self.splitTargetMinimumArea
        ) {
            return split
        }
        return nil
    }

    /// 被屏幕裁掉的整摊：宽高比 ≥ 整摊阈值，但面积/宽度不够
    /// `isSpreadLike`（典型：预览 9:16，摊开书右页被裁到屏幕外）。
    ///
    /// 中心偏移是判据：左页意图下包络中心偏右（右页在画面外），右页意图
    /// 下偏左；居中的单页（中心≈0.5）不会走这条路径。
    static func isClippedSpread(_ quad: Quad, intent: CaptureIntent) -> Bool {
        guard intent != .wholePage, !quad.isDegenerate, !isScreenEdgeFrame(quad) else {
            return false
        }
        let rect = quad.boundingRect
        guard rect.width >= 0.35, rect.height >= 0.32, quad.area >= 0.14 else {
            return false
        }
        let aspect = rect.width / max(rect.height, 0.0001)
        guard aspect >= spreadAspectThreshold else { return false }
        switch intent {
        case .leftPage:
            return rect.midX >= 0.55
        case .rightPage:
            return rect.midX <= 0.45
        case .wholePage:
            return false
        }
    }

    /// 裁掉的整摊：先按暗谷书脊拆，失败再按亮缝拆；目标页面积门放宽到
    /// 8%（包络本身可能只占画面 15%~20%，一半页只有 8%~10%）。
    static func splitClippedSpread(
        _ envelope: Quad,
        intent: CaptureIntent,
        image: CGImage,
        ciContext: CIContext
    ) -> Resolution? {
        guard let rectified = rectifiedImage(envelope, image: image, ciContext: ciContext)
        else { return nil }
        return splitRectified(
            envelope,
            intent: intent,
            rectified: rectified,
            minTargetArea: 0.08
        )
    }

    /// 书脊（暗谷）→ 亮缝（白内边距）两级拆分；找不到返回 nil。
    private static func splitRectified(
        _ source: Quad,
        intent: CaptureIntent,
        rectified: CGImage,
        minTargetArea: Double
    ) -> Resolution? {
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        if let spine = analysis.spine {
            let confidence = SplitProposalConfidence.spine(
                prominence: analysis.diagnosis.prominence,
                continuity: analysis.diagnosis.continuity
            )
            if confidence >= minimumConfidence,
               let target = target(from: source, at: spine.u, intent: intent),
               isValidTarget(target, within: source, minArea: minTargetArea) {
                return Resolution(quad: target, source: .spine, confidence: confidence)
            }
        }
        if let gutter = SpreadSplitter.analyzeGutter(inRectified: rectified),
           gutter.confidence >= SplitProposalConfidence.applyThreshold,
           let target = target(from: source, at: gutter.u, intent: intent),
           isValidTarget(target, within: source, minArea: minTargetArea) {
            return Resolution(quad: target, source: .gutter, confidence: gutter.confidence)
        }
        return nil
    }

    private static func target(from source: Quad, at u: Double, intent: CaptureIntent) -> Quad? {
        guard intent != .wholePage else { return nil }
        let parts = SpreadSplitter.split(source, at: u)
        return intent == .leftPage ? parts.left : parts.right
    }

    /// CF-T002：选择实时显示用的“书/整摊包络”。
    ///
    /// 优先级：最大的整摊候选 → 最大的单页候选 → 当前择优（若它至少是
    /// 页面尺度）。不把文字带/表格小块当包络；包络可以暂时不精确，但必须
    /// 能持续显示，供用户对准和拍后精修。
    ///
    /// CF-T004：**绝不回退 `.fullImage`**。整幅画面外框不是页面——把它当包络
    /// 会画出贴屏的假框，并让快门拍下整张照片。没有可信页面时返回 nil，
    /// 由 tracker 保持上一有效包络（hold）或回到搜索态并禁用快门。
    static func envelope(selection: Quad?, candidates: [Quad]) -> Quad? {
        let pool = uniqueQuads(([selection].compactMap { $0 } + candidates))
            .filter { !isScreenEdgeFrame($0) }
        let spreads = pool.filter(isSpreadLike).sorted { $0.area > $1.area }
        if let spread = spreads.first { return spread }

        // 视频 10：检测器给出左页/右页两个干净矩形，但没有整摊；同时有一个
        // 把背景墙包进来的大矩形（≈0.93 宽高比，单看也“像一页”）。两页的
        // 并集才是书；先拼页对，避免包络选到“墙 + 书”的大矩形。
        if let pair = pagePairEnvelope(in: pool) { return pair }

        // 单页：优先“像一页”的宽高比（0.45~0.85）。接近正方形的大矩形
        // 更像场景/桌面，不是书页。
        let pageAspects = pool
            .filter(isPageLike)
            .filter {
                let rect = $0.boundingRect
                let aspect = rect.width / max(rect.height, 0.0001)
                return aspect >= 0.45 && aspect <= 0.85
            }
            .sorted { $0.area > $1.area }
        if let page = pageAspects.first { return page }

        let pages = pool.filter(isPageLike).sorted { $0.area > $1.area }
        if let page = pages.first { return page }

        if let selection,
           !selection.isDegenerate,
           !isScreenEdgeFrame(selection),
           selection.area >= minimumTargetArea,
           isPlausibleEnvelopeShape(selection) {
            return selection
        }
        return nil
    }

    /// 目标页必须是非退化、面积达标，并且明显小于整书（避免书脊误判后
    /// 把整页再返回一次）。
    private static func isValidTarget(
        _ target: Quad,
        within source: Quad,
        maxAreaRatio: Double = 0.85,
        minArea: Double = minimumTargetArea,
        minAspect: Double = 0.45,
        maxAspect: Double = targetAspectMax
    ) -> Bool {
        guard !target.isDegenerate, target.area >= minArea else { return false }
        let rect = target.boundingRect
        let aspect = rect.width / max(rect.height, 0.0001)
        // 下界 0.45：单页/书页的归一化宽高比不会这么窄；再窄的“目标”
        // 是页内文字栏/照片栏（视频 9 的右页栏间距误拆成竖条）。
        return target.area < source.area * maxAreaRatio
            && aspect >= minAspect
            && aspect <= maxAspect
    }

    /// 左右两页的并集包络（视频 10）：检测器常分别给出左页/右页矩形，
    /// 但整摊不可靠；两页相邻、y 区间重叠、并集达到整摊宽高比时，
    /// 用左页左缘 + 右页右缘组成一个倾斜的整摊四边形。
    ///
    /// 只接受“像一页”的候选（宽高比 0.40~1.05、宽 ≥12%、面积 ≥8%）。
    /// 3:4 照片里竖版页的**归一化**宽高比≈1.0（视频 10 右页 1.002），
    /// 不能用 0.90 的页面值；接近正方形的大场景矩形（0.93）在页对里
    /// 会因“两页相邻 + 并集像整摊”被排除。
    static func pagePairEnvelope(in pool: [Quad]) -> Quad? {
        let pages = pool.filter { quad in
            guard !quad.isDegenerate, quad.area >= 0.06 else { return false }
            let rect = quad.boundingRect
            guard rect.width >= 0.12 else { return false }
            let aspect = rect.width / max(rect.height, 0.0001)
            return aspect >= 0.40 && aspect <= 1.05
        }
        guard pages.count >= 2 else { return nil }
        var best: (quad: Quad, area: Double)?
        for i in pages.indices {
            for j in pages.indices where j > i {
                let a = pages[i]
                let b = pages[j]
                let (left, right) = a.center.x <= b.center.x ? (a, b) : (b, a)
                let leftRect = left.boundingRect
                let rightRect = right.boundingRect
                let gap = rightRect.minX - leftRect.maxX
                guard gap >= -0.08, gap <= 0.15 else { continue }
                let overlap = min(leftRect.maxY, rightRect.maxY)
                    - max(leftRect.minY, rightRect.minY)
                guard overlap >= min(leftRect.height, rightRect.height) * 0.5 else {
                    continue
                }
                let union = Quad(
                    topLeft: left.topLeft,
                    topRight: right.topRight,
                    bottomRight: right.bottomRight,
                    bottomLeft: left.bottomLeft
                )
                let rect = union.boundingRect
                let aspect = rect.width / max(rect.height, 0.0001)
                guard aspect >= spreadAspectThreshold, aspect <= 2.6 else { continue }
                if best == nil || union.area > best!.area {
                    best = (union, union.area)
                }
            }
        }
        return best?.quad
    }

    private static func isPlausibleEnvelopeShape(_ quad: Quad) -> Bool {
        let rect = quad.boundingRect
        guard rect.height > 0 else { return false }
        let aspect = rect.width / rect.height
        return aspect >= 0.30 && aspect <= 1.60
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
