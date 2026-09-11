import CoreGraphics
import Foundation

/// M2 表格识别的产物。
struct TableGridV2: Equatable, Sendable {
    var table: ReconstructTable
    /// 所有网格线的外接框（最小覆盖行 + 列的 bbox）。
    var bbox: CGRect
    /// 行数 / 列数（构造时定型，不再变）。
    var rowCount: Int
    var columnCount: Int
    /// 哪些行被识别为表头（用于 DOCX 渲染加粗）。
    var headerRowIndices: [Int]
    /// 命中的 profile 名（nil = 通用表检测，无 profile 兜底）。
    var profileName: String?
    /// 总体置信度（0~1）。当前用 occupancy × looksLikeDataTable 综合给。
    var confidence: Double
}
