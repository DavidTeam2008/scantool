import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// US3（spec/layout-restore · FR-007 / plan D5）：条码去重 —— 同一条码在还原产物里
/// 只能有一份表示。
///
/// ## 三通道重复的来源（改造前）
/// 1. `FigureRegionsV2.barcodeFigures`：把 occupied 里像条码的框 / layout 条码锚点
///    外扩后当 **figure** 输出（裁图）；
/// 2. Vision 条码检测：`DetectedBarcode` → `.barcode` 块（裁图 + payload）；
/// 3. `OCRNoiseFilter` 把 URL 文本降级成 `.barcode` 块（无裁图）。
/// 营养表条码 / 练习册二维码在产物里最多同时出现三份。
///
/// ## 改造后（plan D5）
/// - 通道 1 整体移除：条码不再外扩成 figure；
/// - 通道 3 与已检条码 bbox 相交（含邻近容差）时**并入**该 `.barcode` 块的说明；
/// - parser 级 figure↔barcode 交叉去重兜底（IoU > 0.5 或包含）。
///
/// ⚠️ 条码断言全部用注入替身：`VNDetectBarcodesRequest` 在 iOS 模拟器上恒返回 0
/// （见 `BarcodeDetecting` 的说明），真检测器写测试只会得到假绿。
struct BarcodeDedupTests {

    // MARK: - 通道移除（FigureRegionsV2.barcodeFigures）

