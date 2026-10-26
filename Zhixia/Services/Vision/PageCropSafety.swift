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

    /// 左侧裁切线与参照页所有表 bbox 是否完全不相交。
    ///
    /// 只用于**页级左缘内收**：裁掉的是页边空白，表在裁切线右侧时，几何上
    /// 不可能丢表。`RecognizeDocumentsRequest` 对同一页的轻微宽度变化会偶发
    /// 返回 0 表（真机 `IMG_7542` 已复现），此时用几何证明兜底，而不是因为
    /// 检测抖动把 1% 页边永久留下。
    ///
    /// `fraction` 是内收量占参照页宽的比例；`bbox` 是矫正页归一化坐标。
    static func tablesClear(
        ofLeftFraction fraction: Double,
        in page: StructuredDocumentPage,
        margin: Double = 0.005
    ) -> Bool {
        guard fraction > 0, !page.tables.isEmpty else { return false }
        return page.tables.allSatisfy { table in
            table.bbox.minX >= CGFloat(fraction + margin)
        }
    }

    /// 裁切矩形是否完整包含参照页所有表 bbox。
    ///
    /// 用于 P0.1 的整体纸张/内容包络：`RecognizeDocumentsRequest` 对同一页
    /// 的轻微裁切常偶发返回 0 表；若所有表 bbox 都在裁切框内，几何上证明
    /// 表没有被裁掉，可以继续采用裁切，而不是因为识别抖动永远保留页外背景。
    static func tablesClear(
        of cropRect: CGRect,
        in page: StructuredDocumentPage,
        margin: Double = 0.004
    ) -> Bool {
        guard !page.tables.isEmpty else { return false }
        let expanded = cropRect.insetBy(dx: -margin, dy: -margin)
        return page.tables.allSatisfy { table in
            // table.bbox 是 Vision 归一化左下原点；cropRect 是左上原点。
            let bbox = CGRect(
                x: table.bbox.minX,
                y: 1 - table.bbox.maxY,
                width: table.bbox.width,
                height: table.bbox.height
            )
            return expanded.contains(bbox)
        }
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
