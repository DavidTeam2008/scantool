import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// 快门裁切一致性门禁穷举（spec/wysiwyg-crop，plan D1/D2，FR-001~004）：
/// 纯函数五分支——一致采纳静帧精修 / 不一致呈现框优先（Case A 右页 vs 整书）/
/// 搜索态静帧直通 / 双 nil / 阈值边界（默认 0.70 + 注入阈值）。
/// 轴对齐框使包围盒 IoU 可手算，一致性度量值可精确断言。
struct CropConsistencyGateTests {
    // MARK: - 一致 → 静帧精修采纳（FR-002 / US4）

    @Test("一致（IoU ≥ 0.70）→ 静帧精修采纳，usedStillRefinement = true")
    func consistentRefines() {
        // 呈现框 0.6×0.8 = 0.48；静帧精修框（贴边吸附级外扩）0.64×0.84 = 0.5376；
        // 交集 0.48 → IoU = 0.48 / 0.5376 = 25/28 ≈ 0.8929 ≥ 0.70。
        let displayed = Self.rectQuad(0.2, 0.1, 0.8, 0.9)
        let still = Self.rectQuad(0.18, 0.08, 0.82, 0.92)

        let decision = CropConsistencyGate.resolve(displayed: displayed, still: still)

        #expect(decision.quad == still, "同文档精修级差异必须判一致并采纳静帧（平整精度不回归）")
        #expect(decision.usedStillRefinement == true)
        #expect(decision.consistency != nil)
        if let consistency = decision.consistency {
            #expect(abs(consistency - 25.0 / 28.0) < 1e-9)
        }
    }

    // MARK: - 不一致 → 呈现框优先（FR-003 / Case A）

    @Test("不一致（右页 vs 整书，IoU ≈ 0.5）→ 呈现框优先，静帧弃用")
    func inconsistentPrefersDisplayed() {
        // Case A 单测对应：呈现框 = 右页 0.5×0.8 = 0.4；静帧检出的整书外轮廓
        // 1.0×0.8 = 0.8（含左页）；交集 = 右页自身 → IoU = 0.4 / 0.8 = 0.5 < 0.70。
        let rightPage = Self.rectQuad(0.5, 0.1, 1.0, 0.9)
        let wholeSpread = Self.rectQuad(0.0, 0.1, 1.0, 0.9)

        let decision = CropConsistencyGate.resolve(displayed: rightPage, still: wholeSpread)

        #expect(decision.quad == rightPage, "整书级偏离必须弃用静帧、呈现框优先（锁的是右页就裁右页）")
        #expect(decision.usedStillRefinement == false)
        #expect(decision.consistency != nil)
        if let consistency = decision.consistency {
            #expect(abs(consistency - 0.5) < 1e-9)
        }
    }

    // MARK: - 搜索态 → 静帧自由检测（FR-004）

    @Test("无呈现框（搜索态）→ 静帧直通，无一致性度量")
    func noDisplayedUsesStill() {
        let still = Self.rectQuad(0.15, 0.1, 0.85, 0.9)

        let decision = CropConsistencyGate.resolve(displayed: nil, still: still)

        #expect(decision.quad == still, "搜索态无「所见」可违背，静帧检测维持现状")
        #expect(decision.usedStillRefinement == true)
        #expect(decision.consistency == nil)
    }

    // MARK: - 双 nil → 由调用方回退全幅

    @Test("呈现框与静帧框双 nil → quad = nil（调用方回退 .fullImage）")
    func bothNilGivesNil() {
        let decision = CropConsistencyGate.resolve(displayed: nil, still: nil)

        #expect(decision.quad == nil)
        #expect(decision.usedStillRefinement == false)
        #expect(decision.consistency == nil)
    }

    // MARK: - 阈值边界（默认 0.70 + 注入阈值穷举 ≥ 含义）

    @Test("阈值边界：IoU 0.6944 → 呈现框；0.7042 → 静帧；注入阈值验证 ≥ 含义")
    func thresholdBoundary() {
        let displayed = Self.rectQuad(0.1, 0.1, 0.6, 0.9) // 0.5×0.8 = 0.4
        // 0.71×0.8 = 0.568 包含呈现框 → IoU = 0.4/0.568 ≈ 0.7042 ≥ 0.70（just above）。
        let justAbove = Self.rectQuad(0.1, 0.1, 0.81, 0.9)
        // 0.72×0.8 = 0.576 包含呈现框 → IoU = 0.4/0.576 ≈ 0.6944 < 0.70（just below）。
        let justBelow = Self.rectQuad(0.1, 0.1, 0.82, 0.9)

        // 默认阈值 0.70：一侧进、一侧出——plan D1「双侧 ≥0.1 余量」的边界钉死。
        let aboveDecision = CropConsistencyGate.resolve(displayed: displayed, still: justAbove)
        #expect(aboveDecision.quad == justAbove)
        #expect(aboveDecision.usedStillRefinement == true)

        let belowDecision = CropConsistencyGate.resolve(displayed: displayed, still: justBelow)
        #expect(belowDecision.quad == displayed)
        #expect(belowDecision.usedStillRefinement == false)

        // 注入阈值穷举「≥ 含义」：阈值 = 实测 IoU 本身（`Quad.iou(with:)` 纯
        // 函数对同一输入确定性相等）→ 必须判一致（≥ 含义，at → still）；
        // 阈值抬高一丝 → 弃用（just below threshold → displayed）。
        // 注：不能用「数学上恰好 0.5」的框对——并集 FP 舍入会差 1 ULP
        //（0.4 + 0.8 − 0.4 ≠ 0.8），实测 IoU 落在阈值下方而假失败。
        let iouHalfPairDisplayed = Self.rectQuad(0.5, 0.1, 1.0, 0.9)
        let iouHalfPairStill = Self.rectQuad(0.0, 0.1, 1.0, 0.9) // 实测 IoU ≈ 0.5
        let measuredIOU = iouHalfPairDisplayed.iou(with: iouHalfPairStill)
        let atThreshold = CropConsistencyGate.resolve(
            displayed: iouHalfPairDisplayed, still: iouHalfPairStill, iouThreshold: measuredIOU
        )
        #expect(atThreshold.quad == iouHalfPairStill, "IoU == 阈值必须判一致（≥ 含义）")
        #expect(atThreshold.usedStillRefinement == true)

        let aboveThreshold = CropConsistencyGate.resolve(
            displayed: iouHalfPairDisplayed, still: iouHalfPairStill, iouThreshold: measuredIOU + 1e-9
        )
        #expect(aboveThreshold.quad == iouHalfPairDisplayed)
        #expect(aboveThreshold.usedStillRefinement == false)
    }

    // MARK: - Helpers

    /// 轴对齐矩形框（包围盒 IoU 手算用；门禁度量 = `Quad.iou(with:)` 包围盒 IoU）。
    private static func rectQuad(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomRight: CGPoint(x: maxX, y: maxY),
            bottomLeft: CGPoint(x: minX, y: maxY)
        )
    }
}
