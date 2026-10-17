import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// 候选粘滞 v2 hold-through-miss 穷举（spec/case-b-sticky-v2，plan D1，
/// FR-001~003）：Case B 根因是**存在性交替**——摊开书三级检测门控使 live
/// 候选池逐帧近似单源（矩形成功帧池里只有右页、落空帧池里只有整书分割），
/// v1 的同池续锚分支（④）结构性不触发，恒走 miss 透传 + 回摆帧清零 miss，
/// 输出逐帧翻转、永不锁定。v2 在 miss 窗口内维持锚点（与 `QuadSmoother`
/// miss 保留语义对齐），达限仍逃逸。既有 `CandidateStickyTests`（v1 语义）
/// 由参数门控默认值保住，断言零修改（铁律 2）。
struct CandidateStickyV2Tests {
    // MARK: - 存在性交替稳定（FR-001 / Case B 核心）

    @Test("存在性交替稳定：A/B 帧池互斥时 hold 维持锚点，输出不逐帧翻转")
    func holdsThroughExistenceAlternation() {
        var sticky = CandidateSticky()

        // 帧 1（矩形成功帧：池里只有右页）→ 直通起锚。
        let f1 = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(f1?.quad == Self.rightPage)

        // 帧 2（矩形落空帧：池里只有整书分割）→ 池中无锚点相似候选，
        // v1 在此透传整书（跳变源头）；v2 维持锚点。
        let f2 = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(f2?.quad == Self.rightPage, "存在性交替帧必须维持锚点（hold），不得透传整书")
        #expect(f2?.tier == 1, "hold 帧 tier 随锚")

        // 帧 3（右页回归）：相似跟随，miss 清零。
        let f3 = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(f3?.quad == Self.rightPage)

        // 帧 4（再次只有整书）：miss 重新计数，hold 持续吸收交替。
        let f4 = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(f4?.quad == Self.rightPage, "交替被持续吸收，输出不得翻转")
    }

    // MARK: - hold 窗口边界与逃逸（FR-002 / FR-007 不粘死）

    @Test("hold 窗口边界：miss 达限前维持锚点，达限帧清空锚点并透传新择优")
    func escapesAfterMissLimitUnderHold() {
        var sticky = CandidateSticky()
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )

        // 用户真移场（右页离开视场）：连续整书单源帧。
        // 第 1~2 帧维持锚点（hold 窗口内）。
        for expectedMiss in 1...2 {
            let held = sticky.apply(
                selection: Self.wholeSpreadSelection(tier: 1),
                pool: [Self.wholeSpread],
                holdThroughMiss: true
            )
            #expect(held?.quad == Self.rightPage, "miss \(expectedMiss) < missLimit：必须维持锚点")
            #expect(sticky.missCount == expectedMiss)
        }
        // 第 3 帧达限：清空锚点、透传整书（逃逸，不粘死）。
        let escaped = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(escaped?.quad == Self.wholeSpread, "达限必须透传新择优（逃逸）")
        #expect(sticky.missCount == 3)

        // 第 4 帧：无锚点直通，重新起锚整书。
        let reanchored = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(reanchored?.quad == Self.wholeSpread)

