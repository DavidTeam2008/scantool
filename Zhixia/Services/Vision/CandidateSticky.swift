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
///
/// v2 hold-through-miss（spec/case-b-sticky-v2，plan D1）：v1 的止跳改写
/// （分支④）要求锚点相似候选与跳变择优**同帧共存**于候选池；摊开书场景下
/// 三级检测门控使 live 候选池逐帧近似单源（矩形成功帧池里只有右页、落空帧
/// 池里只有整书分割），两候选以**存在性交替**出现时分支④结构性不触发，
/// v1 恒走分支⑤透传 + 交替回摆帧分支③清零 miss——锚点既不保护也不逃逸，
/// 输出逐帧翻转、smoother areaJump 反复重置、实线框永不锁定（Case B 根因）。
/// v2 在 `holdThroughMiss == true` 时把分支⑤ miss 窗口内改为**维持锚点**
/// （与 `QuadSmoother` 的 miss 保留语义对齐），达限仍清空锚点保 FR-007 逃逸。
/// 参数默认 false 保持 v1 语义——既有测试断言零修改（铁律 2）。
struct CandidateSticky: Sendable {
    /// 粘滞相似阈值（plan D3：同候选跨帧 IoU ≥0.85 vs 右页/整书 ≈0.5，0.60 居中）。
    static let defaultSimilarityThreshold: Double = 0.60
    /// 逃逸帧数上限（连续无相似候选 3 帧 ≈ 0.2s@15fps，切换无感）。
    static let defaultMissLimit: Int = 3

    /// 本帧判定去向（供调用方接线结构化日志：stickyOverride / stickyHold /
    /// stickyEscape；nil = 尚未判定过）。逐分支取值见 `apply`。
    enum Disposition: String, Sendable {
        /// ① 检测间隙（selection 为 nil），计 miss 未达限。
        case gapMiss
        /// ② 无锚点直通起锚。
        case anchored
        /// ③ 相似跟随（锚点随小幅漂移更新）。
        case follow
        /// ④ 同池共存交替：改选池中锚点相似候选（先稳者胜）。
        case override
        /// ⑤ v2 hold-through-miss：miss 窗口内维持锚点。
        case hold
        /// ⑤ v1 语义：miss 期间透传新择优（未达限）。
        case passthrough
        /// ①/⑤ 达限逃逸：清空锚点，透传新择优 / 返回 nil。每次锚点放弃
        /// 仅判定一次（无锚点的持续间隙回落 gapMiss，不重复判逃逸）。
        case escape
    }

    /// 上次择优（粘滞锚点；nil = 无锚点，下一有效择优直通起锚）。
    private var lastPick: Quad?
    /// 锚点择优的 tier（hold 帧返回锚点择优时随锚带出，勿用 miss 帧择优 tier）。
    private var lastTier: Int = 0
    /// 连续无相似候选帧数（selection 为 nil 或池中无锚点相似候选均计 miss）。
    /// `private(set)` 供调用方读作日志字段（`stickyHold`/`stickyEscape`）。
    private(set) var missCount: Int
    /// 最近一次 `apply` 的判定去向（nil = 尚未判定过）。
    private(set) var lastDisposition: Disposition?
    /// 起锚确认候选与连续相似帧数（spec/frame-truth FR-003：
    /// `reanchorConfirmFrames > 1` 时生效——escape/初锁后需连续 K 帧相似择优
    /// 才起锚，消灭"escape 帧恰好是带子→单帧抽签"；默认 1 为 v1/v2 直通语义）。
    private var pendingPick: Quad?
    private var pendingCount: Int = 0
    /// 上次 `apply` 时刻（spec/frame-truth FR-003 生命周期）：帧间隔 > 1s
    /// （会话边界/停顿）自动清锚，避免跨会话继承旧锚点。同步调用（单测）
    /// 间隔远小于 1s，不受影响。
    private var lastApplyAt: Date?
    /// 帧间隔超过该值视为新会话/停顿，自动清锚（秒）。
    static let anchorStaleInterval: TimeInterval = 1.0

