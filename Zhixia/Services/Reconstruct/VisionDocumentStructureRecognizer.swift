import CoreGraphics
import Foundation
import Vision

/// iOS 26 `RecognizeDocumentsRequest` 的封装 —— 整条还原链路里**唯一**能拿到
/// 「表格行列结构」的地方。
///
/// 为什么关键：老的 `VNRecognizeTextRequest` 只给 **line 级** bbox，表格还原只能靠
/// 「按 OCR 行的 midX 聚类推列」。这个假设在真机上已被证伪 —— OCR 会把
/// `项目每100克NRV%` 这种整行单元格合并成一个 line，于是 3 列塌成 1 列、
/// 锚点「营养成分表」也会丢，`TableGridV2Detector` 直接 `return nil` → 导出 Word 里
/// `w:tbl = 0`（见 docs/08 §2.3/§3、docs/09 §6.2/§6.3）。
///
/// 新 API **直接返回二维 Cell 数组**（`Table.rows`），根本不需要那个假设，
/// 所以调参救不回来的问题在这里是「不存在」而不是「被修好」。
///
/// 可用性：iOS 26+。更低版本、识别不出结构、或抛错时一律返回 `nil`，
/// 由 `OnDeviceDocumentParser` 回退到几何管线 —— 两条通路产出同样的
/// `StructuredDocumentPage`，下游一行都不用改。
actor VisionDocumentStructureRecognizer: DocumentStructureRecognizing {
    private let languages: [Locale.Language]

    /// 与 `VisionTextRecognizer` 保持同一组语言。
    /// ⚠️ 中文只支持 `.accurate` 级别的识别，且 CJK **没有 word 级**结果 ——
    /// 但这不影响表格：表格结构来自 `Table` 容器，不依赖 word 粒度。
    static let defaultLanguages: [Locale.Language] = [
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "zh-Hant"),
        Locale.Language(identifier: "en-US")
    ]

    init(languages: [Locale.Language] = VisionDocumentStructureRecognizer.defaultLanguages) {
        self.languages = languages
    }

    func recognize(imageURL: URL, pageID: UUID) async -> StructuredDocumentPage? {
        guard #available(iOS 26.0, *) else { return nil }
        do {
            // 直接吃 URL：省掉一次全分辨率解码（调用方为了裁图本来还要再解一次）。
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = languages
            request.textRecognitionOptions.useLanguageCorrection = true
            let observations = try await request.perform(on: imageURL)
            guard let container = observations.first?.document else { return nil }
            let page = Self.map(container)
            // 识别不出结构时返回 nil 而不是空结果 —— 契约要求调用方在这种情况回退几何管线。
            return page.hasContent ? page : nil
        } catch {
            ZhixiaLog.image.debug("RecognizeDocumentsRequest 失败，回退几何管线：\(String(describing: error))")
            return nil
        }
    }

    // MARK: - 映射

    @available(iOS 26.0, *)
    private static func map(_ container: DocumentObservation.Container) -> StructuredDocumentPage {
        StructuredDocumentPage(
            lines: lines(from: container),
            tables: tables(from: container),
            barcodes: barcodes(from: container),
            source: .documentRequest
        )
    }

    /// 取**行级**文本，而不是段落级。
    ///
    /// 下游 `OnDeviceReadingOrder` 是按行做行聚类 → 段落聚类 → 标题判定的；
    /// 喂段落级 bbox 会让它的粒度假设失效（一个段落被当成一行）。
    /// 这里刻意保持与几何通路同样的粒度，两条通路的行为差异才被压到最小。
    @available(iOS 26.0, *)
    private static func lines(from container: DocumentObservation.Container) -> [OCRLine] {
        var result: [OCRLine] = []
        for observation in container.text.lines {
            let text = observation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(
                OCRLine(
                    text: text,
                    boundingBox: observation.boundingBox.cgRect,
                    isTitle: observation.isTitle
                )
            )
        }
        guard result.isEmpty else { return result }
        // 兜底：整页被当成一个段落时 `text.lines` 可能为空。
        for paragraph in container.paragraphs {
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(
                OCRLine(text: text, boundingBox: paragraph.boundingRegion.boundingBox.cgRect)
            )
        }
        return result
    }

    @available(iOS 26.0, *)
    private static func tables(from container: DocumentObservation.Container) -> [DetectedTable] {
        container.tables.compactMap { table in
            let rows = rows(of: table)
            guard !rows.isEmpty else { return nil }
            return DetectedTable(
                table: ReconstructTable(rows: rows),
                bbox: table.boundingRegion.boundingBox.cgRect
            )
        }
    }

    @available(iOS 26.0, *)
    private static func barcodes(from container: DocumentObservation.Container) -> [DetectedBarcode] {
        container.barcodes.compactMap { observation in
            guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
            return DetectedBarcode(payload: payload, bbox: observation.boundingBox.cgRect)
        }
    }

    /// 一个表格单元格的最小信息。抽出来是为了让**合并单元格的拉平逻辑可以单测** ——
    /// `DocumentObservation.Container.Table` 没法在测试里构造。
    struct RawCell: Equatable, Sendable {
        var text: String
        var rowRange: ClosedRange<Int>
        var columnRange: ClosedRange<Int>
    }

    @available(iOS 26.0, *)
    private static func rows(of table: DocumentObservation.Container.Table) -> [[String]] {
        flatten(
            table.rows.map { row in
                row.map { cell in
                    RawCell(
                        text: cell.content.text.transcript
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        rowRange: cell.rowRange,
                        columnRange: cell.columnRange
                    )
                }
            }
        )
    }

    /// 把「按视觉行分组的单元格」拉平成 `[[String]]` 网格。
    ///
    /// 两件事必须处理：
    ///
    /// 1. **合并单元格**：`rowRange` / `columnRange` 是 `Range` —— 一个 cell 可以跨多行多列，
    ///    并且它在 `table.rows` 里会在跨越的**每一行重复出现**。策略是只在左上角
    ///    （首次出现）保留文本，其余位置留空。因为下游 `ReconstructTable` 与 DOCX 的 `w:tbl`
    ///    目前都不支持 `gridSpan` / `vMerge`（见 docs/09 §6.2）—— 与其把同一段文字重复 N 遍
    ///    （用户看到一堆重复内容），不如留空。
    /// 2. **补齐成矩形**：每行长度可能不同（被跨行 cell 占据的列没有独立 cell），
    ///    而 `ReconstructTable.columnCount` 与 DOCX 的 `tableXML` 都按列数对齐，
    ///    参差不齐会在导出时静默丢列。
    static func flatten(_ table: [[RawCell]]) -> [[String]] {
        var result: [[String]] = []
        var placed: Set<String> = []

        for row in table {
            var cellsByColumn: [Int: String] = [:]
            for cell in row {
                let key = "\(cell.rowRange.lowerBound):\(cell.columnRange.lowerBound)"
                guard placed.insert(key).inserted else { continue }
                cellsByColumn[cell.columnRange.lowerBound] = cell.text
            }
            guard !cellsByColumn.isEmpty else { continue }
            let lastColumn = cellsByColumn.keys.max() ?? 0
            result.append((0...lastColumn).map { cellsByColumn[$0] ?? "" })
        }

        let width = result.map(\.count).max() ?? 0
        return result.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}