        // 探针帧（判别度最大）：右页相似候选回归池中，锚点已是整书 →
        // 相似跟随整书；若旧锚未清，此处会被误 hold/改写回右页而假失败。
        let probe = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPageEnlarged],
            holdThroughMiss: true
        )
        #expect(probe?.quad == Self.wholeSpread, "逃逸后不得再粘滞旧锚点")
    }

    @Test("hold 期间锚点候选回归：相似跟随立即恢复并清零 miss（持续交替永不逃逸）")
    func anchorReturnResumesFollow() {
        var sticky = CandidateSticky()
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )

        // 整书单源帧 ×2：miss 累计到 2（窗口内 hold）。
        for _ in 0..<2 {
            _ = sticky.apply(
                selection: Self.wholeSpreadSelection(tier: 1),
                pool: [Self.wholeSpread],
                holdThroughMiss: true
            )
        }
        #expect(sticky.missCount == 2)

        // 右页回归帧：相似跟随，miss 清零——持久 A/B 交替因此永不触达逃逸。
        let followed = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(followed?.quad == Self.rightPage)
        #expect(sticky.missCount == 0)

        // 再次交替：miss 从 1 重新计（窗口完整可用）。
        let held = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(held?.quad == Self.rightPage)
        #expect(sticky.missCount == 1)
    }

    @Test("nil 间隙与 hold 混合：共用 miss 计数，跨分支累计达限逃逸")
    func nilGapMixesWithHoldMisses() {
        var sticky = CandidateSticky()
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )

        // 整书单源帧（miss=1，hold）→ 检测间隙（miss=2，nil）→
        // 整书单源帧（miss=3，达限逃逸透传）。两条 miss 路径共用计数。
        let held = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(held?.quad == Self.rightPage)
        #expect(sticky.apply(selection: nil, pool: [], holdThroughMiss: true) == nil)
        #expect(sticky.missCount == 2)
        let escaped = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(escaped?.quad == Self.wholeSpread, "混合 miss 达限必须逃逸透传")
    }

    // MARK: - hold 帧择优形态（tier 随锚 / disposition 日志接线）

    @Test("hold 帧返回锚点择优：quad 为锚点、tier 随锚（不用 miss 帧择优 tier）")
    func holdFrameKeepsAnchorTier() {
        var sticky = CandidateSticky()
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 2),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )

        let held = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(held == DetectionStrategy.Selection(quad: Self.rightPage, tier: 2),
                "hold 帧择优必须完整随锚（quad + tier）")
    }

    @Test("disposition 逐帧可辨：anchored / hold / follow / override / gapMiss / escape")
    func dispositionReflectsBranch() {
        var sticky = CandidateSticky()

        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(sticky.lastDisposition == .anchored)

        _ = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(sticky.lastDisposition == .hold)

        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(sticky.lastDisposition == .follow)

        // 同池共存交替：整书当帧胜出但池中有锚点相似候选 enlarged → ④ 改写。
        let overridden = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPageEnlarged],
            holdThroughMiss: true
        )
        #expect(overridden?.quad == Self.rightPageEnlarged)
        #expect(sticky.lastDisposition == .override)

        // 检测间隙（miss=1，锚点=enlarged 存活）。
        #expect(sticky.apply(selection: nil, pool: [], holdThroughMiss: true) == nil)
        #expect(sticky.lastDisposition == .gapMiss)

        // 整书单源帧 ×2：miss=2 hold → miss=3 达限逃逸。
        // （enlarged ⊂ wholeSpread，IoU ≈ 0.487 < 0.60，结构性走不到③/④。）
        let held = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(held?.quad == Self.rightPageEnlarged)
        #expect(sticky.lastDisposition == .hold)
        let escaped = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(escaped?.quad == Self.wholeSpread)
        #expect(sticky.lastDisposition == .escape)
    }

    // MARK: - 参数门控与复位（FR-003 / plan D1~D2）

    @Test("参数门控默认 v1：不传 holdThroughMiss 时存在性交替帧透传新择优")
    func defaultKeepsV1Passthrough() {
        var sticky = CandidateSticky()
        _ = sticky.apply(selection: Self.rightPageSelection(tier: 1), pool: [Self.rightPage])

        // v1 语义：整书单源帧透传整书（Case B 跳变源头——钉住默认门控不漂移）。
        let passthrough = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread]
        )
        #expect(passthrough?.quad == Self.wholeSpread, "默认参数必须保持 v1 透传语义（既有断言零修改）")
        #expect(sticky.lastDisposition == .passthrough)
    }

    @Test("reset 清空锚点与 miss：复位后新择优直通起锚，disposition 归零")
    func resetClearsAnchor() {
        var sticky = CandidateSticky()
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        _ = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(sticky.missCount == 1)

        sticky.reset()
        #expect(sticky.missCount == 0)
        #expect(sticky.lastDisposition == nil)

        // 复位后无锚点：整书直通起锚（不再 hold 回右页）。
        let anchored = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread],
            holdThroughMiss: true
        )
        #expect(anchored?.quad == Self.wholeSpread)
        #expect(sticky.lastDisposition == .anchored)
    }

    // MARK: - sticky → smoother 集成（Case B 机制闭环）

    @Test("集成：存在性交替经 sticky v2 后 smoother 在锁定窗内锁定且不再跳变")
    func alternationStabilizedLocksSmoother() {
        var sticky = CandidateSticky()
        var smoother = QuadSmoother()

        var everLocked = false
        var finalState = QuadTrackState.searching
        // 18 帧（1.2s@15fps）严格 A/B 交替：偶数帧池=[右页]、奇数帧池=[整书]。
        for index in 0..<18 {
            let isRightPageFrame = index % 2 == 0
            let selection = isRightPageFrame
                ? Self.rightPageSelection(tier: 1)
                : Self.wholeSpreadSelection(tier: 1)
            let pool = isRightPageFrame ? [Self.rightPage] : [Self.wholeSpread]
            let output = sticky.apply(selection: selection, pool: pool, holdThroughMiss: true)
            let state = smoother.ingest(output?.quad)
            if case .locked = state { everLocked = true }
            finalState = state
        }

        #expect(everLocked, "sticky v2 稳定输出后 smoother 必须能在 0.55s 窗内锁定")
        guard case .locked(let lockedQuad) = finalState else {
            Issue.record("终态必须保持锁定（交替被持续吸收）")
            return
        }
        #expect(lockedQuad == Self.rightPage, "锁定对象必须是先稳的右页（先稳者胜）")
    }

    @Test("集成对照：存在性交替不经 sticky 时 smoother 永不锁定（Case B 机制钉住）")
    func alternationWithoutStickyNeverLocks() {
        var smoother = QuadSmoother()

        var everLocked = false
        // 与上例同节奏的原始交替：面积比 0.8448/0.36 ≈ 2.35，每帧触发
        // areaJump（0.35）重置 stableTime——「实线框持续跳动、永不锁定」
        // 的机理锚点；若未来 smoother 参数调整使本用例变绿，须重新评估
        // Case B 是否还需要 sticky 层修复。
        for index in 0..<18 {
            let quad = index % 2 == 0 ? Self.rightPage : Self.wholeSpread
            if case .locked = smoother.ingest(quad) { everLocked = true }
        }
        #expect(!everLocked, "未经 sticky 的存在性交替必须永不锁定（Case B 机理）")
    }

    // MARK: - 逃逸一次性（对抗性审查 confirmed C1：持续间隙不重复判逃逸）

    @Test("逃逸每次锚点放弃仅判定一次：持续 nil 间隙回落 gapMiss，不重发 escape")
    func escapeFiresOncePerAnchorLoss() {
        var sticky = CandidateSticky()

        // 起锚（右页）。
        _ = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )

        // 持续检测间隙 ×3：1~2 gapMiss，第 3 帧达限清锚 = 唯一一次逃逸判定。
        _ = sticky.apply(selection: nil, pool: [], holdThroughMiss: true)
        _ = sticky.apply(selection: nil, pool: [], holdThroughMiss: true)
        _ = sticky.apply(selection: nil, pool: [], holdThroughMiss: true)
        #expect(sticky.lastDisposition == .escape)
        #expect(sticky.missCount == 3, "逃逸帧 afterMisses 恒等于 missLimit（判读契约）")

        // 间隙持续（帧 4~5）：锚点已弃，必须回落 gapMiss——否则 stickyEscape
        // 逐帧重发、afterMisses=4,5,… 无界爬升，打破「每次锚点放弃仅一条、
        // afterMisses = missLimit」日志判读契约（审查 confirmed C1）。
        _ = sticky.apply(selection: nil, pool: [], holdThroughMiss: true)
        #expect(sticky.lastDisposition == .gapMiss, "无锚点的持续间隙不得再判逃逸")
        _ = sticky.apply(selection: nil, pool: [], holdThroughMiss: true)
        #expect(sticky.lastDisposition == .gapMiss)

        // 探针：间隙结束后重新起锚正常（一次性守卫不影响逃逸自清语义）。
        let reanchored = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage],
            holdThroughMiss: true
        )
        #expect(reanchored?.quad == Self.rightPage)
        #expect(sticky.lastDisposition == .anchored)
        #expect(sticky.missCount == 0)
    }

    // MARK: - Helpers

    /// 轴对齐矩形框（包围盒 IoU / score 手算用；与 CandidateStickyTests 同 fixture）。
    private static func rectQuad(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomRight: CGPoint(x: maxX, y: maxY),
            bottomLeft: CGPoint(x: minX, y: maxY)
        )
    }

    private static func rightPageSelection(tier: Int) -> DetectionStrategy.Selection {
        DetectionStrategy.Selection(quad: rightPage, tier: tier)
    }

    private static func wholeSpreadSelection(tier: Int) -> DetectionStrategy.Selection {
        DetectionStrategy.Selection(quad: wholeSpread, tier: tier)
    }

    private static let rightPage = rectQuad(0.5, 0.1, 0.95, 0.9)
    // Case B 右页形态：0.45×0.8 = 0.36。

    private static let rightPageEnlarged = rectQuad(0.48, 0.08, 0.97, 0.92)
    // 0.49×0.84 = 0.4116；IoU(rightPage) ≈ 0.875 ≥ 0.60；IoU(wholeSpread) ≈ 0.487
    // < 0.60（整书完全包围之）——同池交替时锚点相似的「评分最高者」。

    private static let wholeSpread = rectQuad(0.02, 0.06, 0.98, 0.94)
    // 整书外轮廓：0.96×0.88 = 0.8448；IoU(rightPage) ≈ 0.426 < 0.60。
}
