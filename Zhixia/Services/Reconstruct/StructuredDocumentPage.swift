import CoreGraphics
import Foundation

/// 一次「取文本行 + 取表格 + 取条码」的结果。
///
/// 存在的理由：把这三件事从 `OnDeviceDocumentParser` 里抽出来，让
/// **iOS 26 的 `RecognizeDocumentsRequest`**（`VisionDocumentStructureRecognizer`）
/// 与**几何回退管线**（Vision OCR + `TableGridV2Detector`；v1 `OnDeviceTableCluster`
/// 已退役休眠）产出**同样的形状**。这样下游 —— 噪声过滤 / 阅读序 / 配图 / 块排序 /
/// 三档导出 —— 一行都不用改，两条通路的差异被关在这一个类型里。
///
/// 坐标一律是 **Vision 归一化坐标（原点左下，y 向上）**，与 `OCRLine.boundingBox` 同系。
/// 不要在这里做 y 翻转。
struct StructuredDocumentPage: Sendable, Equatable {
    /// 文本行。粒度是**行**而不是段落 —— 下游 `OnDeviceReadingOrder` 是按行做行聚类、
    /// 段落聚类、标题判定的，喂段落级 bbox 会丢掉它的粒度假设。
    var lines: [OCRLine]
    /// 表格。iOS 26 通路给的是**行列结构**（含合并单元格的 `Range`），几何通路给的是聚类结果。
    var tables: [DetectedTable]
    /// 条码。几何通路需要额外跑一次 `PageBarcodeDetector`；iOS 26 通路同一次请求就带回来了。
    var barcodes: [DetectedBarcode]
    /// 来源。只用于诊断与日志，不参与任何判定。
    var source: Source

    enum Source: String, Sendable, Equatable, Codable {
        /// iOS 26 `RecognizeDocumentsRequest`
        case documentRequest
        /// Vision OCR + 几何表格聚类
        case geometric
    }

    /// 有没有可用于还原的内容。空结果必须让调用方回退，不能当成「这页没东西」。
    var hasContent: Bool {
        !lines.isEmpty || tables.contains { !$0.table.rows.isEmpty }
    }

    /// 供 `ReconstructSceneRouter` 做场景判定。
    var joinedText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}