    init() {
        lastPick = nil
        missCount = 0
        lastDisposition = nil
    }

    /// 清空锚点与 miss 计数（跨场景/会话复位用）。live 同场景连续帧的
    /// 场景切换由逃逸路径自清（≤ missLimit 帧），快门/still 路径**不**复位——
    /// 存在性交替场景下快门复位会让恢复后的首帧重掷锚点抽签
    /// （spec/case-b-sticky-v2，plan D2）。
    mutating func reset() {
        lastPick = nil
        lastTier = 0
        missCount = 0
        pendingPick = nil
        pendingCount = 0
        lastDisposition = nil
    }

    /// 对本帧择优应用粘滞，返回实际生效的择优（可能与输入不同 = 止跳改写）。
    ///
    /// 判定次序：
    /// 1. `selection == nil`（检测间隙/全部落空）→ 计 miss，达限清空锚点，
    ///    返回 nil（smoother 自身另有 3 帧 miss 保留，短暂间隙不跳变）；
    /// 2. 无锚点（初锁/逃逸清空后）→ 直通并起锚（miss 清零）；
    /// 3. 新择优与锚点相似（IoU ≥ 阈值）→ 跟随更新锚点（允许小幅漂移）；
    /// 4. 新择优跳变，但池中仍有锚点相似候选（双候选**同池**交替场景）→ 改选
    ///    其中评分最高者（`Quad.score()`，先稳者胜），tier 沿用同池层级；
    /// 5. 池中无锚点相似候选 → 计 miss：
    ///    - `holdThroughMiss == true`（v2，live 默认；spec/case-b-sticky-v2）：
    ///      达限前**维持锚点**（返回锚点择优，tier 随锚）——存在性交替（一帧
    ///      池里只有右页、下一帧只有整书）场景本帧池结构性无相似候选，v1
    ///      透传即逐帧跳变源头；达限仍清空锚点并透传新择优（FR-007 逃逸）；
    ///    - `holdThroughMiss == false`（v1 语义）：miss 期间照常透传新择优
    ///     （跟随切换，不粘死旧位置），达限清空锚点（此后经 2 重新起锚）。
    ///
    /// - Parameters:
    ///   - selection: 本帧 `DetectionStrategy.select` 的择优（nil = 无候选）。
    ///   - pool: 本帧原始候选池（调用方传 `rawCandidates`，与 select 同池）。
    ///   - similarityThreshold: 相似判定 IoU 阈值，默认 0.60。
    ///   - missLimit: 逃逸帧数上限，默认 3。
    ///   - holdThroughMiss: v2 开关——miss 窗口内维持锚点（默认 false = v1）。
    /// - Returns: 实际生效的择优；判定去向写入 `lastDisposition` 供调用方
    ///   接线日志（④ → `ZhixiaLog.stickyOverride`，⑤ hold → `stickyHold`，
    ///   逃逸 → `stickyEscape`）。
    mutating func apply(
        selection: DetectionStrategy.Selection?,
        pool: [Quad],
        similarityThreshold: Double = CandidateSticky.defaultSimilarityThreshold,
        missLimit: Int = CandidateSticky.defaultMissLimit,
        holdThroughMiss: Bool = false,
        anchorMinArea: Double = 0,
        reanchorConfirmFrames: Int = 1,
        followMinAreaRatio: Double = 0
    ) -> DetectionStrategy.Selection? {
        // ⓪ 生命周期（spec/frame-truth FR-003）：帧间隔 > 1s = 会话边界/停顿，
        // 自动清锚——生产代码无（也不能加，铁律 1）协议级 reset，跨会话旧
        // 锚点不得继承。同步单测调用间隔远小于 1s，零影响。
        let now = Date()
        if let lastApplyAt, now.timeIntervalSince(lastApplyAt) > Self.anchorStaleInterval {
            reset()
        }
        lastApplyAt = now
        // ① 检测间隙：计 miss，达限清空锚点。逃逸仅在锚点真实放弃的这一帧
        // 判定（`lastPick != nil` 守卫）——持续间隙下锚点已弃，后续 nil 帧
        // 回落 gapMiss：否则 `stickyEscape` 逐帧重发且 afterMisses 无界爬升，
        // 打破「每次锚点放弃仅一条、afterMisses = missLimit」判读契约
        // （审查 confirmed C1；missCount 不复位是 v1 既有语义，仅遥测可见）。
        guard let selection else {
            missCount += 1
            if missCount >= missLimit, lastPick != nil {
                lastPick = nil
                lastDisposition = .escape
            } else {
                lastDisposition = .gapMiss
            }
            return nil
        }
        // ② 无锚点：先过锚点准入与起锚确认，再直通起锚（初锁/逃逸后）。
        guard let anchor = lastPick else {
            // 锚点准入（FR-003）：亚页面候选可显示（透传），但不得成为锚点——
            // 文字带既不保护自己、也不进入分支④的续命循环。
            if selection.quad.area < anchorMinArea {
                lastDisposition = .passthrough
                return selection
            }
            // 起锚确认（FR-003）：连续 K 帧相似择优才起锚（默认 1 = 立即起锚，
            // v1/v2 语义）。未达标期间逐帧透传，显示跟随检测但不占用锚点。
            if reanchorConfirmFrames > 1 {
                if let pending = pendingPick,
                   selection.quad.iou(with: pending) >= similarityThreshold {
                    pendingCount += 1
                } else {
                    pendingPick = selection.quad
                    pendingCount = 1
                }
                if pendingCount < reanchorConfirmFrames {
                    lastDisposition = .passthrough
                    return selection
                }
            }
            lastPick = selection.quad
            lastTier = selection.tier
            missCount = 0
            pendingPick = nil
            pendingCount = 0
            lastDisposition = .anchored
            return selection
        }
        // ③ 相似跟随：锚点随小幅漂移更新，miss 清零。
        // 面积比守卫（FR-003，默认 0 = 关闭）：分支③允许 IoU≥阈值的候选逐帧
        // 收缩至多 30% 面积——包含链棘轮会把锚点从 0.45 一路缩到 0.09
        // （0.45×0.7^n）。面积比 < ratio 的"相似"候选不跟随，交④/⑤处理。
        let followsArea = followMinAreaRatio <= 0
            || Self.areaRatio(selection.quad.area, anchor.area) >= followMinAreaRatio
        if selection.quad.iou(with: anchor) >= similarityThreshold, followsArea {
            lastPick = selection.quad
            lastTier = selection.tier
            missCount = 0
            pendingPick = nil
            pendingCount = 0
            lastDisposition = .follow
            return selection
        }
        // ④ 止跳改写：池中锚点相似候选优先延续（评分最高者胜），先稳者胜。
        if let stickyQuad = pool
            .filter({ $0.iou(with: anchor) >= similarityThreshold })
            .max(by: { $0.score() < $1.score() })
        {
            lastPick = stickyQuad
            lastTier = selection.tier
            missCount = 0
            lastDisposition = .override
            return DetectionStrategy.Selection(quad: stickyQuad, tier: selection.tier)
        }
        // ⑤ 无相似候选：计 miss。达限清空锚点透传新择优（FR-007 逃逸）；
        // v2 hold-through-miss：达限前维持锚点——存在性交替场景本帧池结构性
        // 无相似候选，透传即跳变源头；v1 语义 miss 期间透传。
        missCount += 1
        if missCount >= missLimit {
            lastPick = nil
            lastDisposition = .escape
            return selection
        }
        if holdThroughMiss {
            lastDisposition = .hold
            return DetectionStrategy.Selection(quad: anchor, tier: lastTier)
        }
        lastDisposition = .passthrough
        return selection
    }

    /// 两框面积比（小 / 大，∈ (0, 1]）；任一非正时返回 0（守卫按拒绝处理）。
    private static func areaRatio(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs > 0, rhs > 0 else { return 0 }
        return min(lhs, rhs) / max(lhs, rhs)
    }
}
