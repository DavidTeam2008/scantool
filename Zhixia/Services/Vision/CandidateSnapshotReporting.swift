import Foundation

/// 候选快照订阅（spec/guided-capture T002 / FR-007）——**新增**协议。
///
/// ## 为什么是独立协议
/// `EdgeDetecting` 的既有签名冻结（铁律 1 / plan D6 不变式）：诊断能力不得
/// 改动生产协议。新能力一律走「新增协议 / debug 回调 / 可选注入」。
///
/// ## 语义
/// - 处理器默认 nil = **零开销**（检测器不为快照做任何排序/分配）；
/// - 回调在检测 actor 内同步发出（顺序 = 检测顺序），载荷不可变；
/// - release 构建下检测器不构造快照（编译期 `#if DEBUG`），回调恒不触发。
protocol CandidateSnapshotReporting: Sendable {
    /// 设置逐帧候选快照回调（nil = 取消订阅）。
    func setCandidateSnapshotHandler(_ handler: (@Sendable (CandidateSnapshot) -> Void)?) async
    /// 最近一次已发出的快照（从未订阅时为 nil）。
    func latestCandidateSnapshot() async -> CandidateSnapshot?
}
