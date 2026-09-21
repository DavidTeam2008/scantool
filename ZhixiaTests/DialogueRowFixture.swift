import CoreGraphics
import Foundation
@testable import Zhixia

/// T001（spec/scan-fidelity）：真机取证页「双栏英语练习册」对话区的 OCR 分段几何固化
/// —— US2 行聚类（T014）与 US3 稳定性（T015）的断言基准。
///
/// ## 来源
/// 真机取证页（叠字/乱序/断行样张）108 行中对话区段，本地 Vision 同参对照。
/// 坐标为 Vision 原生归一化（原点左下，y 向上），与 `OCRLine.boundingBox` 一致。
///
/// ## 为什么是这 7 个分段
/// - 同排异高分段：行 A（"1 A: YesterdayI" h=0.0118 与 "three hours doing those"
///   h=0.0176，顶对齐）、行 C（等高）、行 D（"yOu" h=0.0102 与
///   "the maths problems？" h=0.0176，底对齐）—— 同排合并不得被高度差拆散（R1）；
/// - 相邻视觉行样本：行 B（minY 0.7662）与行 A 第二段（minY 0.7764）仅差
///   0.0102 —— 旧规则 `max(0.012, 0.3×h)` 的 0.012 绝对下限把它们误并成一行
///   （R2 根因："physics exercises for homework. three hours doing those" 乱序拼接），
///   新规则必须分开；行 A 两段 minY 差 0.0058 则必须仍然合并；
/// - 段间填空宽空隙（0.101 / 0.100 / 0.103 归一化页宽）—— US2 下划线占位断言的依据。
///
/// ⚠ 真值来自真机取证记录，勿改 —— T014/T015 断言数值与本表配套。
enum DialogueRowFixture {
    /// 单个 OCR 分段（取证原值；Vision y-up 归一化坐标）。
    struct Segment: Sendable {
        let text: String
        let x: CGFloat
        /// minY（Vision y-up：值越大越靠页顶）
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var line: OCRLine {
            OCRLine(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// 视觉行 A（页顶 ≈ 0.206）：同排异高 + 顶对齐 —— "1 A: YesterdayI three hours doing those"。
    static let rowA: [Segment] = [
        Segment(text: "1 A: YesterdayI", x: 0.051, y: 0.7822, width: 0.127, height: 0.0118),
        Segment(text: "three hours doing those", x: 0.279, y: 0.7764, width: 0.173, height: 0.0176)
    ]

    /// 视觉行 B（页顶 ≈ 0.219）：单段；与行 A 第二段 minY 差 0.0102 —— 旧规则误并的触发样本。
    static let rowB: [Segment] = [
        Segment(text: "physics exercises for homework.", x: 0.098, y: 0.7662, width: 0.235, height: 0.0148)
    ]

    /// 视觉行 C（页顶 ≈ 0.240）：同排等高 —— "B:It me a long time, too."。
    static let rowC: [Segment] = [
        Segment(text: "B:It", x: 0.076, y: 0.7460, width: 0.036, height: 0.0140),
        Segment(text: "me a long time, too.", x: 0.212, y: 0.7460, width: 0.144, height: 0.0140)
    ]

    /// 视觉行 D（页顶 ≈ 0.254）：同排异高 + 底对齐 —— "yOu the maths problems？"。
    static let rowD: [Segment] = [
        Segment(text: "yOu", x: 0.149, y: 0.7358, width: 0.028, height: 0.0102),
        Segment(text: "the maths problems？", x: 0.280, y: 0.7284, width: 0.153, height: 0.0176)
    ]

    static var allRows: [[Segment]] { [rowA, rowB, rowC, rowD] }

    /// OCR 行集合（按视觉行自上而下排列；`makeBlocks` 内部会重排，输入顺序不影响聚类结果）。
    static var lines: [OCRLine] {
        allRows.flatMap { $0 }.map(\.line)
    }

    // MARK: - 期望聚类（T014 断言基准）

    /// 每视觉行拼接文本（拉丁规则空格连接 —— 与 `OnDeviceReadingOrder.join` 同规则）。
    static let expectedRowTexts: [String] = [
        "1 A: YesterdayI three hours doing those",
        "physics exercises for homework.",
        "B:It me a long time, too.",
        "yOu the maths problems？"
    ]

    /// 每视觉行的分段成员（按文本）。
    static let expectedRowGroups: [[String]] = [
        ["1 A: YesterdayI", "three hours doing those"],
        ["physics exercises for homework."],
        ["B:It", "me a long time, too."],
        ["yOu", "the maths problems？"]
    ]

    /// 块 minX（= 各行 minX 最小值；segments 采集的 offset 基准）。
    static let expectedBlockMinX: CGFloat = 0.051

    /// 每行 segments 期望值（T011 采集 / T014 断言）：
    /// offset = 分段 minX − 块 minX；width = 分段宽。行内按 minX 升序。
    static let expectedSegmentsByRow: [[ExpectedSegment]] = [
        [
            ExpectedSegment(text: "1 A: YesterdayI", offset: 0.000, width: 0.127),
            ExpectedSegment(text: "three hours doing those", offset: 0.228, width: 0.173)
        ],
        [
            ExpectedSegment(text: "physics exercises for homework.", offset: 0.047, width: 0.235)
        ],
        [
            ExpectedSegment(text: "B:It", offset: 0.025, width: 0.036),
            ExpectedSegment(text: "me a long time, too.", offset: 0.161, width: 0.144)
        ],
        [
            ExpectedSegment(text: "yOu", offset: 0.098, width: 0.028),
            ExpectedSegment(text: "the maths problems？", offset: 0.229, width: 0.153)
        ]
    ]

    /// 单个分段期望值（块相对水平几何）。
    struct ExpectedSegment: Sendable {
        let text: String
        let offset: Double
        let width: Double
    }

    /// 行内分段间宽空隙（归一化页宽；行 A / C / D 的填空空档，下划线占位断言依据）。
    static let expectedIntraRowGaps: [Double] = [0.101, 0.100, 0.103]
}
