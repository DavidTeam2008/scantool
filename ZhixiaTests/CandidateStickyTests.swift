import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// 候选粘滞穷举（spec/wysiwyg-crop，plan D3，FR-006~007）：交替池保持单一
/// 候选（R5 止跳核心）/ 候选消失 3 帧逃逸 / 相似候选跟随更新（锚点漂移）/
/// 无锚点直通 / selection 为 nil 计 miss 达限清空。轴对齐框使包围盒 IoU
/// 与 `Quad.score()` 可手算，改写与逃逸均用「判别度最大」的探针帧断言
/// （若粘滞语义失效，探针帧会返回相反一侧的候选而假失败）。
struct CandidateStickyTests {
    // MARK: - 交替池保持（FR-006 / R5 止跳核心）

    @Test("交替池保持：新择优跳变时改选池中锚点相似候选的评分最高者")
    func holdsThroughAlternatingPool() {
        var sticky = CandidateSticky()

        // 帧 1：无锚点 → 右页直通起锚。
        let first = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.rightPage, Self.wholeSpread]
        )
        #expect(first?.quad == Self.rightPage)

        // 帧 2（双候选振荡——整书以原始评分反超成为本帧择优）：池中仍有
        // 右页相似候选（rightPage 与其外扩形态 enlarged）→ 粘滞改选其中
        // 评分最高者 enlarged（面积更大、同分权重），整书被止跳拦截。
        let second = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPage, Self.rightPageEnlarged]
        )
        #expect(second?.quad == Self.rightPageEnlarged, "交替帧必须延续锚点相似候选（先稳者胜），不得跟随整书跳变")
        #expect(second?.quad != Self.wholeSpread)
        #expect(second?.tier == 1, "tier 沿用同池层级")

        // 帧 3（右页重新胜出）：与锚点（enlarged）相似 → 直通，交替被完整吸收。
        let third = sticky.apply(
            selection: Self.rightPageSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPage, Self.rightPageEnlarged]
        )
        #expect(third?.quad == Self.rightPage)
    }

    // MARK: - 逃逸（FR-007 / 不粘死）

    @Test("候选消失 3 帧逃逸：锚点清空后新候选直通（相似候选回归不再拦截）")
    func escapesAfterMissLimit() {
        var sticky = CandidateSticky()
        _ = sticky.apply(selection: Self.rightPageSelection(tier: 1), pool: [Self.rightPage])

        // 连续 3 帧池中无锚点相似候选（用户移开取景，右页离开视场）：
        // 每帧照常透传新择优，第 3 帧达限清空锚点。
        for _ in 0..<3 {
            let escaped = sticky.apply(
                selection: Self.wholeSpreadSelection(tier: 1),
                pool: [Self.wholeSpread]
            )
            #expect(escaped?.quad == Self.wholeSpread, "无相似候选期间照常透传新择优（跟随切换，不粘死）")
        }

        // 探针帧（判别度最大）：相似候选回归池中，但锚点已被逃逸清空 →
        // 新择优直通起锚；若锚点未清空，此处会被误改写回 enlarged 而假失败。
        let probe = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPageEnlarged]
        )
        #expect(probe?.quad == Self.wholeSpread, "达限清空后不得再粘滞旧锚点")
    }

    // MARK: - 相似跟随（锚点随小幅漂移更新）

    @Test("相似候选跟随：直通且锚点更新（后续按新锚点判定相似）")
    func followsSimilarSelection() {
        var sticky = CandidateSticky()
        _ = sticky.apply(selection: Self.rightPageSelection(tier: 1), pool: [Self.rightPage])

        // 帧 2：右页右移 0.1（IoU 0.70 ≥ 0.60）→ 直通，锚点随之漂移。
        let followed = sticky.apply(
            selection: Self.rightPageShiftedSelection(tier: 1),
            pool: [Self.rightPageShifted]
        )
        #expect(followed?.quad == Self.rightPageShifted, "相似择优必须直通（非池中改写）")

        // 探针帧：新锚点（shifted）的相似候选 shiftedFar（IoU 0.75）与旧锚点
        // rightPage 不相似（IoU 0.50 < 0.60）——锚点若未随帧 2 更新，会因
        // 池中无 rightPage 相似候选而透传 wholeSpread；锚点已更新则改写为
        // shiftedFar（先稳者胜）。
        let probe = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 2),
            pool: [Self.wholeSpread, Self.rightPageShiftedFar]
        )
        #expect(probe?.quad == Self.rightPageShiftedFar, "相似跟随后锚点必须更新为新择优")
    }

    // MARK: - 无锚点直通

    @Test("初锁（lastPick 为空）：择优原样直通")
    func freshStatePassesThrough() {
        var sticky = CandidateSticky()

        let passed = sticky.apply(selection: Self.rightPageSelection(tier: 2), pool: [])

        #expect(passed == DetectionStrategy.Selection(quad: Self.rightPage, tier: 2))
    }

    // MARK: - selection 为 nil 计 miss（检测间隙）

    @Test("nil 择优计 miss：2 帧间隙锚点存活，3 帧达限清空后新择优直通")
    func nilSelectionCountsMiss() {
        var sticky = CandidateSticky()
        _ = sticky.apply(selection: Self.rightPageSelection(tier: 1), pool: [Self.rightPage])

        // 检测间隙 ×2（帧间无候选）：返回 nil，锚点存活（miss 2 < 上限 3）。
        for _ in 0..<2 {
            #expect(sticky.apply(selection: nil, pool: [Self.rightPage]) == nil)
        }
        // 探针：锚点仍为 rightPage → 池中相似候选 enlarged 改写胜出。
        let survived = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPageEnlarged]
        )
        #expect(survived?.quad == Self.rightPageEnlarged, "短暂检测间隙（< missLimit）不得丢失锚点")

        // nil ×3：达限清空锚点。
        for _ in 0..<3 {
            #expect(sticky.apply(selection: nil, pool: [Self.rightPage]) == nil)
        }
        // 探针：锚点已清空 → 新择优直通（不再改写回 rightPage 相似候选）。
        let escaped = sticky.apply(
            selection: Self.wholeSpreadSelection(tier: 1),
            pool: [Self.wholeSpread, Self.rightPageEnlarged]
        )
        #expect(escaped?.quad == Self.wholeSpread, "nil 达限后锚点必须清空，新择优直通")
    }

    // MARK: - Helpers

    /// 轴对齐矩形框（包围盒 IoU / score 手算用）。
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

    private static func rightPageShiftedSelection(tier: Int) -> DetectionStrategy.Selection {
        DetectionStrategy.Selection(quad: rightPageShifted, tier: tier)
    }

    private static let rightPage = rectQuad(0.5, 0.1, 0.95, 0.9)
    // Case B 右页形态：0.45×0.8 = 0.36。

    private static let rightPageEnlarged = rectQuad(0.48, 0.08, 0.97, 0.92)
    // 0.49×0.84 = 0.4116；IoU(rightPage) ≈ 0.875 ≥ 0.60；同中心权重下
    // 面积更大 → score 更高（0.2264 > 0.198）——改写时的「评分最高者」。

    private static let rightPageShifted = rectQuad(0.6, 0.1, 1.0, 0.9)
    // 右页右移：0.4×0.8 = 0.32；IoU(rightPage) = 0.28/0.40 = 0.70 ≥ 0.60。

    private static let rightPageShiftedFar = rectQuad(0.7, 0.1, 1.0, 0.9)
    // 再右移：0.3×0.8 = 0.24；IoU(shifted) = 0.75 ≥ 0.60；
    // IoU(rightPage) = 0.50 < 0.60（只与新锚点相似——锚点更新探针用）。

    private static let wholeSpread = rectQuad(0.02, 0.06, 0.98, 0.94)
    // 整书外轮廓：0.96×0.88 = 0.8448，中心满分 score = 0.8448
    //（双候选振荡中反超右页的原始最优）；IoU(rightPage) ≈ 0.426 < 0.60。
}
