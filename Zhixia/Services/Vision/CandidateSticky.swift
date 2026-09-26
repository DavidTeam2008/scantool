import Foundation

/// 候选粘滞（spec/wysiwyg-crop，plan D3，FR-006~007，用户决策①「仅止跳」）——
/// 有状态 struct，由 `VisionEdgeDetector` actor 持有（actor 串行访问保证状态安全）。
///
/// R5 根因：摊开书从中线取景时，右页矩形与整书外轮廓两候选逐帧交替成为
/// `DetectionStrategy.select` 的最优（面积比 ≈2:1，超 `QuadSmoother` areaJump
/// 0.35 重置阈值）→ 轨道反复重置、取景框持续跳动、永不锁定。振荡发生在
/// 检测器逐帧独立择优层（smoother 只见单 quad 无从选择），必须在止跳源头
/// 消除：与上次择优相似（IoU ≥ 0.60）的候选优先延续——**先稳者胜**，
/// 不加「意图猜测」类候选偏好启发式（用户决策①）；锁定到不想要的候选
/// （如整书）靠既有缓解链路（看得见 + 确认窗内可移开中止 + 预览四角调框）。
///
/// 逃逸路径（FR-007，不粘死）：池中连续 `missLimit`（默认 3 帧 ≈ 0.2s@15fps）
/// 无相似候选（含 selection 为 nil 的检测间隙）即清空锚点回落搜索态语义；
/// 用户明显改变取景（候选离开视场/新候选显著更优）时跟随切换、重新起锚。
struct CandidateSticky: Sendable {
    /// 粘滞相似阈值（plan D3：同候选跨帧 IoU ≥0.85 vs 右页/整书 ≈0.5，0.60 居中）。
    static let defaultSimilarityThreshold: Double = 0.60
    /// 逃逸帧数上限（连续无相似候选 3 帧 ≈ 0.2s@15fps，切换无感）。
    static let defaultMissLimit: Int = 3

    /// 上次择优（粘滞锚点；nil = 无锚点，下一有效择优直通起锚）。
    private var lastPick: Quad?
    /// 连续无相似候选帧数（selection 为 nil 或池中无锚点相似候选均计 miss）。
    private var missCount: Int

    init() {
        lastPick = nil
        missCount = 0
    }

    /// 对本帧择优应用粘滞，返回实际生效的择优（可能与输入不同 = 止跳改写）。
    ///
    /// 判定次序：
    /// 1. `selection == nil`（检测间隙/全部落空）→ 计 miss，达限清空锚点，
    ///    返回 nil（smoother 自身另有 3 帧 miss 保留，短暂间隙不跳变）；
    /// 2. 无锚点（初锁/逃逸清空后）→ 直通并起锚（miss 清零）；
    /// 3. 新择优与锚点相似（IoU ≥ 阈值）→ 跟随更新锚点（允许小幅漂移）；
    /// 4. 新择优跳变，但池中仍有锚点相似候选（双候选交替场景）→ 改选其中
    ///    评分最高者（`Quad.score()`，先稳者胜），tier 沿用同池层级；
    /// 5. 池中无锚点相似候选（用户明显改变取景）→ 计 miss，达限清空锚点
    ///   （此后经 2 重新起锚）；本帧照常透传新择优——跟随切换，不粘死旧位置。
    ///
    /// - Parameters:
    ///   - selection: 本帧 `DetectionStrategy.select` 的择优（nil = 无候选）。
    ///   - pool: 本帧原始候选池（调用方传 `rawCandidates`，与 select 同池）。
    ///   - similarityThreshold: 相似判定 IoU 阈值，默认 0.60。
    ///   - missLimit: 逃逸帧数上限，默认 3。
    /// - Returns: 实际生效的择优；与本帧输入不同即为止跳改写
    ///   （调用方记 `ZhixiaLog.stickyOverride` 日志）。
    mutating func apply(
        selection: DetectionStrategy.Selection?,
        pool: [Quad],
        similarityThreshold: Double = CandidateSticky.defaultSimilarityThreshold,
        missLimit: Int = CandidateSticky.defaultMissLimit
    ) -> DetectionStrategy.Selection? {
        // ① 检测间隙：计 miss，达限清空锚点。
        guard let selection else {
            missCount += 1
            if missCount >= missLimit {
                lastPick = nil
            }
            return nil
        }
        // ② 无锚点：直通起锚（初锁/逃逸后）。
        guard let anchor = lastPick else {
            lastPick = selection.quad
            missCount = 0
            return selection
        }
        // ③ 相似跟随：锚点随小幅漂移更新，miss 清零。
        if selection.quad.iou(with: anchor) >= similarityThreshold {
            lastPick = selection.quad
            missCount = 0
            return selection
        }
        // ④ 止跳改写：池中锚点相似候选优先延续（评分最高者胜），先稳者胜。
        if let stickyQuad = pool
            .filter({ $0.iou(with: anchor) >= similarityThreshold })
            .max(by: { $0.score() < $1.score() })
        {
            lastPick = stickyQuad
            missCount = 0
            return DetectionStrategy.Selection(quad: stickyQuad, tier: selection.tier)
        }
        // ⑤ 无相似候选：计 miss（达限清空锚点），透传新择优——不粘死旧位置。
        missCount += 1
        if missCount >= missLimit {
            lastPick = nil
        }
        return selection
    }
}
