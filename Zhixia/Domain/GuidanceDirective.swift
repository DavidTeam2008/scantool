import Foundation

/// 取景方向感知引导判定（spec/scan-fidelity T005 / FR-010）—— 纯函数，无状态无 I/O。
///
/// 四态语义（`CaptureView.hintText` 的唯一判定来源，T025 消费）：
/// - `backOff`：太近 / 贴边 / 形变可疑（suspicious 优先级最高——先排除拍摄姿势问题再谈距离）；
/// - `closer`：太远（目标面积低于进入阈值，经 `FarHysteresis` 滞回去抖）；
/// - `locked`：对准（跟踪锁定且距离达标）；
/// - `searching`：无 quad / 初始态（透传，文案沿用现状 search，不制造新提示）。
enum GuidanceDirective: Equatable, Sendable {
    case backOff
    case closer
    case locked
    case searching

    /// 由平滑器轨道态 + 面积滞回推导引导态。
    ///
    /// 判定次序（优先级从高到低）：
    /// 1. `track` 无 quad（.searching）→ 复位滞回，透传 `.searching`；
    /// 2. quad 触发 `isSuspiciousForAutoCapture`（面积 ≥ 0.95 近满幅 / 贴边
    ///    < 0.015——**既有阈值原样复用**，不另起一套）→ `.backOff`；
    /// 3. 滞回判太远（面积 < 0.07 进入，> 0.09 退出）→ `.closer`；
    /// 4. `.locked` 轨道态 → `.locked`；其余（tracking 且距离达标）→ `.searching`。
    ///
    /// 滞回更新只依赖 quad 面积，`backOff` 期间照常喂入（面积语义连续，
    /// 可疑框解除后滞回状态不跳变）。
    static func evaluate(track: QuadTrackState, hysteresis: inout FarHysteresis) -> GuidanceDirective {
        guard let quad = track.quad else {
            hysteresis.reset()
            return .searching
        }
        let tooFar = hysteresis.update(area: quad.area)
        if quad.isSuspiciousForAutoCapture() {
            return .backOff
        }
        if tooFar {
            return .closer
        }
        if case .locked = track {
            return .locked
        }
        return .searching
    }
}

/// 「太远」面积滞回（FR-010 防闪烁）：进入 closer 需面积 < 0.07，退出需面积 > 0.09
/// —— 两阈值间的 0.02 间隙保持上一判定，目标在边界附近晃动时提示不闪跳。
/// 无 quad（searching）时由 `GuidanceDirective.evaluate` 复位。
struct FarHysteresis: Equatable, Sendable {
    /// 进入「太远」的面积上限（归一化面积，与 `Quad.area` 同基准）。
    static let enterArea: Double = 0.07
    /// 退出「太远」的面积下限（必须 > `enterArea` 才构成滞回间隙）。
    static let exitArea: Double = 0.09

    private(set) var isTooFar: Bool

    init(isTooFar: Bool = false) {
        self.isTooFar = isTooFar
    }

    /// 喂入当前目标面积，返回更新后的太远判定。
    @discardableResult
    mutating func update(area: Double) -> Bool {
        if isTooFar {
            if area > Self.exitArea {
                isTooFar = false
            }
        } else if area < Self.enterArea {
            isTooFar = true
        }
        return isTooFar
    }

    /// 无 quad / 重新搜索时复位。
    mutating func reset() {
        isTooFar = false
    }
}
