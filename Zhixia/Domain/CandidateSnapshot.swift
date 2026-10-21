import Foundation

/// 单帧候选快照（spec/guided-capture T002 / FR-007）——检测器 debug 回调的载荷。
///
/// ## 用途
/// 折页书主场景连续多个周期未达效，根因之一是「池里到底有没有右页」只能猜：
/// 上一轮的复盘里我们既不知道右页是否进池，也不知道它是被包含降权压掉还是
/// 根本没被检出。快照把**每帧的完整候选事实**落盘，让 V2 验证（docs/15 §九）
/// 可以离线判读：
///
/// - 右页**在池里但输给整书** → 评分/意图问题（后续周期处理）；
/// - 右页**不在池里** → 检测问题（另一个周期处理）。
///
/// ## 载荷约定（FR-007）
/// - 候选集 = **全部 viable** + **top 8**（按 score 降序），硬上限 16；
/// - 超出部分记 `droppedCount`（不静默丢 viable——丢弃必须可数）；
/// - 每条候选记四角、面积、score、containment、tier、是否 viable；
/// - 另记总数与最大面积（`rawCount` / `viableCount` / `maxArea`）。
///
/// 纯数据（无 I/O、无 Services 依赖），`Codable` 以便随诊断包落盘。
struct CandidateSnapshot: Codable, Equatable, Sendable {
    /// 检测路径：live（逐帧）/ still（快门静帧重检）。
    enum Path: String, Codable, Sendable {
        case live
        case still
    }

    /// 单条候选事实。
    struct Candidate: Codable, Equatable, Sendable {
        /// 候选四边形（检测所在空间的归一化坐标，y-down）。
        var quad: Quad
        /// 归一化面积。
        var area: Double
        /// 择优评分（面积 × 居中 × 方正，与 `Quad.score()` 同口径）。
        var score: Double
        /// **被其他候选包含的比例**（自身包围盒被别的候选覆盖的最大比例）：
        /// ≥0.9 即触发包含降权 ×0.35（`DetectionStrategy.containmentThreshold`）。
        var containment: Double
        /// 面积档位：0 = 不入池（退化/过小），1 = 一级（<0.96），2 = 二级（≤1.0）。
        var tier: Int
        /// 是否进入 viable 池（非退化且面积 > `DetectionStrategy.minArea`）。
        var viable: Bool
    }

    /// 快照时刻。
    var timestamp: Date
    /// 检测路径。
    var path: Path
    /// 是否证件模式（证件窗口路径的候选语义与文档路径不同）。
    var idCardMode: Bool
    /// 原始候选总数（含被过滤掉的）。
    var rawCount: Int
    /// viable 候选数。
    var viableCount: Int
    /// 因硬上限 16 被丢弃的候选数（丢弃**必须可数**）。
    var droppedCount: Int
    /// viable 候选中的最大面积（0 = 无 viable）。
    var maxArea: Double
    /// 粘滞后实际生效框的面积（-1 = 无生效框）。
    var selectionArea: Double
    /// 择优档位（0 = 无择优）。
    var tier: Int
    /// 粘滞判定去向（`CandidateSticky.Disposition` 的 raw value；无粘滞路径为 nil）。
    var disposition: String?
    /// 粘滞连续 miss 计数（0 = 无粘滞路径或未 miss）。
    var stickyMissCount: Int
    /// 候选明细（≤16；全部 viable + top 8，按 score 降序）。
    var candidates: [Candidate]
}
