import CoreGraphics
import Foundation

enum LayoutRegionKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case header
    case body
    case footer
}

struct LayoutRegion: Sendable, Equatable, Codable, Hashable {
    var kind: LayoutRegionKind
    var frame: CGRect
    /// 输入 lines 的下标（与 OCRLine 数组对齐），region 内的行子集。
    var lineIndices: [Int]
}

struct LayoutColumn: Sendable, Equatable, Codable, Hashable {
    var id: Int
    var frame: CGRect
    var isPrimary: Bool
    /// 低置信（如 < 0.3）视为未分栏，下游应回退为单栏处理。
    var confidence: Double
    var lineIndices: [Int]
}

struct LayoutBand: Sendable, Equatable, Codable, Hashable {
    var frame: CGRect
    var lineIndices: [Int]
}

/// M1 的版面分析产物。OCRLine 之外的「版」信息全在这里：
/// 同一行可以同时属于一个 region、一个 column、一个 band，并带若干个 anchor（通常 0~1）。
///
/// 与 IR 的关系：Document 持 version 字段；Page 持 layout 字段；
/// Block 持 semantic / anchors / confidence 字段（v2 新增，向后兼容）。
struct PageLayout: Sendable, Equatable, Codable, Hashable {
    /// 所有输入行的外接框；空集为 .zero。
    var contentBounds: CGRect
    var medianLineHeight: CGFloat
    var medianGap: CGFloat
    /// 自上而下的水平内容带（按大间隙/表标题切分）。
    var bands: [LayoutBand]
    /// 头/正文/尾分区。bands 的语义分类结果，可能少于 bands（中间的全是 body）。
    var regions: [LayoutRegion]
    /// 栏结构；置信度 < 0.3 视为未分栏。
    var columns: [LayoutColumn]
    /// 语义锚点。
    var anchors: [LayoutAnchor]
    /// 与输入 lines 一一对齐的语义标签。
    var lineSemantics: [ReconstructSemanticTag?]
}

/// 几何/统计小工具。单独一个 namespace 方便复用，也避免在 Domain 里塞全局函数。
enum LayoutMath {
    static func unionBounds(of lines: [OCRLine]) -> CGRect {
        guard let first = lines.first else { return .zero }
        return lines.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
    }

    static func median(of values: [CGFloat], fallback: CGFloat = 0.02) -> CGFloat {
        guard !values.isEmpty else { return fallback }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
