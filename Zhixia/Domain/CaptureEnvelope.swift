import Foundation

/// CF-T002/CF-T003：实时取景的“书/整摊包络”观测。
///
/// 与 `EdgeDetecting.detect(...)` 的单一 `quad` 不同，这里把两件事分开：
/// - `envelope`：屏幕上要持续显示的整本书/整摊页面外轮廓；
/// - `target`：拍后真正要输出的一页（左/右页意图时才存在）。
///
/// 目标页找不到时 `target == nil`，但 `envelope` 仍然可供用户对准和拍摄；
/// 这样不会因为“右页候选暂缺”让实线框完全消失。
struct CaptureEnvelopeObservation: Equatable, Sendable {
    var envelope: Quad
    var target: Quad?
    /// 包络本身的置信度（0...1），当前由候选面积/来源做保守估计。
    var confidence: Double
    /// 目标页是否已经可靠（false = 只能拍包络，拍后需拆页/确认）。
    var intentSatisfied: Bool
}

/// 观测接口独立于 `EdgeDetecting`，让旧替身测试保持原语义；只有真实
/// `VisionEdgeDetector` 走包络跟踪路径。
protocol EnvelopeDetecting: Sendable {
    func observeEnvelope(
        frame: VideoFrame,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> CaptureEnvelopeObservation?

    /// 清空检测器侧的包络缓存/候选状态（切换意图/模式时调用）。
    func resetEnvelopeTracking() async
}
