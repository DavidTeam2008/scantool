import Foundation

/// 拍后拆分**提案**（spec/guided-capture T020 / FR-008 / plan D5）。
///
/// ## 为什么是「提案」而不是「直接改写」
/// 上一周期（spec/scan-enhance）里，整理页 `appear()` 会**静默**把摊开书
/// 按书脊/折条拆成右页——用户看到的是「成片少了一半」，但没有任何提示、
/// 没有撤销，也不知道系统为什么这么判。折页书场景里这等于**静默误裁**。
///
/// 本周期把它改成提案：系统只**给出可见的建议**（分割线 + 置信度），
/// 由用户确认后才写入 `draft.quad`（可撤销）。用户意图优先，系统不替用户
/// 决定「拍的是整页还是右页」。
///
/// ## 不变式
/// - 提案**不写 quad**（`refineQuads` 只生成提案）；
/// - 只有 `applySplit` 才写 quad，并置 `userAdjustedQuad = true`
///   （复用既有字段 → 后续不再被自动精修/拆分覆盖）；
/// - 引导页（`userAdjustedQuad == true`）不生成提案——引导框已经是用户意图。
struct SplitProposal: Equatable, Sendable {
    /// 分割线来源。
    enum Source: String, Sendable, Equatable {
        /// 左侧折痕暗条（折起部分是一条暗带）。
        case leftFold
        /// 中央书脊暗谷（摊开书）。
        case spine
    }

    /// 用户选择。
    enum Selection: String, Sendable, Equatable, CaseIterable, Hashable {
        /// 整页（放弃拆分，恢复提案前的框）。
        case whole
        /// 左页。
        case left
        /// 右页（提案默认）。
        case right
    }

    /// 分割线位置（沿框宽度的归一化比例，0 = 左缘，1 = 右缘）。
    var u: Double
    /// 来源。
    var source: Source
    /// 书脊显著度（spine 场景有效）。
    var prominence: Double
    /// 书脊连续性（spine 场景有效）。
    var continuity: Double
    /// 置信度（0~1；≥0.5 实线，<0.5 虚线提示）。
    var confidence: Double
    /// 提案前的框（撤销基准）。
    var quadBefore: Quad
    /// 提案默认结果（右页）。
    var quadAfter: Quad
    /// 当前选择。
    var selection: Selection

    init(
        u: Double,
        source: Source,
        prominence: Double,
        continuity: Double,
        confidence: Double,
        quadBefore: Quad,
        quadAfter: Quad,
        selection: Selection = .right
    ) {
        self.u = u
        self.source = source
        self.prominence = prominence
        self.continuity = continuity
        self.confidence = confidence
        self.quadBefore = quadBefore
        self.quadAfter = quadAfter
        self.selection = selection
    }

    /// 置信度是否达到「实线 + 可直接应用」的档位。
    var isConfident: Bool { confidence >= SplitProposalConfidence.applyThreshold }
}

/// 拆分提案的置信度公式（spec/guided-capture plan D5）——**纯函数**，可单测。
///
/// - 书脊（spine）：`0.6×clamp((prominence−0.06)/0.09) + 0.4×clamp((continuity−0.70)/0.25)`
/// - 左折条（leftFold）：`clamp((stripDepth−0.15)/0.25)`
/// - 两者都 clamp 到 `[0,1]`；`≥0.5` 实线（可直接应用），`<0.5` 虚线（提示，
///   仍允许手动拖线后应用）。
enum SplitProposalConfidence {
    /// 应用阈值（实线 / 虚线的分界）。
    static let applyThreshold: Double = 0.5

    /// 截断到 [0,1]（非有限值 → 0）。
    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// 书脊置信度。
    static func spine(prominence: Double, continuity: Double) -> Double {
        let p = clamp01((prominence - 0.06) / 0.09)
        let c = clamp01((continuity - 0.70) / 0.25)
        return clamp01(0.6 * p + 0.4 * c)
    }

    /// 左折条置信度。
    static func leftFold(stripDepth: Double) -> Double {
        clamp01((stripDepth - 0.15) / 0.25)
    }
}
