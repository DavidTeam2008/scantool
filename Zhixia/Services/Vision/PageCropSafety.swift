import Foundation

/// 页面裁切安全门（page-preprocess P0）。
///
/// 裁切/增强会改变 Vision 的表格判定：真机 A/B 曾出现 2×5 表 → 0 表。
/// 本门禁只比较**结构化识别产物**，不读像素；未裁切页有表而裁切页丢表/变列
/// 时返回 false，调用方应放弃裁切、保留原图。
enum PageCropSafety {
    struct Signature: Equatable, Sendable {
        var tableCount: Int
        var shapes: [[Int]]
        var cells: [[[String]]]
    }

    static func signature(_ page: StructuredDocumentPage) -> Signature {
        let tables = page.tables.map(\.table)
        return Signature(
            tableCount: tables.count,
            shapes: tables.map { table in
                [table.rows.count, table.columnCount]
            },
            cells: tables.map { table in
                table.rows.map { row in
                    row.map { normalize($0) }
                }
            }
        )
    }

    /// 原页无表 → 裁切安全（没有表可丢）；原页有表 → 行列/单元格必须一致。
    static func isSafe(original: StructuredDocumentPage, cropped: StructuredDocumentPage) -> Bool {
        let originalSig = signature(original)
        guard originalSig.tableCount > 0 else { return true }
        let croppedSig = signature(cropped)
        guard originalSig.tableCount == croppedSig.tableCount else { return false }
        guard originalSig.shapes == croppedSig.shapes else { return false }
        return originalSig.cells == croppedSig.cells
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
