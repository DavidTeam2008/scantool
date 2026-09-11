import Foundation
import ImageIO
import UIKit

actor OnDeviceDocumentParser: DocumentParsing {
    private let recognizer: any TextRecognizing

    init(recognizer: any TextRecognizing) {
        self.recognizer = recognizer
    }

    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage {
        let ocr = try await recognizer.recognize(imageURL: imageURL, pageID: pageID)
        guard ocr.hasText else {
            throw ZhixiaError.ocrFailed
        }
        let image = loadCGImage(at: imageURL)
        let barcodes = image.map { PageBarcodeDetector.detect(in: $0) } ?? []
        let resolved = scene == .auto
            ? ReconstructSceneRouter.route(text: ocr.joinedText, barcodeCount: barcodes.count)
            : scene
        // M2：先用 `TableGridV2Detector`（锚点驱动）尝试；
        //    失败再回退 v1 `OnDeviceTableCluster`（ad-hoc 表，无表标题）。
        //    命中后包装为统一的 `DetectedTable` 给后续 OCR 行过滤用。
        let v2 = TableGridV2Detector.detect(from: ocr.lines, profile: .nutrition)
        let v1 = v2 == nil ? OnDeviceTableCluster.detect(from: ocr.lines) : nil
        let table: DetectedTable? = v2.map {
            DetectedTable(table: $0.table, bbox: $0.bbox)
        } ?? v1
        // 真机回归（2026-09-07）：先过一遍噪声过滤。
        // 状态栏 / App 导航栏 / 底部工具栏直接丢；URL、二维码内容降级成链接块，
        // 不再混进正文段落（练习册产物里 3 个 qrcode.5rs.me 链接的由来）。
        let (cleanedLines, demotedLines) = Self.filterNoise(ocr.lines)
        let leftover = cleanedLines.filter { line in
            if let v2Grid = v2, TableGridV2Detector.contains(v2Grid, line: line) {
                return false
            }
            if let v1Table = v1, OnDeviceTableCluster.contains(v1Table, line: line) {
                return false
            }
            let point = CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY)
            return !barcodes.contains { $0.bbox.insetBy(dx: -0.012, dy: -0.012).contains(point) }
        }
        var blocks = OnDeviceReadingOrder.makeBlocks(from: leftover)
        if let table {
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
            let occupied = barcodes.map(\.bbox) + (table.map { [$0.bbox] } ?? [])
            // M3：先跑 `FigureRegionsV2`（题下 anchor + barcode anchor + v1 兜底），覆盖
            // 营养表条码 / 练习册 A/B/C 题图两个长期 knownIssue。
            let layout = LayoutAnalyzer.analyze(lines: ocr.lines)
            let figureBoxes = FigureRegionsV2.boxes(.init(
                textBoxes: ocr.lines.map(\.boundingBox),
                layout: layout ?? LayoutAnalyzer.zeroLayout(),
                occupied: occupied
            ))
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
        blocks.sort { lhs, rhs in
            if abs(lhs.bbox.maxY - rhs.bbox.maxY) > 0.03 {
                return lhs.bbox.maxY > rhs.bbox.maxY
            }
            return lhs.bbox.minX < rhs.bbox.minX
        }
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
