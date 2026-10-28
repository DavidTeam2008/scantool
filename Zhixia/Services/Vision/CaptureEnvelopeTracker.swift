import Foundation

/// CF-T003：实时包络跟踪器（纯组件，可离线回放）。
///
/// 设计目标不是“每帧得到一个精确单页”，而是：
/// 1. 只要曾经看到书/页面，框就尽量不消失；
/// 2. 检测偶尔消失时保持最近包络，超过 `holdDuration` 才回到搜索；
/// 3. 新观测是另一个对象（整摊↔单页/桌面）时，先确认再切换，显示不瞬移；
/// 4. 稳定一段时间后进入 locked，供自动快门/白线提示使用。
///
/// 这一层不做 Vision/相机 I/O；输入已在视频空间，输出可直接喂 overlay。
/// 高频光流/单应性传播作为 `observation` 的可选来源，后续接入时不需要改
/// 本状态机的接口。
struct CaptureEnvelopeTracker: Sendable {
    enum Phase: String, Sendable, Equatable {
        case searching
        case tracking
        case locked
    }

    struct State: Equatable, Sendable {
        var phase: Phase
        var envelope: Quad?
        var target: Quad?
        var isHolding: Bool
        var confidence: Double
        var intentSatisfied: Bool

        var track: QuadTrackState {
            guard let envelope else { return .searching }
            return phase == .locked ? .locked(envelope) : .tracking(envelope)
        }

        static let searching = State(
            phase: .searching,
            envelope: nil,
            target: nil,
            isHolding: false,
            confidence: 0,
            intentSatisfied: false
        )
    }

    // MARK: - 可调参数（真实参数由离线回放调整，不依赖真机盲调）

    /// 平滑系数：越小越稳、越大越跟手。
    var alpha: Double = 0.30
    /// 进入锁定前的单帧稳定阈值（归一化顶点平均距离）。
    var stableEpsilon: Double = 0.006
    /// 稳定多久进入 locked。
    var lockDuration: TimeInterval = 0.40
    /// 检测完全缺失时保留上一个包络的时间。
    var holdDuration: TimeInterval = 0.50
    /// 新观测与当前包络差异超过该值，视为可能切换对象。
    var switchDistance: Double = 0.12
    /// 候选切换的确认时间；确认前保持旧包络。
    var switchConfirmDuration: TimeInterval = 0.30
    /// 目标页（左/右页）失联后保留时间；超过则回退包络。
    var targetHoldDuration: TimeInterval = 0.25

    private var envelope: Quad?
    private var target: Quad?
    private var lastTargetAt: TimeInterval?
    private var lastObservationAt: TimeInterval?
    private var stableSince: TimeInterval?
    private var pendingSwitch: Quad?
    private var pendingSwitchSince: TimeInterval?
    private var isLocked = false
    private var lastConfidence: Double = 0
    private var lastIntentSatisfied = false

    mutating func reset() {
        envelope = nil
        target = nil
        lastTargetAt = nil
        lastObservationAt = nil
        stableSince = nil
        pendingSwitch = nil
        pendingSwitchSince = nil
        isLocked = false
        lastConfidence = 0
        lastIntentSatisfied = false
    }

