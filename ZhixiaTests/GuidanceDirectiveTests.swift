import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// T026（spec/scan-fidelity US6 / FR-010）：方向感知引导判定——四态穷举、
/// suspicious 优先级最高、面积滞回穿越序列、searching 透传与滞回复位。
struct GuidanceDirectiveTests {
    // MARK: - 四态穷举

    @Test("四态穷举：searching / closer / locked / backOff 全部可达")
    func fourStatesAreReachable() {
        var hysteresis = FarHysteresis()

        #expect(GuidanceDirective.evaluate(track: .searching, hysteresis: &hysteresis) == .searching)

        hysteresis = FarHysteresis()
        #expect(GuidanceDirective.evaluate(track: .tracking(Self.centeredQuad(area: 0.065)), hysteresis: &hysteresis) == .closer)

        hysteresis = FarHysteresis()
        #expect(GuidanceDirective.evaluate(track: .locked(Self.centeredQuad(area: 0.25)), hysteresis: &hysteresis) == .locked)

        hysteresis = FarHysteresis()
        #expect(GuidanceDirective.evaluate(track: .locked(Self.nearFullQuad), hysteresis: &hysteresis) == .backOff)
    }

    // MARK: - suspicious 优先级

    @Test("suspicious 优先级最高：压过 closer 与 locked")
    func suspiciousOutranksDistanceAndLock() {
        var hysteresis = FarHysteresis()

        // 贴边微型框：面积 0.01 < 0.07（太远）且边距 0（贴边可疑）→ backOff 胜出。
        #expect(
            GuidanceDirective.evaluate(track: .tracking(Self.tinyEdgeQuad), hysteresis: &hysteresis) == .backOff,
            "太远 + 可疑双条件时必须提示后退（先排除拍摄姿势问题再谈距离）"
        )

        // 近满幅（面积 0.96 ≥ 0.95）锁定 → backOff 而非 locked。
        #expect(GuidanceDirective.evaluate(track: .locked(Self.nearFullQuad), hysteresis: &hysteresis) == .backOff)
    }

    // MARK: - 面积滞回穿越序列

    @Test("面积滞回穿越：0.065 进 closer，0.08 保持，0.095 出到 locked")
    func farHysteresisCrossingSequence() {
        var hysteresis = FarHysteresis()
        func evaluate(_ area: Double) -> GuidanceDirective {
            GuidanceDirective.evaluate(
                track: .locked(Self.centeredQuad(area: area)),
                hysteresis: &hysteresis
            )
        }

        // 任务书序列（locked 轨道）：进入 → 间隙保持（防闪烁）→ 退出。
        #expect(evaluate(0.065) == .closer)
        #expect(evaluate(0.08) == .closer)
        #expect(evaluate(0.095) == .locked)

        // 反向：间隙值先行不进入（只 < 0.07 才进入）——滞回不是单纯阈值。
        hysteresis = FarHysteresis()
        #expect(evaluate(0.08) == .locked)
        #expect(evaluate(0.065) == .closer)
    }

    // MARK: - searching 透传与滞回复位

    @Test("searching 透传并复位滞回：随后间隙面积不再保持 closer")
    func searchingPassesThroughAndResetsHysteresis() {
        var hysteresis = FarHysteresis()

        // 先进入太远，再丢失目标：透传 searching 且滞回复位。
        #expect(GuidanceDirective.evaluate(track: .locked(Self.centeredQuad(area: 0.065)), hysteresis: &hysteresis) == .closer)
        #expect(hysteresis.isTooFar)
        #expect(GuidanceDirective.evaluate(track: .searching, hysteresis: &hysteresis) == .searching)
        #expect(!hysteresis.isTooFar)

        // 复位后 0.08（间隙内）不构成太远——若未复位，会因保持语义继续 closer。
        #expect(GuidanceDirective.evaluate(track: .locked(Self.centeredQuad(area: 0.08)), hysteresis: &hysteresis) == .locked)
    }

    // MARK: - 夹具

    /// 中心放置的矩形 quad：shoelace 面积恰为 `area`，边距充足不触发可疑判定。
    private static func centeredQuad(area: Double) -> Quad {
        let side = area.squareRoot()
        let x = (1 - side) / 2
        let y = (1 - side) / 2
        return Quad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + side, y: y),
            bottomRight: CGPoint(x: x + side, y: y + side),
            bottomLeft: CGPoint(x: x, y: y + side)
        )
    }

    /// 贴边微型框：面积 0.01（太远）+ 边距 0（可疑）——双重条件验证优先级。
    private static let tinyEdgeQuad = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 0.1, y: 0),
        bottomRight: CGPoint(x: 0.1, y: 0.1),
        bottomLeft: CGPoint(x: 0, y: 0.1)
    )

    /// 近满幅框：面积 0.96 ≥ 0.95（与 CaptureFallbackTests 的 nearFull 同形）。
    private static let nearFullQuad = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 0.96),
        bottomLeft: CGPoint(x: 0, y: 0.96)
    )
}