    @Test("occupied 里的条码框不再外扩成 figure")
    func occupiedBarcodeBoxIsNotEmittedAsFigure() {
        // aspect 3.75 / 高 0.08：恰好通过旧的 looksLikeBarcodeBox 与 isPlausible，
        // 改造前一定会被输出。
        let flatBarcodeBox = CGRect(x: 0.35, y: 0.12, width: 0.3, height: 0.08)
        let boxes = FigureRegionsV2.boxes(makeInput(occupied: [flatBarcodeBox]))
        #expect(
            boxes.contains { $0.insetBy(dx: -0.02, dy: -0.02).intersects(flatBarcodeBox) } == false,
            "条码 bbox 被当成 figure 输出了：\(boxes)"
        )
    }

    @Test("layout 条码锚点不再膨胀成 figure")
    func barcodeAnchorIsNotEmittedAsFigure() {
        let anchorFrame = CGRect(x: 0.3, y: 0.5, width: 0.3, height: 0.02)
        let boxes = FigureRegionsV2.boxes(makeInput(anchors: [
            LayoutAnchor(kind: .barcode, frame: anchorFrame, text: "6 936832 529010", confidence: 0.7)
        ]))
        #expect(
            boxes.contains { $0.insetBy(dx: -0.05, dy: -0.05).intersects(anchorFrame) } == false,
            "条码锚点被膨胀成 figure 输出了：\(boxes)"
        )
    }

    // MARK: - parser 级单份表示（注入替身）

    @Test("同一条码区域不出重叠 figure（数字行锚点改造前会外扩成 figure）")
    func qrAreaYieldsNoOverlappingFigureBlock() async throws {
        let qrBox = CGRect(x: 0.3, y: 0.45, width: 0.3, height: 0.3)
        let image = try #require(BarcodePageImage.write(darkBox: qrBox))
        defer { try? FileManager.default.removeItem(at: image) }

        let parser = OnDeviceDocumentParser(
            recognizer: StubTextRecognizer(lines: [
                OCRLine(text: "扫码查看商品详情", boundingBox: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.03)),
                // EAN-13 数字行：AnchorExtractor 会抽成 .barcode 锚点，
                // 改造前经 barcodeFigures 通道外扩成与二维码重叠的 figure。
                OCRLine(text: "6 936832 529010", boundingBox: CGRect(x: 0.3, y: 0.42, width: 0.3, height: 0.02))
            ]),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                DetectedBarcode(payload: "https://qrcode.5rs.me/abc123", bbox: qrBox)
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let payloads = page.blocks.filter { $0.kind == .barcode }.compactMap(\.barcodePayload)
        #expect(payloads.filter { $0 == "https://qrcode.5rs.me/abc123" }.count == 1)

        let overlappingFigures = page.blocks.filter { block in
            guard block.kind == .figure else { return false }
            return block.bbox.insetBy(dx: -0.02, dy: -0.02).intersects(qrBox)
        }
        #expect(overlappingFigures.isEmpty, "条码区域出了重叠 figure：\(overlappingFigures.map(\.bbox))")
    }

    @Test("条码旁的 URL 降级文本并入条码块，不另出块")
    func urlLineNearBarcodeMergesIntoBarcodeBlock() async throws {
        let qrBox = CGRect(x: 0.3, y: 0.45, width: 0.3, height: 0.3)
        let url = "https://qrcode.5rs.me/abc123"
        let image = try #require(BarcodePageImage.write(darkBox: qrBox))
        defer { try? FileManager.default.removeItem(at: image) }

        let parser = OnDeviceDocumentParser(
            recognizer: StubTextRecognizer(lines: [
                OCRLine(text: "扫码查看商品详情", boundingBox: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.03)),
                // 印在二维码正下方的 URL —— 改造前会单独降级成一个 .barcode 块，
                // 和 Vision 检出的二维码块重复。
                OCRLine(text: url, boundingBox: CGRect(x: 0.28, y: 0.395, width: 0.34, height: 0.02))
            ]),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                DetectedBarcode(payload: url, bbox: qrBox)
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let barcodeBlocks = page.blocks.filter { $0.kind == .barcode }
        #expect(barcodeBlocks.count == 1, "URL 与二维码重复成块：\(barcodeBlocks.map { $0.barcodePayload ?? "" })")
        #expect(barcodeBlocks.first?.barcodePayload == url)
        #expect(barcodeBlocks.first?.text.contains("qrcode.5rs.me") == true)
        // URL 文本全页只出现一次（并入条码块，不再有第二份表示）
        let urlMentions = page.blocks.filter { $0.text.contains("qrcode.5rs.me") }
        #expect(urlMentions.count == 1)
    }

    @Test("远离条码的 URL 降级文本仍单独成块（行为保持）")
    func urlLineAwayFromBarcodeStaysOwnBlock() async throws {
        let qrBox = CGRect(x: 0.05, y: 0.6, width: 0.2, height: 0.2)
        let farURL = "https://qrcode.5rs.me/faraway"
        let image = try #require(BarcodePageImage.write(darkBox: qrBox))
        defer { try? FileManager.default.removeItem(at: image) }

        let parser = OnDeviceDocumentParser(
            recognizer: StubTextRecognizer(lines: [
                OCRLine(text: "扫码查看商品详情", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.03)),
                OCRLine(text: farURL, boundingBox: CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.02))
            ]),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                DetectedBarcode(payload: "https://example.com/qr", bbox: qrBox)
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let payloads = page.blocks.filter { $0.kind == .barcode }.compactMap(\.barcodePayload)
        #expect(payloads.count == 2, "应当恰好两个条码块：\(payloads)")
        #expect(payloads.contains(farURL), "远离条码的 URL 不能被吞掉：\(payloads)")
        #expect(payloads.contains("https://example.com/qr"))
    }

    // MARK: - 交叉去重规则（parser 兜底）

    @Test("figure↔barcode 交叉去重：IoU > 0.5 或包含即丢弃 figure")
    func crossDedupDropsOverlappingFigures() {
        let barcode = CGRect(x: 0.3, y: 0.4, width: 0.2, height: 0.2)
        let result = OnDeviceDocumentParser.removingBarcodeOverlaps(
            [
                CGRect(x: 0.32, y: 0.42, width: 0.2, height: 0.2),  // IoU ≈ 0.6 → 丢
                CGRect(x: 0.34, y: 0.44, width: 0.1, height: 0.1),  // 被条码包含 → 丢
                CGRect(x: 0.48, y: 0.42, width: 0.2, height: 0.2),  // 边缘轻擦，IoU ≈ 0.05 → 留
                CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1)   // 完全不相交 → 留
            ],
            barcodes: [barcode]
        )
        #expect(result.count == 2, "只有轻擦与远离的 figure 该留下：\(result)")
    }

    // MARK: - 夹具

    private func makeInput(
        occupied: [CGRect] = [],
        anchors: [LayoutAnchor] = []
    ) -> FigureRegionsV2.Input {
        FigureRegionsV2.Input(
            textBoxes: [CGRect(x: 0.1, y: 0.85, width: 0.6, height: 0.03)],
            layout: PageLayout(
                contentBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.78),
                medianLineHeight: 0.02,
                medianGap: 0.01,
                bands: [],
                regions: [],
                columns: [],
                anchors: anchors,
                lineSemantics: []
            ),
            occupied: occupied
        )
    }
}

/// 可控 OCR 替身：忽略图片，返回固定行。
private struct StubTextRecognizer: TextRecognizing {
    let lines: [OCRLine]
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: lines)
    }
}

/// 条码检测替身（模拟器上真检测器恒为空，见 `BarcodeDetecting` 的说明）。
private struct StubBarcodeDetector: BarcodeDetecting {
    let barcodes: [DetectedBarcode]
    func detect(in image: CGImage) -> [DetectedBarcode] { barcodes }
}

/// 白底 + 指定归一化区域的黑色方块（模拟条码墨块）。解析器需要真实图片文件
/// 才会走条码/配图通路；内容形状不参与断言（条码来自注入替身）。
private enum BarcodePageImage {
    static func write(darkBox: CGRect) -> URL? {
        let size = CGSize(width: 400, height: 520)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // Vision 归一化（原点左下）→ UIKit 坐标（原点左上）
            UIColor.black.setFill()
            context.fill(CGRect(
                x: darkBox.minX * size.width,
                y: (1 - darkBox.maxY) * size.height,
                width: darkBox.width * size.width,
                height: darkBox.height * size.height
            ))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zhixia-barcode-page-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }
}