    mutating func ingest(
        _ observation: CaptureEnvelopeObservation?,
        at timestamp: TimeInterval
    ) -> State {

        guard let observation, !observation.envelope.isDegenerate else {
            if let envelope = self.envelope, let lastObservationAt = self.lastObservationAt,
               timestamp - lastObservationAt <= holdDuration {
                // 保留包络，但明确标记“hold”：UI 可以画得淡一点，自动快门
                // 必须等真正的新观测，不能拿旧框继续拍。hold 期间撤销锁定，
                // 新观测回来后重新累计稳定时间。
                isLocked = false
                stableSince = nil
                return State(
                    phase: .tracking,
                    envelope: envelope,
                    target: targetIfFresh(at: timestamp),
                    isHolding: true,
                    confidence: lastConfidence * 0.5,
                    intentSatisfied: lastIntentSatisfied
                )
            }
            reset()
            return .searching
        }

        lastObservationAt = timestamp
        lastConfidence = max(0, min(1, observation.confidence))
        lastIntentSatisfied = observation.intentSatisfied
        if let target = observation.target, !target.isDegenerate {
            self.target = target
            lastTargetAt = timestamp
        } else if !observation.intentSatisfied {
            // 目标页明确不可靠时尽快撤掉，而不是把它当成整页输出。
            self.target = nil
            lastTargetAt = nil
        } else if let lastTargetAt = self.lastTargetAt, timestamp - lastTargetAt > targetHoldDuration {
            self.target = nil
        }

        guard let previous = envelope else {
            envelope = observation.envelope
            stableSince = timestamp
            isLocked = false
            pendingSwitch = nil
            pendingSwitchSince = nil
            return State(
                phase: .tracking,
                envelope: envelope,
                target: targetIfFresh(at: timestamp),
                isHolding: false,
                confidence: lastConfidence,
                intentSatisfied: lastIntentSatisfied
            )
        }

        // 候选身份切换：新观测与旧包络差异很大时，不直接瞬移，先确认
        // 连续出现；确认前仍显示旧包络。这样整摊 ↔ 单页、书 ↔ 桌面的
        // 候选抽签不会变成屏幕跳变。
        let distance = previous.meanVertexDistance(to: observation.envelope)
        let appearsDifferent = distance > switchDistance
            || previous.iou(with: observation.envelope) < 0.20
        if appearsDifferent {
            if pendingSwitch == nil || pendingSwitch!.iou(with: observation.envelope) < 0.70 {
                pendingSwitch = observation.envelope
                pendingSwitchSince = timestamp
            }
            if let switchTime = self.pendingSwitchSince,
               timestamp - switchTime < switchConfirmDuration {
                // 未确认前保持旧框；置信度下降但仍显示。
                return State(
                    phase: .tracking,
                    envelope: previous,
                    target: targetIfFresh(at: timestamp),
                    isHolding: false,
                    confidence: lastConfidence * 0.7,
                    intentSatisfied: lastIntentSatisfied
                )
            }
            // 确认切换：从旧框平滑追新框，而不是直接替换。
            let confirmedSwitch = pendingSwitch ?? observation.envelope
            envelope = previous.interpolated(toward: confirmedSwitch, alpha: max(alpha, 0.45))
            stableSince = timestamp
            isLocked = false
            self.pendingSwitch = nil
            pendingSwitchSince = nil
            return State(
                phase: .tracking,
                envelope: envelope,
                target: targetIfFresh(at: timestamp),
                isHolding: false,
                confidence: lastConfidence,
                intentSatisfied: lastIntentSatisfied
            )
        }

        pendingSwitch = nil
        pendingSwitchSince = nil
        let next = previous.interpolated(toward: observation.envelope, alpha: alpha)
        envelope = next

        // 以“平滑后仍贴着新观测”为稳定判据，避免只因为观测本身不动就锁定
        // 而屏幕框还在缓慢追赶。
        let settled = next.meanVertexDistance(to: observation.envelope) <= stableEpsilon
        if settled {
            if stableSince == nil { stableSince = timestamp }
            if let stableSince = self.stableSince, timestamp - stableSince >= lockDuration, !isLocked {
                isLocked = true
            }
        } else {
            stableSince = nil
            isLocked = false
        }

        return State(
            phase: isLocked ? .locked : .tracking,
            envelope: next,
            target: targetIfFresh(at: timestamp),
            isHolding: false,
            confidence: lastConfidence,
            intentSatisfied: lastIntentSatisfied
        )
    }

    private func targetIfFresh(at timestamp: TimeInterval) -> Quad? {
        guard let target = self.target, let lastTargetAt = self.lastTargetAt else { return nil }
        return timestamp - lastTargetAt <= targetHoldDuration ? target : nil
    }
}
