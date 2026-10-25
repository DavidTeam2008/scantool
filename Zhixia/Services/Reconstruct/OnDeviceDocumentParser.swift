import Foundation
import ImageIO
import UIKit

actor OnDeviceDocumentParser: DocumentParsing {
    private let recognizer: any TextRecognizing
    /// iOS 26 结构化识别。为 nil（或不支持 / 识别失败）时全程走几何管线。
    private let structureRecognizer: (any DocumentStructureRecognizing)?
    private let barcodeDetector: any BarcodeDetecting
    /// 裁图落盘目录（pageID → 目录）。spec/layout-restore plan D2 / FR-010：
    /// 默认保持旧 temporaryDirectory 路径（既有测试 / 未接线的调用方零改动），
    /// App 侧由 `AppEnvironment.makeReconstructParser(documentID:)` 注入
    /// PageFileStore 的文档级持久目录 —— 系统清理 temporaryDirectory 后
    /// 「过一阵再导出」不再缺图。
    private let cropDirectory: @Sendable (UUID) -> URL

    /// 兼容默认：与迁移前完全一致的 tmp 路径。
    static let legacyTemporaryCropDirectory: @Sendable (UUID) -> URL = { pageID in
        FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: "reconstruct", directoryHint: .isDirectory)
            .appending(path: pageID.uuidString, directoryHint: .isDirectory)
    }

    init(
        recognizer: any TextRecognizing,
        structureRecognizer: (any DocumentStructureRecognizing)? = nil,
        barcodeDetector: any BarcodeDetecting = VisionBarcodeDetector(),
        cropDirectory: @escaping @Sendable (UUID) -> URL = OnDeviceDocumentParser.legacyTemporaryCropDirectory
    ) {
        self.recognizer = recognizer
        self.structureRecognizer = structureRecognizer
        self.barcodeDetector = barcodeDetector
        self.cropDirectory = cropDirectory
    }

    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage {
        let image = loadCGImage(at: imageURL)
        let resolvedInputs = try await resolveInputs(imageURL: imageURL, pageID: pageID, image: image)
        let inputs = Self.normalizingListMarkers(resolvedInputs)
        let barcodes = inputs.barcodes
        let resolved = scene == .auto
            ? ReconstructSceneRouter.route(text: inputs.joinedText, barcodeCount: barcodes.count)
            : scene
        // 真机回归（2026-09-07）：先过一遍噪声过滤。
        // 状态栏 / App 导航栏 / 底部工具栏直接丢；URL、二维码内容降级成链接块，
        // 不再混进正文段落（练习册产物里 3 个 qrcode.5rs.me 链接的由来）。
        let (cleanedLines, demotedLines) = Self.filterNoise(inputs.lines)
        // 「表格行不进段落」的 bbox 基准。iOS 26 通路下是 Apple 给的表格区域，
        // 几何通路下是锚点检测的外接框 —— 两者判据一致（-0.02 容差），
        // 所以两条通路共用这一个过滤即可（原先 v2/v1 各有一份同公式的 contains）。
        let tableBoxes = inputs.tables.map(\.bbox)
        let occupied = barcodes.map(\.bbox) + tableBoxes
        let textBoxes = inputs.lines.map(\.boundingBox)
        // 乱码区域判定（spec/layout-restore plan D4 / FR-003）：先取「被文字覆盖墨块」
        // 空间证据（InkFigureDetector 第二输出），再对干净行做双门控判定 ——
        // 低置信 ∧ 低质量 ∧ 墨块重叠的行聚类成 artwork 区域：文字行从文字层剔除
        // （乱码不再混进正文），生成 .artwork 块保留原像素（预览/导出靠底座透出）。
        // 判定保守：识别正确的行（质量分为正）与高置信行永不剔除（FR-004）。
        let inkDetection = image.map { cgImage in
            InkFigureDetector.detect(.init(
                image: cgImage,
                textBoxes: textBoxes,
                occupied: occupied
            ))
        } ?? InkFigureDetector.Output(figures: [], textCoveredInkRegions: [])
        let garbled = GarbledRegionDetector.detect(
            lines: cleanedLines,
            inkRegions: inkDetection.textCoveredInkRegions
        )
        ZhixiaLog.reconstructArtwork(
            candidateLines: garbled.candidateLineCount,
            inkEvidence: inkDetection.textCoveredInkRegions.count,
            confirmedRegions: garbled.regions.count,
            lowestConfidence: garbled.lowestConfidence
        )
        // containment 不变量（wps-parity-layout FR-004 / plan D4-②）：被表格/条码
        // bbox 剔除的行必须被携带文本的结构覆盖 —— 表格行可在对应表格的单元格文本
        // 里检索到，条码行与对应条码 payload 互为包含（QR 印的 URL 常被整行识别）。
        // 未覆盖行不再静默丢弃（2026-09-21 "wrong bus!" 类丢字教训：结构吞了墨迹
        // 却没带走文字）：保留进文字层继续走段落聚类，违规计数进日志。
        let (leftover, removedByStructure, rescuedLines) = Self.splitCarriedLines(
            cleanedLines,
            garbled: garbled,
            tables: inputs.tables,
            barcodes: barcodes
        )
        if removedByStructure > 0 {
            ZhixiaLog.reconstructContainment(removed: removedByStructure, rescued: rescuedLines)
        }
        // 分栏（2026-09-12 真机反馈）：教材 / 练习册是左右两栏，而段落聚类与最终排序
        // 都假设单栏 → 左右栏会**逐行交错**。按栏分别排阅读序，栏与栏之间按栏序拼。
        // 单栏页面 `split` 返回一栏，行为与改动前完全一致。
        let columns = PageColumnSplitter.split(leftover)
        var blocks: [ReconstructBlock] = []
        for column in columns {
            blocks += OnDeviceReadingOrder.makeBlocks(from: column.lines)
        }
        for table in inputs.tables {
            blocks.append(
                ReconstructBlock(
                    kind: .table,
                    bbox: table.bbox,
                    text: "",
                    table: table.table
                )
            )
        }
        // 页级版面度量（spec/layout-engine plan D3 / T007）：`LayoutAnalyzer` 从此
        // **页级常跑**（原先只在 figure 分支里算，算完即丢，`page.layout` 字段
        // 一直悬空）。产物写入 `page.layout` —— 配图检测与后续区域布局引擎（US1）
        // 消费同一份度量；无文本行时 analyze 返回 nil，page.layout 保持 nil。
        let layout = LayoutAnalyzer.analyze(lines: inputs.lines)
        // figure↔barcode 交叉去重与去重日志的计数（spec/layout-restore plan D5 / FR-007）。
        // 图缺失时 figure 通道整体不跑，计数保持 0。
        var figuresBeforeCrossDedup = 0
        var figuresAfterCrossDedup = 0
        if let image {
            // M3：先跑 `FigureRegionsV2`（题下 anchor + v1 兜底），覆盖练习册题图。
            // iOS 26 `RecognizeDocumentsRequest` **不提供配图区域**，所以配图两条通路都得靠它。
            // 墨块通路复用上方 `inkDetection`（一次检测双输出，不重复栅格化）。
            // 条码不走 figure 通道（US3 / plan D5）：由 `.barcode` 块单份表示。
            var figureBoxes = Self.dedup(
                FigureRegionsV2.boxes(.init(
                    textBoxes: textBoxes,
                    layout: layout ?? LayoutAnalyzer.zeroLayout(),
                    occupied: occupied
                )) + inkDetection.figures

            )
            // artwork 判定优先（单份表示，plan D4）：同一区域同时是 figure 候选与
            // 乱码判定区域时只留 artwork —— 乱码行已剔除、原像素靠底座透出，
            // 再出一份 figure 裁图就成了同一区域的重复表示。
            let artworkRects = garbled.regions.map(\.rect)
            figureBoxes = figureBoxes.filter { box in
                !artworkRects.contains { artwork in
                    let intersection = artwork.intersection(box)
                    guard !intersection.isNull else { return false }
                    let smaller = min(artwork.width * artwork.height, box.width * box.height)
                    return intersection.width * intersection.height / max(smaller, 0.0001) > 0.5
                }
            }
            // figure↔barcode 交叉去重（plan D5 / FR-007 单份表示）：条码区域已有
            // 权威的 `.barcode` 表示（裁图 + payload），与条码框重叠的 figure 一律丢弃。
            figuresBeforeCrossDedup = figureBoxes.count
            figureBoxes = Self.removingBarcodeOverlaps(figureBoxes, barcodes: barcodes.map(\.bbox))
            figuresAfterCrossDedup = figureBoxes.count
            let directory = cropDirectory(pageID)
            // 同页重跑（切档不重跑 parse，但「重新扫描」会）：先清掉历史裁图，
            // 防止上一次多检出的 figure 文件变成孤儿占磁盘（目录页级私有，可安全清空）。
            try? FileManager.default.removeItem(at: directory)
            for (index, box) in figureBoxes.enumerated() {
                guard let url = NormalizedImageCrop.writePNG(
                    from: image,
                    visionBox: box,
                    to: directory.appending(path: "figure-\(index).png")
                ) else { continue }
                blocks.append(
                    ReconstructBlock(
                        kind: .figure,
                        bbox: box,
                        text: "",
                        figureRelativePath: url.path
                    )
                )
            }
            for (index, barcode) in barcodes.enumerated() {
                let url = directory.appending(path: "barcode-\(index).png")
                let written = NormalizedImageCrop.writePNG(
                    from: image,
                    visionBox: barcode.bbox,
                    to: url,
                    padding: 0.02
                )
                blocks.append(
                    ReconstructBlock(
                        kind: .barcode,
                        bbox: barcode.bbox,
                        text: barcode.payload,
                        figureRelativePath: (written ?? url).path,
                        barcodePayload: barcode.payload
                    )
                )
            }
        }
        // 被降级的 URL / 二维码内容（plan D5 / FR-007 单份表示）：
        // 与已检条码 bbox 相交（横向 0.03 / 纵向 0.05 邻近容差 —— 印在码上/下的
        // 说明行通常只隔一道小缝）的**并入该条码块的说明**，不另出块；
        // 远离任何条码的才单独成块（不混进正文段落，行为与改造前一致）。
        for line in demotedLines {
            let caption = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 只并入 Vision 检出的条码块（有裁图）；已降级块之间不互相合并。
            if let index = blocks.firstIndex(where: { block in
                block.kind == .barcode
                    && block.figureRelativePath != nil
                    && block.bbox.insetBy(dx: -0.03, dy: -0.05).intersects(line.boundingBox)
            }) {
                // payload 与 URL 文本一致时不重复追加（QR 的 payload 就是这个 URL）。
                if !caption.isEmpty, blocks[index].barcodePayload != caption {
                    blocks[index].text = blocks[index].text.isEmpty
                        ? caption
                        : blocks[index].text + "\n" + caption
                }
                continue
            }
            blocks.append(
                ReconstructBlock(
                    kind: .barcode,
                    bbox: line.boundingBox,
                    text: line.text,
                    barcodePayload: line.text,
                    semantic: .barcode
                )
            )
        }
        ZhixiaLog.reconstructDedup(
            beforeFigures: figuresBeforeCrossDedup,
            beforeBarcodes: barcodes.count + demotedLines.count,
            afterFigures: figuresAfterCrossDedup,
            afterBarcodes: blocks.filter { $0.kind == .barcode }.count
        )
        // 乱码区域 → .artwork 块（无文本、无独立裁图；预览/导出靠底座原像素透出，
        // 不进覆盖 mask —— LayoutMaskBuilder 按 kind 排除）。
        for region in garbled.regions {
            blocks.append(ReconstructBlock(kind: .artwork, bbox: region.rect, text: ""))
        }
        blocks = Self.assemble(blocks, columns: columns.map(\.xRange))
        guard !blocks.isEmpty else {
            throw ZhixiaError.reconstructFailed
        }
        // 区域布局引擎（spec/layout-engine plan D1 / FR-001/003/010/012）：装配产物
        // 过一遍确定性消解（跨栏拆分 → 碰撞让位 → 页界夹取），布局后块集**只**写入
        // restoredBlocks —— 结构化档恒读 blocks，拆分/位移对结构化档零扰动
        // （双档隔离铁律）。无冲突页引擎恒等映射 → 与 blocks 相等 → 写 nil
        // （等价旧产物，不为无变化页复制一份块集）。
        let pageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let resolution = RegionLayoutEngine.resolve(blocks: blocks, layout: layout, pageSize: pageSize)
        // layout 类目日志（plan D10，debug 级）：事件驱动——零活动页不刷屏
        if resolution.report.yieldCount > 0 {
            ZhixiaLog.layoutYield(count: resolution.report.yieldCount, totalShift: resolution.report.totalShift)
        }
        if resolution.report.splitCount > 0 {
            ZhixiaLog.layoutSplit(count: resolution.report.splitCount)
        }
        for shrink in resolution.report.figureShrinks {
            ZhixiaLog.layoutFigureShrink(figureID: shrink.figureID, clipHeight: shrink.clipHeight)
        }
        return ReconstructPage(
            pageID: pageID,
            size: pageSize,
            scene: resolved,
            usedCloud: false,
            blocks: blocks,
            layout: layout,
            restoredBlocks: resolution.blocks == blocks ? nil : resolution.blocks
        )
    }

    /// 两路配图检测的结果去重（几何连通域 + 像素墨块，可能给出同一张图）。
    private static func dedup(_ boxes: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for box in boxes {
            let overlaps = result.contains { existing in
                let intersection = existing.intersection(box)
                guard !intersection.isNull else { return false }
                let union = existing.union(box)
                let iou = (intersection.width * intersection.height) / max(union.width * union.height, 0.0001)
                // 高度重叠或一个基本包含另一个，都算同一张图
                return iou > 0.5
                    || existing.insetBy(dx: 0.01, dy: 0.01).contains(box)
                    || box.insetBy(dx: 0.01, dy: 0.01).contains(existing)
            }
            if !overlaps { result.append(box) }
        }
        return result
    }

    /// figure↔barcode 交叉去重（spec/layout-restore plan D5 / FR-007 单份表示）。
    ///
    /// 条码在产物里已有权威表示（`.barcode` 块：裁图 + payload）；figure 框与任一
    /// 条码框 IoU > 0.5、或一方基本包含另一方时丢弃 figure —— 与 `dedup` 同一套
    /// 重叠判据，只是跨到「figure × 条码」这一维。
    ///
    /// `FigureRegionsV2` 的条码通道移除后，ink / 几何通道都把条码框当墙，
    /// 正常不会撞上 —— 这里是阈值边缘漏网的兜底。
    static func removingBarcodeOverlaps(_ boxes: [CGRect], barcodes: [CGRect]) -> [CGRect] {
        guard !barcodes.isEmpty else { return boxes }
        return boxes.filter { box in
            !barcodes.contains { barcode in
                let intersection = barcode.intersection(box)
                guard !intersection.isNull else { return false }
                let union = barcode.union(box)
                let iou = (intersection.width * intersection.height) / max(union.width * union.height, 0.0001)
                return iou > 0.5
                    || barcode.insetBy(dx: 0.01, dy: 0.01).contains(box)
                    || box.insetBy(dx: 0.01, dy: 0.01).contains(barcode)
            }
        }
    }

    // MARK: - containment 不变量（wps-parity-layout FR-004 / plan D4-②）

    /// 「表格/条码行不进段落」过滤 + containment 不变量执行。
    ///
    /// 返回 (leftover, removed, rescued)：
    /// - leftover：进段落聚类的文字层（乱码行除外，见 `GarbledRegionDetector`）；
    /// - removed：被表格/条码 bbox 剔除、且文字确被对应结构携带的行数；
    /// - rescued：落在结构 bbox 里但结构**没有**携带其文字、依 FR-004 保留回
    ///   文字层的行数（= 被拦截的静默丢字数，进 `containment` 日志）。
    private static func splitCarriedLines(
        _ lines: [OCRLine],
        garbled: GarbledRegionJudgement,
        tables: [DetectedTable],
        barcodes: [DetectedBarcode]
    ) -> (leftover: [OCRLine], removed: Int, rescued: Int) {
        var leftover: [OCRLine] = []
        var removed = 0
        var rescued = 0
        for (index, line) in lines.enumerated() {
            // 乱码行不进文字层（spec/layout-restore FR-003：乱码文本不出现在
            // 还原结果与导出文档中，原像素由 .artwork 块透出）—— 与 containment 无关。
            if garbled.isGarbled(index) { continue }
            let point = CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY)
            let carryingTables = tables.filter {
                $0.bbox.insetBy(dx: -0.02, dy: -0.02).contains(point)
            }
            let carryingBarcodes = barcodes.filter {
                $0.bbox.insetBy(dx: -0.012, dy: -0.012).contains(point)
            }
            if carryingTables.isEmpty && carryingBarcodes.isEmpty {
                leftover.append(line)
                continue
            }
            if Self.isCarried(line.text, tables: carryingTables, barcodes: carryingBarcodes) {
                removed += 1
            } else {
                rescued += 1
                leftover.append(line)
            }
        }
        return (leftover, removed, rescued)
    }

    /// 行文字是否被剔除它的结构携带。
    ///
    /// 宽松方向刻意选「多判覆盖」：**去全部空白**后做包含比较 —— v2 建格用
    /// 「trim + 空格拼接」、Apple 单元格文本自带首尾空白，单元格边界处的空白
    /// 不构成文字差异（「能量1429千焦17%」与单元格 ["能量","1429千焦","17%"]
    /// 必须判覆盖）。反过来，文字真的不在结构里时（条码说明不是 payload、
    /// 表格行被识别端丢弃），宁可保留回文字层也不赌「结构丢了它」。
    private static func isCarried(
        _ text: String,
        tables: [DetectedTable],
        barcodes: [DetectedBarcode]
    ) -> Bool {
        let normalized = Self.squeezed(text)
        // 空白行没有可丢的文字 —— 结构吞了也不构成丢字。
        if normalized.isEmpty { return true }
        for table in tables {
            let cells = table.table.rows
                .flatMap { $0 }
                .map(Self.squeezed)
                .joined()
            if cells.contains(normalized) { return true }
        }
        for barcode in barcodes {
            let payload = Self.squeezed(barcode.payload)
            // 空 payload（未解码的码）判不了覆盖 —— 交给下一个结构或救回。
            guard !payload.isEmpty else { continue }
            if payload.contains(normalized) || normalized.contains(payload) {
                return true
            }
        }
        return false
    }

    /// 去全部空白（含全角空格/换行），供 containment 覆盖判定做宽松包含比较。
    private static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    // MARK: - 装配（按栏排阅读序）

    /// 把块按栏装配成阅读序。
    ///
    /// - **单栏**：退化为原来的「`(maxY 降序, minX 升序)`」全局排序，行为与改动前一致。
    /// - **多栏**：先按栏分组、栏内排序，再按栏序（左→右）拼。这才是真正的阅读序 ——
    ///   原先的全局排序会把左右栏同一水平带的块交替输出。
    private static func assemble(
        _ blocks: [ReconstructBlock],
        columns: [ClosedRange<CGFloat>]
    ) -> [ReconstructBlock] {
        guard columns.count > 1 else { return blocks.sorted(by: readingOrder) }
        var buckets = [[ReconstructBlock]](repeating: [], count: columns.count)
        for block in blocks {
            buckets[columnIndex(for: block.bbox.midX, columns: columns)].append(block)
        }
        return buckets.flatMap { $0.sorted(by: readingOrder) }
    }

    /// 按块的横向中心归栏。跨栏块（整页宽的标题、跨栏配图）落到距离最近的那一栏。
    private static func columnIndex(for x: CGFloat, columns: [ClosedRange<CGFloat>]) -> Int {
        if let index = columns.firstIndex(where: { $0.contains(x) }) { return index }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, range) in columns.enumerated() {
            let distance = min(abs(x - range.lowerBound), abs(x - range.upperBound))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// 栏内的阅读序：按视觉上边（Vision 的 `maxY` 大 = 靠上）降序，顶上齐平时按 x 升序。
    ///
    /// ⚠️ 这里**刻意不加「同一视觉行」容差**（原先是 `abs(ΔmaxY) > 0.03` 才算不同行）。
    /// 真机反馈（2026-09-12）：教材行距只有 1%~2%，远小于 0.03，于是所有块都被当成
    /// 「同一行」而改成按 x 排序 —— 左栏的短行（如 `the maths problems?`）被排到了
    /// 它下面那一大段之后，正文顺序整个错掉。
    ///
    /// 那个容差原本是为了「同一行的碎片按 x 排」，但同一行的碎片早已被
    /// `OnDeviceReadingOrder.clusterRows` 合并成同一个块了；而分栏之后，栏内文本
    /// 是纵向流动的，本来就不该有「同一行」的概念。所以严格按 y 排才是真正的阅读序。
    private static func readingOrder(_ lhs: ReconstructBlock, _ rhs: ReconstructBlock) -> Bool {
        if lhs.bbox.maxY != rhs.bbox.maxY {
            return lhs.bbox.maxY > rhs.bbox.maxY
        }
        return lhs.bbox.minX < rhs.bbox.minX
    }

    // MARK: - 取输入（两条通路）

    /// 优先 iOS 26 结构化识别，失败则回退几何管线。
    ///
    /// 之所以值得单开一个通路口：**结构化通路拿得到表格的行列结构**，
    /// 而几何通路的「按 OCR 行 midX 聚类推列」在真机上已被证伪
    /// （Vision 只给 line 级 bbox，真机把整行单元格合并成一个 line）→ `w:tbl = 0`。
    private func resolveInputs(
        imageURL: URL,
        pageID: UUID,
        image: CGImage?
    ) async throws -> StructuredDocumentPage {
        guard let structureRecognizer else {
            // 没有可用的结构化识别器（低版本注入 nil / 测试几何通路）→ 唯一通路是几何。
            ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .apiUnavailable)
            return try await geometricInputs(imageURL: imageURL, pageID: pageID, image: image)
        }
        if let structured = await structureRecognizer.recognize(imageURL: imageURL, pageID: pageID) {
            // 真实识别器在「识别失败」的捕获点已经发过一条带具体原因的线（每页一条，不在这里重复）；
            // 走到这里说明拿到了非 nil 结果。真实识别器对空结果返回 nil，非 nil 却无内容
            // 只可能出现在替身违反契约时 —— 补一条 invalidResult 兜底，保证决策线不缺。
            guard structured.hasContent else {
                ZhixiaLog.reconstructPath(pageID: pageID, path: .geometric, reason: .invalidResult)
                return try await geometricInputs(imageURL: imageURL, pageID: pageID, image: image)
            }
            ZhixiaLog.reconstructPath(pageID: pageID, path: .structured, reason: .structuredSuccess)
            return mergingBarcodes(structured, image: image)
        }
        return try await geometricInputs(imageURL: imageURL, pageID: pageID, image: image)
    }

    /// 把结构化通路的条码与 `VNDetectBarcodesRequest` 的结果**取并集**。
    ///
    /// 实测（2026-09-12，样张 `nutrition-mango.jpg`）：`RecognizeDocumentsRequest` 的
    /// `container.barcodes` 返回 **0 个**，而几何检测器在同一张图上能检出条码。
    /// 条码既参与配图占位、又直接进导出产物（裁图 + payload），漏一个就是用户可见的缺失。
    /// 所以两个来源都要，而不是用新的替换旧的。
    private func mergingBarcodes(_ page: StructuredDocumentPage, image: CGImage?) -> StructuredDocumentPage {
        guard let image else { return page }
        let detected = barcodeDetector.detect(in: image)
        guard !detected.isEmpty else { return page }
        var merged = page
        for barcode in detected {
            let alreadyKnown = merged.barcodes.contains { known in
                known.payload == barcode.payload || known.bbox.intersects(barcode.bbox)
            }
            if !alreadyKnown {
                merged.barcodes.append(barcode)
            }
        }
        return merged
    }

    /// 几何回退：Vision OCR + `TableGridV2Detector`（锚点驱动）。
    private func geometricInputs(imageURL: URL, pageID: UUID, image: CGImage?) async throws -> StructuredDocumentPage {
        let ocr = try await recognizer.recognize(imageURL: imageURL, pageID: pageID)
        guard ocr.hasText else {
            throw ZhixiaError.ocrFailed
        }
        let barcodes = image.map { barcodeDetector.detect(in: $0) } ?? []
        // 表格只信两种来源（FR-003）：结构化识别通路（resolveInputs 优先）或
        // 锚点驱动的 `TableGridV2Detector`。v1 `OnDeviceTableCluster` 的
        // 「按 midX 聚类推列」启发式已退役（wps-parity-layout FR-003 / D2）：
        // 在真机 OCR 上被证伪 —— Vision 只给 line 级 bbox，整行单元格会被
        // 合并成一个 line，聚类推不出列 → 产出假表/漏表。类与直连单测休眠保留。
        var tables: [DetectedTable] = []
        if let v2 = TableGridV2Detector.detect(from: ocr.lines, profile: .nutrition) {
            tables = [DetectedTable(table: v2.table, bbox: v2.bbox)]
        }
        return StructuredDocumentPage(
            lines: ocr.lines,
            tables: tables,
            barcodes: barcodes,
            source: .geometric
        )
    }

    /// OCR 常把中文项目符号「•」读成句号「。」。行首的「。」后面直接跟汉字时，
    /// 它几乎不可能是句末标点——按项目符号还原，避免在渲染层出现一个孤零零的
    /// 全角句号 + 巨大缩进（真机/模拟器样张的「仔细读说明」「注意考试…」两行）。
    private static func normalizingListMarkers(_ page: StructuredDocumentPage) -> StructuredDocumentPage {
        var normalized = page
        normalized.lines = page.lines.map { line in
            var copy = line
            copy.text = normalizeListMarker(line.text)
            return copy
        }
        return normalized
    }

    private static func normalizeListMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("。") else { return text }
        let rest = trimmed.dropFirst()
        guard let first = rest.unicodeScalars.first,
              (0x4E00...0x9FFF).contains(first.value)
        else { return text }
        return "• " + rest
    }

    /// 把 OCR 行分成「干净的正文行」和「降级为链接/条码的行」。
    /// 噪声行（状态栏、UI 工具栏）在此直接丢弃。
    private static func filterNoise(_ lines: [OCRLine]) -> (clean: [OCRLine], demoted: [OCRLine]) {
        let heights = lines.map(\.boundingBox.height).sorted()
        let medianH = heights.isEmpty ? 0.02 : heights[heights.count / 2]
        var clean: [OCRLine] = []
        var demoted: [OCRLine] = []
        for line in lines {
            let context = OCRNoiseFilter.Context(
                medianLineHeight: medianH,
                isNearTopEdge: line.boundingBox.maxY > 0.965,
                isNearBottomEdge: line.boundingBox.minY < 0.035
            )
            switch OCRNoiseFilter.verdict(for: line.text, context: context) {
            case .keep: clean.append(line)
            case .drop: continue
            case .demoteToBarcode: demoted.append(line)
            }
        }
        return (clean, demoted)
    }

    private func loadCGImage(at url: URL) -> CGImage? {
        if let uiImage = UIImage(contentsOfFile: url.path) {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: uiImage.size, format: format)
            let flattened = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
            }
            return flattened.cgImage ?? uiImage.cgImage
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
