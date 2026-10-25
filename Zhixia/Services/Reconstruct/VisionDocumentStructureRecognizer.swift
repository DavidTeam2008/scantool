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

    /// 结构识别语言：简体中文 + 英文。
    /// ⚠️ 中文只支持 `.accurate` 级别的识别，且 CJK **没有 word 级**结果 ——
    /// 但这不影响表格：表格结构来自 `Table` 容器，不依赖 word 粒度。
    ///
    /// **不要加 `zh-Hant`**：2026-10-23 真实页复测，`zh-Hans + zh-Hant + en-US`
    /// 会把本页的 2 列表格识别成 1 列（宿主机 Vision 从 2 张表降为 1 张，
    /// 模拟器直接 0 张）；去掉繁中后简中/英文页面表格恢复。繁体页面后续若要
    /// 支持，应在「简体+英文」无表格时再做一次繁中回退，而不是默认三语一起跑。
    static let defaultLanguages: [Locale.Language] = [
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "en-US")
    ]

    init(languages: [Locale.Language] = VisionDocumentStructureRecognizer.defaultLanguages) {
        self.languages = languages
    }

    func recognize(imageURL: URL, pageID: UUID) async -> StructuredDocumentPage? {
        guard #available(iOS 26.0, *) else {
            // 通路决策可观测（spec/wps-parity-layout plan D9 / FR-002、SC-006）：
            // 返回 nil 即调用方回退几何管线，所以这里的有效通路就是 geometric。
            ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .lowVersionFallback)
            return nil
        }
        do {
            // 直接吃 URL：省掉一次全分辨率解码（调用方为了裁图本来还要再解一次）。
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = languages
            request.textRecognitionOptions.useLanguageCorrection = true
            let observations = try await request.perform(on: imageURL)
            guard let container = observations.first?.document else {
                ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .invalidResult)
                return nil
            }
            let page = Self.map(container)
            // 识别不出结构时返回 nil 而不是空结果 —— 契约要求调用方在这种情况回退几何管线。
            guard page.hasContent else {
                ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .invalidResult)
                return nil
            }
            return page
        } catch {
            ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .requestFailed)
            ZhixiaLog.image.debug("RecognizeDocumentsRequest 失败，回退几何管线：\(String(describing: error))")
            return nil
        }
    }

    // MARK: - 映射

    @available(iOS 26.0, *)
    private static func map(_ container: DocumentObservation.Container) -> StructuredDocumentPage {
        let lines = lines(from: container)
        return StructuredDocumentPage(
            lines: lines,
            tables: tables(from: container, lines: lines),
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
    private static func tables(
        from container: DocumentObservation.Container,
        lines: [OCRLine]
    ) -> [DetectedTable] {
        container.tables.compactMap { table in
            let rawRows = rawRows(of: table)
            let bbox = table.boundingRegion.boundingBox.cgRect
            if let repaired = TableStructureRepair.repair(
                rawRows: rawRows,
                tableBBox: bbox,
                lines: lines
            ), isUsableTable(repaired.rows) {
                return DetectedTable(
                    table: ReconstructTable(
                        rows: repaired.rows,
                        columnRatios: repaired.columnRatios
                    ),
                    bbox: bbox
                )
            }
            let rows = flatten(rawRows)
            guard !rows.isEmpty else { return nil }
            // 单列/一半为空列的表在练习册页上是典型的“段落框误判”：它会把整段
            // 故事吞成表格，同时让 figure 通道失效（Golden iOS 27 回归）。不收。
            guard isUsableTable(rows) else { return nil }
            return DetectedTable(
                table: ReconstructTable(rows: rows, columnRatios: columnRatios(rawRows)),
                bbox: bbox
            )
        }
    }

    /// 至少 2 个非空列、2 行才算可编辑表格；否则视为段落框误判。
    static func isUsableTable(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return false }
        let width = rows.map(\.count).max() ?? 0
        guard width >= 2 else { return false }
        let nonEmptyColumns = (0..<width).filter { column in
            rows.contains { row in
                column < row.count
                    && !row[column].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard nonEmptyColumns.count >= 2 else { return false }
        // 长“表”里超过一半行只有一个非空单元格 → 多半是段落被按行切成了假表格
        // （Golden iOS 27 的 24 行故事被切出 2 列，空列占一半）。
        let nonEmptyCells = rows.reduce(0) { partial, row in
            partial + row.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        }
        let occupancy = Double(nonEmptyCells) / Double(rows.count)
        if rows.count > 8, occupancy < 1.5 { return false }
        return true
    }

    @available(iOS 26.0, *)
    private static func barcodes(from container: DocumentObservation.Container) -> [DetectedBarcode] {
        container.barcodes.compactMap { observation in
            guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
            return DetectedBarcode(payload: payload, bbox: observation.boundingBox.cgRect)
        }
    }

    /// 一个表格单元格的最小信息。抽出来是为了让**合并单元格的拉平逻辑**与
    /// **列宽提取逻辑可以单测** —— `DocumentObservation.Container.Table` 没法在测试里构造。
    struct RawCell: Equatable, Sendable {
        var text: String
        var rowRange: ClosedRange<Int>
        var columnRange: ClosedRange<Int>
        /// 单元格内容区域（Vision 归一化坐标，原点左下）。只有结构化通路（真机 API）
        /// 填得上；合成测试夹具不填 → `columnRatios` 返回 nil，下游走均分兜底。
        var frame: CGRect? = nil
    }

    @available(iOS 26.0, *)
    private static func rawRows(of table: DocumentObservation.Container.Table) -> [[RawCell]] {
        table.rows.map { row in
            row.map { cell in
                RawCell(
                    text: cell.content.text.transcript
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    rowRange: cell.rowRange,
                    columnRange: cell.columnRange,
                    frame: cell.content.boundingRegion.boundingBox.cgRect
                )
            }
        }
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

    /// 从单元格内容区域提取**实测列宽比例**（和为 1；T006，plan D8）。
    ///
    /// 背景：老的拉平逻辑只保留文本，把列边界信息丢了 —— 下游 `tblGrid` 只能均分。
    /// 真机上「项目 | 每100克 | NRV%」三列宽度差好几倍，均分会让窄列文字被压到
    /// 字号下限、宽列留白（docs/09 §6.2）。
    ///
    /// 算法：
    /// 1. 每个网格列取**单列单元格**（`columnRange.count == 1`）内容区域的并集
    ///    —— 跨列单元格横跨多个列边界，对「列在哪」不提供信息，必须排除；
    /// 2. 相邻列边界取两侧内容并集的中点（间隙对半分、重叠对半让）；
    /// 3. 列宽 = 相邻边界之差，归一化到和为 1。
    ///
    /// 返回 nil 的情形（下游一律均分兜底，不做猜测）：合成输入没有 frame、
    /// 某列只有跨列单元格、边界推出来非正、空表格或单列表格。
    static func columnRatios(_ table: [[RawCell]]) -> [Double]? {
        let cells = table.flatMap { $0 }
        guard !cells.isEmpty else { return nil }

        // 网格总列数：所有 cell 的 columnRange 上界决定。
        let gridWidth = cells.map { $0.columnRange.upperBound + 1 }.max() ?? 0
        guard gridWidth >= 2 else { return nil }

        // 每列内容并集的左右沿。nil = 该列还没有任何可测的单列单元格。
        var lows: [CGFloat?] = .init(repeating: nil, count: gridWidth)
        var highs: [CGFloat?] = .init(repeating: nil, count: gridWidth)
        for cell in cells where cell.columnRange.count == 1 {
            guard let frame = cell.frame, frame.width > 0 else { continue }
            let column = cell.columnRange.lowerBound
            lows[column] = min(lows[column] ?? frame.minX, frame.minX)
            highs[column] = max(highs[column] ?? frame.maxX, frame.maxX)
        }
        guard zip(lows, highs).allSatisfy({ $0 != nil && $1 != nil }) else { return nil }

        // 边界：最左/最右沿来自首末列内容，内部边界取相邻列内容的中点。
        var bounds: [CGFloat] = [lows[0]!]
        for column in 1..<gridWidth {
            bounds.append((highs[column - 1]! + lows[column]!) / 2)
        }
        bounds.append(highs[gridWidth - 1]!)

        let widths = zip(bounds, bounds.dropFirst()).map { $1 - $0 }
        guard widths.allSatisfy({ $0 > 0 }) else { return nil }
        let total = widths.reduce(0, +)
        guard total > 0 else { return nil }
        return widths.map { Double($0 / total) }
    }
}
