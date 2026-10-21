import Foundation

/// 候选快照构造（spec/guided-capture T002 / FR-007）——**纯函数**，可单测。
///
/// ## 载荷规则（与 FR-007 一一对应）
/// 1. **全部 viable** 进入快照（`viable` = 非退化且面积 > `minArea`）；
/// 2. 再补 **top 8**（按 score 降序）——用于看清「输给右页的那些框」；
/// 3. 硬上限 **16**：超出部分记 `droppedCount`（丢弃必须可数，不静默丢）；
/// 4. 每条记四角、面积、score、containment、tier、是否 viable；
/// 5. 另记总数（`rawCount` / `viableCount`）与最大面积（`maxArea`）。
///
/// ## 排序口径
/// score 降序；同分时按面积降序、原索引升序——**确定性**排序（回放与
/// 单测都要求同一候选集得到同一顺序）。
enum CandidateSnapshotBuilder {
    /// 快照内候选硬上限。
    static let hardLimit = 16
    /// top N（按 score）。
    static let topCount = 8

    /// 构造一帧候选快照。
    static func build(
        rawCandidates: [Quad],
        selection: DetectionStrategy.Selection?,
        effective: DetectionStrategy.Selection?,
        disposition: String?,
        stickyMissCount: Int = 0,
        path: CandidateSnapshot.Path,
        idCardMode: Bool,
        timestamp: Date
    ) -> CandidateSnapshot {
        let metas = rawCandidates.enumerated().map { index, quad in
            CandidateSnapshot.Candidate(
                quad: quad,
                area: quad.area,
                score: quad.score(),
                containment: maxContainment(of: quad, at: index, in: rawCandidates),
                tier: tier(of: quad),
                viable: isViable(quad)
            )
        }

        let ranked = metas.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score {
                    return lhs.element.score > rhs.element.score
                }
                if lhs.element.area != rhs.element.area {
                    return lhs.element.area > rhs.element.area
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        // ① 全部 viable（按 score 降序）优先占位。
        var keptIndices: [Int] = []
        for (index, meta) in metas.enumerated() where meta.viable {
            guard keptIndices.count < hardLimit else { break }
            keptIndices.append(index)
        }
        // ② 余位按 score 降序补齐（自然包含 top 8）。
        for (index, _) in ranked.enumerated() {
            guard keptIndices.count < hardLimit else { break }
            if !keptIndices.contains(index) {
                keptIndices.append(index)
            }
        }

        let keptSet = Set(keptIndices)
        let kept = ranked.enumerated()
            .filter { keptSet.contains($0.offset) }
            .map(\.element)

        let viableMetas = metas.filter(\.viable)
        return CandidateSnapshot(
            timestamp: timestamp,
            path: path,
            idCardMode: idCardMode,
            rawCount: metas.count,
            viableCount: viableMetas.count,
            droppedCount: max(0, metas.count - kept.count),
            maxArea: viableMetas.map(\.area).max() ?? 0,
            selectionArea: effective?.quad.area ?? -1,
            tier: effective?.tier ?? 0,
            disposition: disposition,
            stickyMissCount: stickyMissCount,
            candidates: kept
        )
    }

    /// viable 判定（与 `DetectionStrategy.viablePool` 同口径——单一真源）。
    static func isViable(_ quad: Quad) -> Bool {
        !quad.isDegenerate && quad.area > DetectionStrategy.minArea
    }

    /// 面积档位：0 = 不入池（退化/过小），1 = 一级（<0.96），2 = 二级（≤1.0）。
    static func tier(of quad: Quad) -> Int {
        guard isViable(quad) else { return 0 }
        return quad.area < DetectionStrategy.primaryMaxArea ? 1 : 2
    }

    /// 自身被**更大**候选包围的最大比例（≥0.9 触发包含降权 ×0.35）。
    ///
    /// 只与「面积不小于自己」的候选比较——与 `DetectionStrategy.isPenalized`
    /// 的判定同口径（被更小的候选覆盖不构成降权理由，否则外框会被自己的
    /// 内框「反向包含」成 0.56 这种无意义数字）。
    static func maxContainment(of quad: Quad, at index: Int, in candidates: [Quad]) -> Double {
        var best: Double = 0
        for (otherIndex, other) in candidates.enumerated() where otherIndex != index {
            guard other.area >= quad.area else { continue }
            best = max(best, quad.containment(in: other))
        }
        return best
    }
}
