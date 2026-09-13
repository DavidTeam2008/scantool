import Foundation
import ImageIO
import UIKit

actor OnDeviceDocumentParser: DocumentParsing {
    private let recognizer: any TextRecognizing
    /// iOS 26 结构化识别。为 nil（或不支持 / 识别失败）时全程走几何管线。
    private let structureRecognizer: (any DocumentStructureRecognizing)?
    private let barcodeDetector: any BarcodeDetecting

    init(
        recognizer: any TextRecognizing,
        structureRecognizer: (any DocumentStructureRecognizing)? = nil,
        barcodeDetector: any BarcodeDetecting = VisionBarcodeDetector()
    ) {
        self.recognizer = recognizer
        self.structureRecognizer = structureRecognizer
        self.barcodeDetector = barcodeDetector
    }

    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage {
        let image = loadCGImage(at: imageURL)
        let inputs = try await resolveInputs(imageURL: imageURL, pageID: pageID, image: image)
        let barcodes = inputs.barcodes
        let resolved = scene == .auto
            ? ReconstructSceneRouter.route(text: inputs.joinedText, barcodeCount: barcodes.count)
            : scene
        // 真机回归（2026-09-07）：先过一遍噪声过滤。
        // 状态栏 / App 导航栏 / 底部工具栏直接丢；URL、二维码内容降级成链接块，
        // 不再混进正文段落（练习册产物里 3 个 qrcode.5rs.me 链接的由来）。
        let (cleanedLines, demotedLines) = Self.filterNoise(inputs.lines)
        // 「表格行不进段落」。iOS 26 通路下这里的 bbox 是 Apple 给的表格区域，
        // 几何通路下是聚类出的表格外接框 —— 两者判据一致（-0.02 容差），
        // 所以两条通路共用这一个过滤即可（原先 v2/v1 各有一份同公式的 contains）。
        let tableBoxes = inputs.tables.map(\.bbox)
        let leftover = cleanedLines.filter { line in
            let point = CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY)
            if tableBoxes.contains(where: { $0.insetBy(dx: -0.02, dy: -0.02).contains(point) }) {
                return false
            }
            return !barcodes.contains { $0.bbox.insetBy(dx: -0.012, dy: -0.012).contains(point) }
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
        if let image {
            let occupied = barcodes.map(\.bbox) + tableBoxes
            // M3：先跑 `FigureRegionsV2`（题下 anchor + barcode anchor + v1 兜底），覆盖
            // 营养表条码 / 练习册 A/B/C 题图两个长期 knownIssue。
            // iOS 26 `RecognizeDocumentsRequest` **不提供配图区域**，所以配图两条通路都得靠它。
            let layout = LayoutAnalyzer.analyze(lines: inputs.lines)
            let textBoxes = inputs.lines.map(\.boundingBox)
            // 几何通路：把文字盒当墙找「空白连通域」。它有个结构性盲区 ——
            // **区分不了「照片」和「白纸」**：实测一页教材的空白连成了面积 0.905 的一整块，
            // 插图的空白和页边距、行间距全部连通，于是那张照片从来没作为独立区域出现过。
            // 所以再叠一路**读像素**的墨块检测（见 `InkFigureDetector`）。
            let figureBoxes = Self.dedup(
                FigureRegionsV2.boxes(.init(
                    textBoxes: textBoxes,
                    layout: layout ?? LayoutAnalyzer.zeroLayout(),
                    occupied: occupied
                )) + InkFigureDetector.boxes(.init(
                    image: image,
                    textBoxes: textBoxes,
                    occupied: occupied
                ))
            )
            let directory = cropDirectory(pageID: pageID)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, box) in figureBoxes.enumerated() {
                guard let data = NormalizedImageCrop.png(from: image, visionBox: box) else { continue }
                let url = directory.appending(path: "figure-\(index).png")
                try? data.write(to: url, options: .atomic)
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
                if let data = NormalizedImageCrop.png(from: image, visionBox: barcode.bbox, padding: 0.02) {
                    try? data.write(to: url, options: .atomic)
                }
                blocks.append(
                    ReconstructBlock(
                        kind: .barcode,
                        bbox: barcode.bbox,
                        text: barcode.payload,
                        figureRelativePath: FileManager.default.fileExists(atPath: url.path) ? url.path : nil,
                        barcodePayload: barcode.payload
                    )
                )
            }
        }
        // 被降级的 URL / 二维码内容：单独成块，不混进正文段落。
        for line in demotedLines {
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
        blocks = Self.assemble(blocks, columns: columns.map(\.xRange))
        guard !blocks.isEmpty else {
            throw ZhixiaError.reconstructFailed
        }
        return ReconstructPage(
            pageID: pageID,
            size: image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            scene: resolved,
            usedCloud: false,
            blocks: blocks
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
        if let structureRecognizer,
           let structured = await structureRecognizer.recognize(imageURL: imageURL, pageID: pageID),
           structured.hasContent {
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

    /// 几何回退：Vision OCR + `TableGridV2Detector`（锚点驱动）/ `OnDeviceTableCluster`（v1 兜底）。
    private func geometricInputs(imageURL: URL, pageID: UUID, image: CGImage?) async throws -> StructuredDocumentPage {
        let ocr = try await recognizer.recognize(imageURL: imageURL, pageID: pageID)
        guard ocr.hasText else {
            throw ZhixiaError.ocrFailed
        }
        let barcodes = image.map { barcodeDetector.detect(in: $0) } ?? []
        // M2：先用 `TableGridV2Detector`（锚点驱动）尝试；
        //    失败再回退 v1 `OnDeviceTableCluster`（ad-hoc 表，无表标题）。
        var tables: [DetectedTable] = []
        if let v2 = TableGridV2Detector.detect(from: ocr.lines, profile: .nutrition) {
            tables = [DetectedTable(table: v2.table, bbox: v2.bbox)]
        } else if let v1 = OnDeviceTableCluster.detect(from: ocr.lines) {
            tables = [v1]
        }
        return StructuredDocumentPage(
            lines: ocr.lines,
            tables: tables,
            barcodes: barcodes,
            source: .geometric
        )
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

    private func cropDirectory(pageID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: "reconstruct", directoryHint: .isDirectory)
            .appending(path: pageID.uuidString, directoryHint: .isDirectory)
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
