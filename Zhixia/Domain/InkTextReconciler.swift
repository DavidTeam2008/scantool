import CoreGraphics
import Foundation

/// 墨迹-文本对账纯函数（spec/wps-parity-layout plan D5 / FR-006 / T012）。
///
/// 问题：导出的文字层是否覆盖了原页的所有墨迹？——「原页有墨但文字层无
/// 对应文本」的区域就是潜在丢字。对账在导出前逐页执行、只记日志不阻断
/// （FR-006）；墨迹证据来自 `InkRegionProviding`（原始连通域，见
/// `InkFigureDetector.rawInkRegions` 的闸门说明）。
///
/// 分类优先级：**先解释、再归因、最后定罪**——
/// 1. 墨迹被文字行采样覆盖 ≥ `explainedCoverage` → 不是缺口；
/// 2. 缺口落 figure/artwork 块 bbox → `.figureOverlap`（图形墨，预期）；
/// 3. 落表格/条码块 bbox → `.structureSwallow`（结构墨；其文本由解析期
///    containment 不变量（T009 `splitCarriedLines`）保障，违规在那边计数）；
/// 4. 贴页缘带 → `.edgeBand`（页眉/页脚/系统 chrome，预期噪声）；
/// 5. 都不是 → `.likelyMissed`（疑似 OCR 漏识 —— 哨兵核心证据）。
///
/// 文字覆盖刻意取**行级**（`BlockLine` 重建）而非块级：丢字哨兵防的正是
/// 「块还在、块内某行被漏」——块级覆盖会把这类丢失整个藏住。
/// 覆盖率用区域内均匀采样点估计：确定性、纯函数，且天然支持多矩形并集覆盖。
enum InkTextReconciler {

    // MARK: - 常量

    /// 采样密度：每边 8 点 → 64 采样点/区域（线级墨迹 ≈ 0.05×0.015，
    /// 采样步长 ~0.006×0.002，粒度足够）。
    static let sampleSteps = 8

    /// 「已被解释」的覆盖阈值：≥ 50% 采样点落进该类区域即算覆盖。
    /// 留一半余量容忍相邻行墨迹连通成一团的边界情形。
    static let explainedCoverage: Double = 0.5

    /// 页缘带阈值，与 `OnDeviceDocumentParser` OCR 噪声判定（0.965/0.035）
    /// 同值同义：墨迹整块贴页顶（maxY > 0.965）或贴页底（minY < 0.035）
    /// 按页缘 chrome 归因。
    static let edgeBandTopY: Double = 0.965
    static let edgeBandBottomY: Double = 0.035

    /// 行级文字区域的膨胀量：行几何从 `BlockLine`（块相对坐标）重建，
    /// 描边/下划线略超行框在所难免；0.3% 页宽的 padding 让覆盖判定稳。
    static let textRegionPadding: Double = 0.003

    // MARK: - 对账（纯几何）

    /// 对账主入口。所有区域均为 Vision 归一化坐标（原点左下）。
    static func reconcile(
        inkRegions: [CGRect],
        textRegions: [CGRect],
        figureRegions: [CGRect],
        structureRegions: [CGRect]
    ) -> MissingTextReport {
        var gaps: [InkGap] = []
        for ink in inkRegions {
            guard !ink.isEmpty else { continue }
            // 1. 已被文字解释 → 不是缺口。
            guard coverage(ink, in: textRegions) < explainedCoverage else { continue }
            // 2~5. 未解释墨迹按优先级归因。
            let category: InkGapCategory
            if coverage(ink, in: figureRegions) >= explainedCoverage {
                category = .figureOverlap
            } else if coverage(ink, in: structureRegions) >= explainedCoverage {
                category = .structureSwallow
            } else if ink.maxY > edgeBandTopY || ink.minY < edgeBandBottomY {
                category = .edgeBand
            } else {
                category = .likelyMissed
            }
            gaps.append(InkGap(frame: ink, category: category))
        }
        return MissingTextReport(gaps: gaps)
    }

    /// 页模型适配重载：从 `ReconstructPage.blocks` 抽三类区域后对账。
    ///
    /// 刻意读 `blocks`（识别几何）而非 `restoredBlocks` —— 高保真档的布局
    /// 引擎会搬动块位置，对账必须用与原页同一坐标参照系的识别产物。
    /// 墨迹为空（图片不可解码 / 无墨）自然产出空报告，哨兵不阻断。
    static func reconcile(page: ReconstructPage, inkRegions: [CGRect]) -> MissingTextReport {
        reconcile(
            inkRegions: inkRegions,
            textRegions: textRegions(of: page.blocks),
            figureRegions: page.blocks
                .filter { $0.kind == .figure || $0.kind == .artwork }
                .map(\.bbox),
            structureRegions: page.blocks
                .filter { $0.kind == .table || $0.kind == .barcode }
                .map(\.bbox)
        )
    }

    // MARK: - 文字行区域抽取

    /// 文本块 → 行级覆盖区域。`lines` 缺失（旧数据 / 非文本来源块）回退块 bbox。
    private static func textRegions(of blocks: [ReconstructBlock]) -> [CGRect] {
        blocks.flatMap { block -> [CGRect] in
            switch block.kind {
            case .heading, .paragraph, .list, .checkbox, .handwrittenBlank:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                guard let lines = block.lines, !lines.isEmpty else { return [block.bbox] }
                return lineRegions(lines: lines, blockBBox: block.bbox)
            case .table, .figure, .barcode, .artwork:
                // 结构/图形块的墨归因走 structure/figure 分类，不进文字覆盖。
                return []
            }
        }
    }

    /// `BlockLine`（块相对几何）→ 页归一化行框。垂直重建与渲染端同口径：
    /// 块 bbox = 行并集 ⇒ 首行顶 = 块顶；下行顶 = 上行底 − gapToPrevious
    /// （首行 gap = 0，`OnDeviceReadingOrder.blockLines` 的产出契约）。
    private static func lineRegions(lines: [BlockLine], blockBBox: CGRect) -> [CGRect] {
        var regions: [CGRect] = []
        var previousMinY = blockBBox.maxY
        let pad = CGFloat(textRegionPadding)
        for line in lines {
            let top = previousMinY - CGFloat(line.gapToPrevious)
            let y = top - CGFloat(line.height)
            regions.append(
                CGRect(
                    x: blockBBox.minX + CGFloat(line.leadingOffset),
                    y: y,
                    width: CGFloat(line.width),
                    height: CGFloat(line.height)
                )
                .insetBy(dx: -pad, dy: -pad)
            )
            previousMinY = y
        }
        return regions
    }

    // MARK: - 采样覆盖

    /// 区域内 `sampleSteps`² 个均匀采样点落进 `rects` 任一点的占比
    /// （确定性采样，多矩形并集覆盖天然成立）。
    private static func coverage(_ region: CGRect, in rects: [CGRect]) -> Double {
        guard !rects.isEmpty, region.width > 0, region.height > 0 else { return 0 }
        var hit = 0
        let total = sampleSteps * sampleSteps
        for row in 0..<sampleSteps {
            for column in 0..<sampleSteps {
                let point = CGPoint(
                    x: region.minX + (CGFloat(column) + 0.5) / CGFloat(sampleSteps) * region.width,
                    y: region.minY + (CGFloat(row) + 0.5) / CGFloat(sampleSteps) * region.height
                )
                if rects.contains(where: { $0.contains(point) }) {
                    hit += 1
                }
            }
        }
        return Double(hit) / Double(total)
    }
}
