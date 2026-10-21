import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

/// 粘滞锚点治理（spec/frame-truth FR-003）：锚点准入、起锚确认、跟随面积比、
/// 跨会话清锚。全部以**显式参数**驱动——默认语义（v1/v2）由既有
/// `CandidateStickyTests` / `CandidateStickyV2Tests` 钉住，本套件不触碰。
struct CandidateStickyFrameTruthTests {
    // MARK: - 锚点准入

    @Test("Sub-page selections display but never anchor")
    func subFloorSelectionNeverAnchors() {
        var sticky = CandidateSticky()
        let band = Self.rectQuad(0.4, 0.4, 0.6, 0.55) // 0.2×0.15 = 0.03
        let selection = DetectionStrategy.Selection(quad: band, tier: 1)

        #expect(band.area < 0.12)
        for _ in 0..<3 {
            let output = sticky.apply(
                selection: selection,
                pool: [band],
                anchorMinArea: 0.12
            )
            // 透传显示（框不消失），但锚点始终为空——分支④无从续命。
            #expect(output?.quad == band)
            #expect(sticky.lastDisposition == .passthrough)
        }
    }

    // MARK: - 起锚确认（消灭 escape 单帧抽签）

    @Test("Re-anchor requires K consecutive similar frames")
    func reanchorConfirmationRequiresConsecutiveFrames() {
        var sticky = CandidateSticky()
        let page = Self.rectQuad(0.1, 0.1, 0.7, 0.9) // 0.48
        let selection = DetectionStrategy.Selection(quad: page, tier: 1)

        let first = sticky.apply(
            selection: selection, pool: [page], reanchorConfirmFrames: 3
        )
        #expect(first?.quad == page)
        #expect(sticky.lastDisposition == .passthrough, "第 1 帧仅悬挂，不起锚")

        let second = sticky.apply(
            selection: selection, pool: [page], reanchorConfirmFrames: 3
        )
        #expect(second?.quad == page)
        #expect(sticky.lastDisposition == .passthrough, "第 2 帧仍不足 3 帧")

        let third = sticky.apply(
            selection: selection, pool: [page], reanchorConfirmFrames: 3
        )
        #expect(third?.quad == page)
        #expect(sticky.lastDisposition == .anchored, "连续 3 帧相似才起锚")

        // 起锚后同候选走跟随（证明锚点确实生效）。
        _ = sticky.apply(
            selection: selection, pool: [page], reanchorConfirmFrames: 3
        )
        #expect(sticky.lastDisposition == .follow)
    }

    // MARK: - 跟随面积比（堵包含链棘轮）

    @Test("Follow ratio blocks the 30%/frame containment ratchet")
    func followAreaRatioBlocksContainmentChain() {
        let page = Self.rectQuad(0.1, 0.1, 0.7, 0.9) // 0.48
        // 子框完全含于母框：IoU = 0.352/0.48 ≈ 0.7333 ≥ 0.70（相似判定通过），
        // 面积比 0.7333 < 0.8（跟随面积比拒绝）。
        let child = Self.rectQuad(0.1, 0.1, 0.54, 0.9)
        #expect(child.area / page.area < 0.8)

        // 无面积比守卫（默认 0）：相似即跟随——包含链可以逐帧收缩锚点。
        var defaultSticky = CandidateSticky()
        _ = defaultSticky.apply(selection: DetectionStrategy.Selection(quad: page, tier: 1), pool: [page])
        let followed = defaultSticky.apply(
            selection: DetectionStrategy.Selection(quad: child, tier: 1),
            pool: [child]
        )
        #expect(followed?.quad == child)
        #expect(defaultSticky.lastDisposition == .follow)

        // 面积比守卫 0.8：拒绝跟随 → 无池候选可改写 → hold 维持原锚点。
        var guarded = CandidateSticky()
        _ = guarded.apply(selection: DetectionStrategy.Selection(quad: page, tier: 1), pool: [page])
        let held = guarded.apply(
            selection: DetectionStrategy.Selection(quad: child, tier: 1),
            pool: [],
            holdThroughMiss: true,
            followMinAreaRatio: 0.8
        )
        #expect(held?.quad == page, "面积比不足：锚点不得逐帧被收缩")
        #expect(guarded.lastDisposition == .hold)
    }

    // MARK: - 锚点生命周期

    @Test("A >1s detection gap clears the anchor (new session must not inherit it)")
    func staleGapClearsAnchor() async {
        var sticky = CandidateSticky()
        let page = Self.rectQuad(0.1, 0.1, 0.7, 0.9)
        let selection = DetectionStrategy.Selection(quad: page, tier: 1)

        _ = sticky.apply(selection: selection, pool: [page])
        #expect(sticky.lastDisposition == .anchored)

        try? await Task.sleep(nanoseconds: 1_050_000_000)

        // 间隔 > 1s 后重新起锚（若旧锚点未清，这里会是 .follow）。
        _ = sticky.apply(selection: selection, pool: [page])
        #expect(sticky.lastDisposition == .anchored, "跨会话旧锚点不得继承")
    }

    // MARK: - Fixtures

    private static func rectQuad(
        _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
    ) -> Quad {
        Quad(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomRight: CGPoint(x: maxX, y: maxY),
            bottomLeft: CGPoint(x: minX, y: maxY)
        )
    }
}
