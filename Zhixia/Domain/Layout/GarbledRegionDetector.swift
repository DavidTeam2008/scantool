import CoreGraphics
import Foundation

/// 乱码区域判定产物（spec/layout-restore plan D4）。
///
/// `regions` 为判定成立的区域；`isGarbled(_:)` 供 parser 把对应文字行从文字层剔除
/// （FR-003：乱码文本不出现在还原结果与导出文档中）。证据值（置信度 / 质量分 /
/// 墨块重叠率）随区域携带，供 `ZhixiaLog.reconstructArtwork` 与阈值调优（plan D10）。
struct GarbledRegionJudgement: Sendable, Equatable {
    /// 一个判定成立的乱码区域（艺术字 / 图章 / 手绘字等）。
    struct Region: Sendable, Equatable {
        /// 区域矩形 = 成员乱码行 bbox 的并集（Vision 归一化，左下原点）。
        /// 刻意**不**并上墨块证据区域 —— 墨块也可能罩住邻近正常文本的覆盖区，
        /// 并进去会让 artwork 块把正常文本的区域一并圈走。
        var rect: CGRect
        /// 成员乱码行在输入 `lines` 数组中的下标（输入顺序）。
        var lineIndices: [Int]
        // MARK: 双门控证据值
        /// 信号门控证据 A：成员行各自的 Vision 置信度（与 `lineIndices` 对齐）。
        var confidences: [Double]
        /// 信号门控证据 B：成员行各自的 `OCRTextQuality` 分数（与 `lineIndices` 对齐）。
        var qualityScores: [Int]
        /// 墨块门控证据：区域被「被文字覆盖墨块」覆盖的面积占比（0~1）。
        var inkOverlap: CGFloat
        /// 与区域相交的墨块证据区域数。
        var inkRegionCount: Int
    }

    /// 判定成立的区域集合（按输入行下标升序）。
    var regions: [Region]
    /// 通过信号门控的候选行数（**未**过墨块门控的全部行 —— 供日志观测信号门控触达面）。
    var candidateLineCount: Int
    /// 候选行中的最低置信度（无候选时为 1.0）。
    var lowestConfidence: Double

    init(
        regions: [Region] = [],
        candidateLineCount: Int = 0,
        lowestConfidence: Double = 1.0
    ) {
        self.regions = regions
        self.candidateLineCount = candidateLineCount
        self.lowestConfidence = lowestConfidence
    }

    var isEmpty: Bool { regions.isEmpty }

    var removedLineCount: Int {
        regions.reduce(0) { $0 + $1.lineIndices.count }
    }

    /// 第 `lineIndex` 行（输入数组的下标）是否被判为乱码行（应从文字层剔除）。
    func isGarbled(_ lineIndex: Int) -> Bool {
        regions.contains { $0.lineIndices.contains(lineIndex) }
    }
}

/// 乱码区域双门控判定（spec/layout-restore plan D4）。
///
/// 艺术字 / 手绘字 / 图章等无法准确识别为纯文本的区域，OCR 会把它们读成乱码文本行
/// —— 旧版这些行直接混进正文（用户痛点「识别成了乱码」），而图片通道又因
/// 「被文字盒覆盖即排除」（`InkFigureDetector.maxTextCoverage`）恰好把它们排除在外。
///
/// ## 双门控（缺一不可）
///
/// 1. **信号门控**（行级）：`confidence < maxConfidence` **且**
///    `OCRTextQuality.score ≤ maxQualityScore`。
///    - 置信度低：Vision 自己都不确定读对了；
///    - 质量分低：读出的东西不是像样的文字（符号汤 / 稀奇古怪的组合）。
///    - **两者同时成立才算低信号** —— 识别正确的文字质量分天然为正
///      （CJK ×8 / 字母 +1），所以「低置信但认对了」的生僻字、模糊小字不是候选；
///      反过来「高置信」的行无论质量分多低都永不剔除（保守性由单测钉死）。
///      这是 FR-004「误杀率趋零优先于乱码清除率」的直接实现。
/// 2. **墨块门控**（区域级）：低信号行先做空间聚类（相邻行合并成候选区域），
///    候选区域与 `InkFigureDetector` 的**被文字覆盖墨块**（`textCoveredInkRegions`）
///    重叠率达到 `minInkOverlap` 才判定成立 —— 只低置信而无墨块证据的行
///    （正常小字被误读）保留为文本；只与墨块擦边的行也不判定。
///
/// Domain 纯逻辑：无 I/O、无像素读取（墨块证据由调用方从 `InkFigureDetector` 取得）。
enum GarbledRegionDetector {

