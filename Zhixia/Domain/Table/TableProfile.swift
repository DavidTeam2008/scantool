import CoreGraphics
import Foundation

/// 表格 profile —— 让 `TableGridV2Detector` 知道「这种表长什么样」。
///
/// M2 的关键变化：v1 是「看着像表格就当表格」；v2 是「先识别表标题/锚点，再按 profile 收紧」。
/// profile 决定：
/// - 用哪些关键词当 `tableTitle` 锚点
/// - 期望的列数（用于 reject 列数不符的候选）
/// - 哪些词出现在表头行（用于标 bold + 标记为 header row）
/// - focus 窗口在表标题下方最多延伸多远（Vision 坐标，原点左下）
struct TableProfile: Sendable, Equatable, Hashable {
    var name: String
    /// 触发该 profile 的 tableTitle 关键词。OCR 文本含任一即视作该表。
    var titlePatterns: [String]
    /// 期望的列数（v2 仍允许列数与 profile 不完全一致；用于校验/打分）。
    var expectedColumnCount: Int
    /// 表头行的判定词。第一行若任一 cell 包含任一词，即判为 header。
    var headerKeywords: [String]
    /// 焦点窗口：tableTitle 中线下方最多延伸多远（Vision 归一化）。
    /// 太宽会吸进底部条码/页脚；太窄会丢长表。当前 0.22 适配 5~6 行 + 1 表头。
    var focusWindowBelow: CGFloat

    /// 中文 / 英式营养成分表
    static let nutrition = TableProfile(
        name: "nutrition",
        titlePatterns: [
            "营养成分表",
            "营养配料表",
            "Nutrition Facts",
            "Nutrition Information",
            "Supplement Facts"
        ],
        expectedColumnCount: 3,
        headerKeywords: ["项目", "每", "NRV", "Per 100", "Per100", "每100", "每 100"],
        focusWindowBelow: 0.22
    )
}
