import Foundation
import Testing
@testable import Zhixia

/// 候选择优策略回归网（US1 / FR-001~003）：两级面积兜底、包含降权、无包含时与现状一致。
///
/// 纯函数测试——直接喂候选集合，不跑 Vision（模拟器上矩形检测对合成图像不可靠，
/// 策略回归必须确定性）。策略入口：`DetectionStrategy.select(rawCandidates:idCardWindow:)`。
struct EdgeDetectionStrategyTests {
    private func rectQuad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: x0, y: y0),
            topRight: CGPoint(x: x1, y: y0),
            bottomRight: CGPoint(x: x1, y: y1),
            bottomLeft: CGPoint(x: x0, y: y1)
        )
    }

    // MARK: - US1 (a) 两级面积兜底（FR-002）

    @Test("Tier 2 admits a near-full candidate when the 0.96 cap filters tier 1 to empty")
    func tierTwoFallbackAdmitsNearFull() {
        // 近拍书占满画面：外框面积 0.9604 > 0.96 —— 现状会把它静默过滤掉。
        let nearFull = rectQuad(0.01, 0.01, 0.99, 0.99)
        #expect(nearFull.area > 0.96)

        let selection = DetectionStrategy.select(rawCandidates: [nearFull], idCardWindow: nil)
        #expect(selection != nil)
        #expect(selection?.tier == 2)
        #expect(selection?.quad == nearFull)
    }

    @Test("Tier 2 picks the best-scoring near-full when several are admitted")
    func tierTwoPicksBestNearFull() {
        let a = rectQuad(0.01, 0.01, 0.99, 0.99) // 0.9604 × 居中 1.0 = 0.9604
        let b = rectQuad(0.02, 0.0, 1.0, 0.985)  // 面积更大但略偏心 → 评分更低
        #expect(a.score() > b.score())

        let selection = DetectionStrategy.select(rawCandidates: [b, a], idCardWindow: nil)
        #expect(selection?.tier == 2)
        #expect(selection?.quad == a)
    }

    @Test("Mixed pool keeps the 0.96 cap: near-full cannot beat mid-size candidates")
    func mixedPoolKeepsCap() {
        // 0.96 上限的原始职责（过滤整幅误检）在混合候选池下保持不变。
        let nearFull = rectQuad(0.0, 0.0, 0.99, 0.99) // 面积 0.9801 → 仅二级
        let mid = rectQuad(0.1, 0.1, 0.9, 0.9) // 面积 0.64 → 一级

        let selection = DetectionStrategy.select(rawCandidates: [nearFull, mid], idCardWindow: nil)
        #expect(selection?.tier == 1)
        #expect(selection?.quad == mid)
    }

    // MARK: - US1 (b) 包含降权（FR-001 / FR-003）

    @Test("A contained interior quad loses to its outer frame despite a higher raw score")
    func containmentDownweightFlipsSelection() {
        // 外框：梯形（略偏斜、略偏心 → 平方/居中评分被压低）；
        // 内框：居中方正 —— 原始评分更高，复现「内部矩形反超」症状。
        let outer = Quad(
            topLeft: CGPoint(x: 0.2, y: 0.2),
            topRight: CGPoint(x: 0.8, y: 0.2),
            bottomRight: CGPoint(x: 0.72, y: 1.0),
            bottomLeft: CGPoint(x: 0.28, y: 1.0)
        )
        let inner = rectQuad(0.2, 0.2, 0.8, 0.8)

        // 前置条件（不成立则用例无效）：
        #expect(inner.containment(in: outer) >= 0.9)
        #expect(inner.score() > outer.score())

        // 降权后外框必胜（FR-001：可信外框存在时内部矩形不得胜出）。
        let selection = DetectionStrategy.select(rawCandidates: [inner, outer], idCardWindow: nil)
        #expect(selection?.quad == outer)

        // 外框缺失时内部矩形仍可胜出（配合兜底，绝不空手）。
        let only = DetectionStrategy.select(rawCandidates: [inner], idCardWindow: nil)
        #expect(only?.quad == inner)
    }

    @Test("Near-duplicate candidates do not penalize each other")
    func nearDuplicatesNotPenalized() {
        // 矩形检测与文档分割常对同一个外框给出两次近似结果——
        // 互包含 ≥0.9 的近重复候选不得互相压分（否则真外框被自己的重复项降权）。
        let outer = rectQuad(0.1, 0.1, 0.9, 0.9)
        let duplicate = rectQuad(0.1, 0.1, 0.9, 0.9)
        let inner = rectQuad(0.3, 0.3, 0.7, 0.7)

        let selection = DetectionStrategy.select(
            rawCandidates: [outer, duplicate, inner],
            idCardWindow: nil
        )
        #expect(selection?.quad == outer)
    }

    // MARK: - US1 (c) 无包含关系 → 行为与现状一致

    @Test("Without containment the plain score decides, matching current behavior")
    func plainScoreWhenNoContainment() {
        let centered = rectQuad(0.25, 0.25, 0.75, 0.75) // score = 0.25
        let big = rectQuad(0.0, 0.4, 1.0, 0.9) // 面积 0.5、略偏心 → score ≈ 0.35
        // 前置条件：无包含关系（降权不生效）。
        #expect(centered.containment(in: big) < 0.9)
        #expect(big.containment(in: centered) < 0.9)
        #expect(big.score() > centered.score())

        let selection = DetectionStrategy.select(rawCandidates: [centered, big], idCardWindow: nil)
        #expect(selection?.tier == 1)
        #expect(selection?.quad == big)
    }

    // MARK: - 证件模式窗口语义不变（FR-013）

    @Test("ID card window matching keeps current semantics")
    func idCardWindowUnchanged() {
        let window = Quad.idCardWindow
        let match = rectQuad(0.15, 0.33, 0.85, 0.67) // IoU ≈ 0.87 > 0.45
        let unrelated = rectQuad(0.05, 0.05, 0.3, 0.3) // 与窗口相离

        let selection = DetectionStrategy.select(
            rawCandidates: [match, unrelated],
            idCardWindow: window
        )
        #expect(selection?.quad == match)

        let noMatch = DetectionStrategy.select(rawCandidates: [unrelated], idCardWindow: window)
        #expect(noMatch?.quad == window)
    }

    // MARK: - US2 live 条件性文档分割（FR-004 / plan D6）

    @Test("Live segmentation gate: no confident rectangle candidates triggers document segmentation")
    func liveGateTriggersOnEmptyRectangles() {
        // 矩形检测完全为空（圆角书/低对比度的典型失效）→ 需要补跑分割。
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: []))

        // 只有退化/过小结果同样视为无可信候选。
        let degenerate = rectQuad(0.49, 0.49, 0.51, 0.51) // 面积 0.0004，isDegenerate
        let tooSmall = rectQuad(0.4, 0.4, 0.6, 0.6) // 面积 0.04 < 0.08 下限
        #expect(degenerate.isDegenerate)
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [degenerate, tooSmall]))
    }

    @Test("Live segmentation gate: confident rectangle candidates suppress segmentation")
    func liveGateSuppressedWhenRectanglesExist() {
        // 矩形检测有可信候选 → 走既有路径，不要求分割（性能约束 D6）。
        let confident = rectQuad(0.2, 0.2, 0.8, 0.8) // 面积 0.36，非退化
        #expect(!DetectionStrategy.needsDocumentSegmentation(rectangles: [confident]))

        // 近满幅矩形候选同样算「找到矩形」——不触发分割（由两级兜底接管）。
        let nearFull = rectQuad(0.0, 0.0, 0.99, 0.99)
        #expect(!DetectionStrategy.needsDocumentSegmentation(rectangles: [nearFull]))
    }

    @Test("Document segmentation candidate joins live selection and can win")
    func liveSegmentationCandidateCanWin() {
        // US2 场景：矩形检测只找到封面上一个过小的文字块（被下限过滤），
        // 文档分割给出整本书 → 并入统一择优后胜出。
        let textBlock = rectQuad(0.4, 0.4, 0.6, 0.6) // 面积 0.04 < 0.08
        let book = rectQuad(0.1, 0.1, 0.9, 0.85) // 分割结果：整本书

        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [textBlock]))
        let selection = DetectionStrategy.select(
            rawCandidates: [textBlock, book],
            idCardWindow: nil
        )
        #expect(selection?.quad == book)
    }

    // MARK: - US1 三级兜底门控（spec/live-edge-crop，plan D2 / FR-001~002）

    @Test("Relaxed gate fires only when strict rectangles and segmentation both come up empty")
    func relaxedGateFiresOnDoubleFailure() {
        // 组合 ①：严格候选为空 + 分割无结果 → 触发（折页厚书的典型失效链）。
        #expect(DetectionStrategy.needsRelaxedRectangles(rectangles: [], segmented: nil))

        // 组合 ②：严格候选无可信项（退化/过小，复用 needsDocumentSegmentation 口径）
        // + 分割无结果 → 同样触发。
        let degenerate = rectQuad(0.49, 0.49, 0.51, 0.51) // 面积 0.0004，isDegenerate
        let tooSmall = rectQuad(0.4, 0.4, 0.6, 0.6) // 面积 0.04 < 0.08 下限
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [degenerate, tooSmall]))
        #expect(DetectionStrategy.needsRelaxedRectangles(
            rectangles: [degenerate, tooSmall],
            segmented: nil
        ))
    }

    @Test("Relaxed gate stays closed when strict rectangles have a confident candidate")
    func relaxedGateClosedWhenStrictConfident() {
        // 组合 ③：严格矩形有可信候选 → 不触发（一级照旧命中，行为零回退）。
        let confident = rectQuad(0.2, 0.2, 0.8, 0.8) // 面积 0.36，非退化
        #expect(!DetectionStrategy.needsRelaxedRectangles(rectangles: [confident], segmented: nil))

        // 组合 ④：严格有候选 + 分割有结果 → 双通道可用，更不触发。
        let segmented = rectQuad(0.1, 0.1, 0.9, 0.85)
        #expect(!DetectionStrategy.needsRelaxedRectangles(
            rectangles: [confident],
            segmented: segmented
        ))
    }

    @Test("Relaxed gate stays closed when segmentation produced a result")
    func relaxedGateClosedWhenSegmentedExists() {
        // 组合 ⑤：严格无可信但分割有结果 → 分割候选接管，放宽档不触发
        //（FR-002：不得逐帧常开，已有可用候选时省算力）。
        let segmented = rectQuad(0.1, 0.1, 0.9, 0.85)
        let tooSmall = rectQuad(0.4, 0.4, 0.6, 0.6)
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [tooSmall]))
        #expect(!DetectionStrategy.needsRelaxedRectangles(rectangles: [tooSmall], segmented: segmented))

        // 严格为空 + 分割有结果 → 同样不触发。
        #expect(!DetectionStrategy.needsRelaxedRectangles(rectangles: [], segmented: segmented))
    }

    // MARK: - US1 放宽候选进池择优语义（spec/live-edge-crop，plan D1 / D6）

    @Test("Relaxed-tier candidates join the shared pool and can win")
    func relaxedCandidatesJoinSharedPool() {
        // 折页书场景：严格矩形只命中封面上一个过小的文字块（被下限过滤），
        // 分割也无结果 → 放宽档找到整本书 → 并入统一择优后胜出（出框）。
        let textBlock = rectQuad(0.4, 0.4, 0.6, 0.6) // 面积 0.04 < 0.08
        let book = rectQuad(0.12, 0.1, 0.88, 0.9) // 放宽档候选

        #expect(DetectionStrategy.needsRelaxedRectangles(rectangles: [textBlock], segmented: nil))
        let selection = DetectionStrategy.select(
            rawCandidates: [textBlock, book],
            idCardWindow: nil
        )
        #expect(selection?.quad == book)
    }

    @Test("Relaxed-tier near-full book frame wins through the tier-2 area fallback")
    func relaxedNearFullWinsViaTierTwo() {
        // 近拍折页书占满画面：放宽档唯一候选面积 > 0.96 → 二级兜底（≤1.0）接纳，
        // 不被一级上限静默过滤（中间层填上，成片不再退化全幅）。
        let nearFull = rectQuad(0.005, 0.01, 0.995, 0.99) // 面积 ≈ 0.978
        #expect(nearFull.area > 0.96)

        let selection = DetectionStrategy.select(rawCandidates: [nearFull], idCardWindow: nil)
        #expect(selection != nil)
        #expect(selection?.tier == 2)
        #expect(selection?.quad == nearFull)
    }

    @Test("Full-frame false positive from the relaxed tier stays under the two-tier area guard")
    func relaxedFullFrameStillGuarded() {
        // 放宽档在桌面纹理等杂乱背景上误检整幅 → 与常规候选同池时 0.96 上限
        // 照旧生效（整幅误检防护不变，Edge Case 语义钉死）。
        let falseFullFrame = rectQuad(0.0, 0.0, 0.995, 0.995) // 面积 ≈ 0.99 → 仅二级
        let mid = rectQuad(0.1, 0.1, 0.9, 0.9) // 面积 0.64 → 一级

        let selection = DetectionStrategy.select(
            rawCandidates: [falseFullFrame, mid],
            idCardWindow: nil
        )
        #expect(selection?.tier == 1)
        #expect(selection?.quad == mid)
    }

    @Test("Relaxed-tier interior quad still loses to its container via containment downweight")
    func relaxedInteriorStillDownweighted() {
        // 放宽档一次重跑可命中多个候选（上限 8）——同时给出外框与封面设计框。
        // 内框居中方正原始评分更高（「内部矩形反超」症状），包含降权照常
        // 使外框必胜（语义与严格候选同池时一致）。
        let outer = Quad(
            topLeft: CGPoint(x: 0.12, y: 0.12),
            topRight: CGPoint(x: 0.88, y: 0.12),
            bottomRight: CGPoint(x: 0.7, y: 1.0),
            bottomLeft: CGPoint(x: 0.3, y: 1.0)
        )
        let inner = rectQuad(0.15, 0.15, 0.85, 0.85)

        // 前置条件（不成立则用例无效）：inner 高度包含于 outer 且原始评分更高。
        #expect(inner.containment(in: outer) >= 0.9)
        #expect(inner.score() > outer.score())

        // 降权后外框必胜（0.39 ≈ 0.49×0.35 = 0.17）。
        let selection = DetectionStrategy.select(
            rawCandidates: [inner, outer],
            idCardWindow: nil
        )
        #expect(selection?.quad == outer)
    }

    // MARK: - spec/frame-truth FR-001/002：池单一真源与页面先验门控

    @Test("viablePool filters sub-minimum and degenerate candidates (single source for select and sticky)")
    func viablePoolFiltersSubMinimum() {
        let band = rectQuad(0.4, 0.4, 0.6, 0.55) // 0.2×0.15 = 0.03 < minArea
        let degenerate = rectQuad(0.49, 0.49, 0.51, 0.51) // 面积 0.0004
        let page = rectQuad(0.2, 0.2, 0.8, 0.8) // 0.36
        let pool = DetectionStrategy.viablePool([band, degenerate, page])
        #expect(pool == [page], "只有通过 select 同口径过滤的候选能进入粘滞池")

        // 与 select 的实际使用口径一致：viable 集合中的候选才可能胜出。
        let selection = DetectionStrategy.select(
            rawCandidates: [band, degenerate, page],
            idCardWindow: nil
        )
        #expect(selection?.quad == page)
    }

    @Test("Page-like prior: a sub-page band no longer vetoes document segmentation")
    func pageLikeGateIgnoresSubPageBand() {
        // 真机证据：0.08–0.093 的文字带一票否决了分割与放宽档（页面候选
        // 从未被请求）。pageLikeMinArea=0.25 后：带子不再是「可信页面」。
        let band = rectQuad(0.3, 0.3, 0.7, 0.55) // 0.4×0.25 = 0.10（> minArea、< pageLike）
        #expect(band.area > DetectionStrategy.minArea)
        #expect(band.area < DetectionStrategy.pageLikeMinArea)
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [band]),
                "sub-page 带子必须触发分割（页面先验口径）")
        #expect(DetectionStrategy.needsRelaxedRectangles(rectangles: [band], segmented: nil),
                "sub-page 带子同样不得阻挡放宽档")

        // 边界：0.24（0.6×0.4）触发；0.25（0.5×0.5）抑制。
        let justBelow = rectQuad(0.2, 0.3, 0.8, 0.7) // 0.6×0.4 = 0.24
        let atThreshold = rectQuad(0.25, 0.25, 0.75, 0.75) // 0.5×0.5 = 0.25
        #expect(abs(justBelow.area - 0.24) < 1e-9)
        #expect(abs(atThreshold.area - 0.25) < 1e-9)
        #expect(DetectionStrategy.needsDocumentSegmentation(rectangles: [justBelow]))
        #expect(!DetectionStrategy.needsDocumentSegmentation(rectangles: [atThreshold]))
    }
}