    /// 判定阈值（全部参数化，供真机调优与单测构造边界用例）。
    struct Thresholds: Sendable, Equatable {
        /// 信号门控 A：行置信度上限（低于才算低信号）。0.5 —— 正常识别通常 > 0.5，
        /// 艺术字乱码通常 < 0.4；配合质量门控后不必压得更低。
        var maxConfidence: Double = 0.5
        /// 信号门控 B：行质量分上限（不高于才算低信号）。0 —— 符号汤为负，
        /// 认对的真实文字（哪怕生僻）为正。
        var maxQualityScore: Int = 0
        /// 空间聚类间隙（Vision 归一化单位）：两个低信号行 bbox 外扩该间隙后
        /// 相交即并簇。0.02 ≈ 一倍典型行高，能把艺术字区域里相邻的乱码行并成区域，
        /// 又不会把版面上相距远的两处各自并起来。
        var clusterGap: CGFloat = 0.02
        /// 墨块门控：候选区域被墨块证据覆盖的面积占比下限。
        var minInkOverlap: CGFloat = 0.3
    }

    /// 双门控判定入口。
    ///
    /// - Parameters:
    ///   - lines: 该页全部文字行（Vision 归一化 bbox，左下原点）。
    ///   - inkRegions: `InkFigureDetector.detect` 的 `textCoveredInkRegions`
    ///     （被文字覆盖墨块 —— 艺术字/图章的空间证据）。
    ///   - thresholds: 判定阈值。
    /// - Returns: 判定产物（区域 + 证据值）；无成立区域时 `regions` 为空。
    static func detect(
        lines: [OCRLine],
        inkRegions: [CGRect],
        thresholds: Thresholds = Thresholds()
    ) -> GarbledRegionJudgement {
        // 信号门控：低置信 且 低质量（保守 —— 高置信行 / 认对的行永不进候选）。
        let candidates: [(index: Int, line: OCRLine)] = lines.enumerated().compactMap { offset, line in
            guard line.confidence < thresholds.maxConfidence,
                  OCRTextQuality.score(line.text) <= thresholds.maxQualityScore else {
                return nil
            }
            return (index: offset, line: line)
        }
        guard !candidates.isEmpty else {
            return GarbledRegionJudgement()
        }
        let lowest = candidates.map(\.line.confidence).min() ?? 1.0

        // 空间聚类：候选行 bbox 外扩 clusterGap 后两两合并（传递闭包）。
        var clusters: [[(index: Int, line: OCRLine)]] = candidates.map { [$0] }
        var rects: [CGRect] = candidates.map(\.line.boundingBox)
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let reach = rects[i].insetBy(dx: -thresholds.clusterGap, dy: -thresholds.clusterGap)
                    guard !rects[j].isNull, reach.intersects(rects[j]) else { continue }
                    clusters[i].append(contentsOf: clusters[j])
                    rects[i] = rects[i].union(rects[j])
                    clusters.remove(at: j)
                    rects.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }

        // 墨块门控：候选区域被墨块证据覆盖的面积占比达标才判定成立。
        var regions: [GarbledRegionJudgement.Region] = []
        for (cluster, rect) in zip(clusters, rects) where rect.width > 0 && rect.height > 0 {
            let clusterArea = rect.width * rect.height
            var covered: CGFloat = 0
            var overlappingRegions = 0
            for ink in inkRegions where ink.intersects(rect) {
                let intersection = ink.intersection(rect)
                guard !intersection.isNull else { continue }
                overlappingRegions += 1
                covered += intersection.width * intersection.height
            }
            let overlap = min(covered / clusterArea, 1)
            guard overlappingRegions > 0, overlap >= thresholds.minInkOverlap else { continue }

            let sorted = cluster.sorted { $0.index < $1.index }
            regions.append(
                GarbledRegionJudgement.Region(
                    rect: rect,
                    lineIndices: sorted.map(\.index),
                    confidences: sorted.map(\.line.confidence),
                    qualityScores: sorted.map { OCRTextQuality.score($0.line.text) },
                    inkOverlap: overlap,
                    inkRegionCount: overlappingRegions
                )
            )
        }

        return GarbledRegionJudgement(
            regions: regions,
            candidateLineCount: candidates.count,
            lowestConfidence: lowest
        )
    }
}
