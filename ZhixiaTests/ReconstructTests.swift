import Foundation
import Testing
import UIKit
@testable import Zhixia

struct ReconstructSceneRouterTests {
    @Test("Nutrition labels route to table")
    func nutritionIsTable() {
        let scene = ReconstructSceneRouter.route(text: "小象超市\n营养成分表\n项目\n每100克\nNRV%\n能量")
        #expect(scene == .table)
    }

    @Test("Exam questions route to exam")
    func questionsAreExam() {
        let scene = ReconstructSceneRouter.route(
            text: "Test 4 Questions 1~5\nQuestion 1. What does Becky want to drink?\nA\nB\nC"
        )
        #expect(scene == .exam)
    }

    @Test("A contract stays plain")
    func contractIsPlain() {
        let scene = ReconstructSceneRouter.route(text: "房屋租赁合同\n甲方林秋白\n乙方陈可\n租期一年")
        #expect(scene == .plain)
    }
}

struct OnDeviceReadingOrderTests {
    @Test("A large first line becomes a heading")
    func headingThenParagraphs() {
        let lines = [
            OCRLine(text: "租赁合同", boundingBox: CGRect(x: 0.1, y: 0.86, width: 0.4, height: 0.07)),
            OCRLine(text: "甲方林秋白", boundingBox: CGRect(x: 0.1, y: 0.68, width: 0.55, height: 0.035)),
            OCRLine(text: "乙方陈可", boundingBox: CGRect(x: 0.1, y: 0.62, width: 0.5, height: 0.035))
        ]
        let blocks = OnDeviceReadingOrder.makeBlocks(from: lines)
        #expect(blocks.count >= 2)
        #expect(blocks[0].kind == .heading)
        #expect(blocks[0].text.contains("租赁合同"))
        #expect(blocks.contains { $0.text.contains("甲方") })
    }

    @Test("Same-baseline fragments join into one row")
    func sameRowJoins() {
        let lines = [
            OCRLine(text: "Hello", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.04)),
            OCRLine(text: "world", boundingBox: CGRect(x: 0.35, y: 0.5, width: 0.2, height: 0.04))
        ]
        let blocks = OnDeviceReadingOrder.makeBlocks(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks[0].text.contains("Hello"))
        #expect(blocks[0].text.contains("world"))
    }
}

struct DocxExportServiceTests {
    @Test("DOCX contains heading text as UTF-8")
    func docxContainsText() async throws {
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "合同",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .plain,
                    usedCloud: false,
                    blocks: [
                        ReconstructBlock(
                            kind: .heading,
                            bbox: .zero,
                            text: "房屋租赁合同",
                            style: .heading
                        ),
                        ReconstructBlock(
                            kind: .paragraph,
                            bbox: .zero,
                            text: "甲方林秋白"
                        )
                    ]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(document, fileName: "test-\(UUID().uuidString).docx", tier: .structured)
        let data = try Data(contentsOf: url)
        let utf8 = String(decoding: data, as: UTF8.self)
        #expect(utf8.contains("房屋租赁合同"))
        #expect(utf8.contains("word/document.xml") || data.contains(Array("word/document.xml".utf8)))
        try? FileManager.default.removeItem(at: url)
    }

    @Test("DOCX embeds a real table and a PNG")
    func docxEmbedsTableAndImage() async throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "营养",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .table,
                    usedCloud: false,
                    blocks: [
                        ReconstructBlock(
                            kind: .table,
                            bbox: .zero,
                            text: "",
                            table: ReconstructTable(rows: [
                                ["项目", "每100克", "NRV%"],
                                ["能量", "1429 千焦", "17%"]
                            ])
                        ),
                        ReconstructBlock(
                            kind: .figure,
                            bbox: .zero,
                            text: "",
                            figureRelativePath: png.path
                        )
                    ]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(document, fileName: "table-\(UUID().uuidString).docx", tier: .structured)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let utf8 = String(decoding: data, as: UTF8.self)
        #expect(utf8.contains("<w:tbl>"))
        #expect(utf8.contains("1429"))
        #expect(utf8.contains("17%"))
        #expect(data.contains(Array("word/media/image1.png".utf8)))
        #expect(utf8.contains("a:blip"))
    }

    @Test("DOCX B 档用 wp:anchor 定位图")
    func docxAnchoredTierUsesAnchor() async throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "题",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .exam,
                    usedCloud: false,
                    blocks: [
                        ReconstructBlock(
                            kind: .figure,
                            bbox: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3),
                            text: "",
                            figureRelativePath: png.path
                        )
                    ]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(document, fileName: "b-\(UUID().uuidString).docx", tier: .anchored)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let utf8 = String(decoding: data, as: UTF8.self)
        #expect(utf8.contains("wp:anchor"))
        #expect(utf8.contains("behindDoc=\"0\"") || utf8.contains("behindDoc=\"1\""))
        #expect(utf8.contains("posOffset"))
    }

    @Test("DOCX C 档把 figure 作为 behindDoc 衬底")
    func docxBackgroundTierUsesBehindDoc() async throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "衬底",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .plain,
                    usedCloud: false,
                    blocks: [
                        ReconstructBlock(
                            kind: .figure,
                            bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                            text: "",
                            figureRelativePath: png.path
                        ),
                        ReconstructBlock(
                            kind: .paragraph,
                            bbox: .zero,
                            text: "覆盖在衬底上的文字"
                        )
                    ]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(document, fileName: "c-\(UUID().uuidString).docx", tier: .background)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let utf8 = String(decoding: data, as: UTF8.self)
        #expect(utf8.contains("behindDoc=\"1\""))
        #expect(utf8.contains("覆盖在衬底上的文字"))
        #expect(utf8.contains("wp:anchor"))
    }
}

struct OnDeviceTableClusterTests {
    @Test("Nutrition boxes become a 3-column grid")
    func nutritionGrid() {
        let table = OnDeviceTableCluster.detect(from: ReconstructTestFixtures.nutritionLines())
        #expect(table != nil)
        let energy = table?.table.rows.first { row in
            row.contains(where: { $0.contains("能量") })
        }
        #expect(energy?.count == 3)
        #expect(energy?.contains { $0.contains("1429") } == true)
        #expect(energy?.contains { $0.contains("17%") } == true)
        let header = table?.table.rows.first { row in
            row.contains(where: { $0.contains("项目") })
        }
        #expect(header?.contains(where: { $0.contains("项目") }) == true)
        #expect(header?.contains(where: { $0.contains("NRV") }) == true)
    }

    @Test("A B C option letters are not a table")
    func optionLettersRejected() {
        let lines = (0..<12).map { index -> OCRLine in
            let col = index % 3
            let row = index / 3
            return OCRLine(
                text: ["A", "B", "C"][col],
                boundingBox: CGRect(
                    x: 0.2 + CGFloat(col) * 0.2,
                    y: 0.7 - CGFloat(row) * 0.04,
                    width: 0.08,
                    height: 0.03
                )
            )
        }
        #expect(OnDeviceTableCluster.detect(from: lines) == nil)
    }
}

struct OnDeviceFigureRegionTests {
    @Test("An empty illustration hole becomes a figure box")
    func illustrationHole() {
        let textBoxes = [
            CGRect(x: 0.05, y: 0.75, width: 0.9, height: 0.18),
            CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.18),
            CGRect(x: 0.05, y: 0.23, width: 0.38, height: 0.52)
        ]
        let boxes = OnDeviceFigureRegions.boxes(textBoxes: textBoxes)
        #expect(boxes.contains { $0.midX > 0.5 && $0.width > 0.2 && $0.height > 0.2 })
    }

    @Test("A figure-only page still counts as content")
    func figureCountsAsContent() throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }
        let page = ReconstructPage(
            pageID: UUID(),
            size: .zero,
            scene: .exam,
            usedCloud: false,
            blocks: [
                ReconstructBlock(
                    kind: .figure,
                    bbox: .zero,
                    text: "",
                    figureRelativePath: png.path
                )
            ]
        )
        #expect(page.hasContent)
        #expect(page.hasLocalFigure)
        let document = ReconstructDocument(documentID: UUID(), title: "试卷", pages: [page])
        #expect(document.needsCloudParsing == false)
    }
}

enum ReconstructTestFixtures {
    static func nutritionLines() -> [OCRLine] {
        let headers = ["项目", "每100克", "NRV%"]
        let data = [
            ["能量", "1429 千焦", "17%"],
            ["蛋白质", "3.4 克", "6%"],
            ["脂肪", "1.0 克", "2%"],
            ["碳水化合物", "80.5 克", "27%"]
        ]
        let xs: [CGFloat] = [0.10, 0.40, 0.70]
        var lines = [
            OCRLine(text: "营养成分表", boundingBox: CGRect(x: 0.15, y: 0.78, width: 0.55, height: 0.05))
        ]
        for (index, header) in headers.enumerated() {
            lines.append(
                OCRLine(text: header, boundingBox: CGRect(x: xs[index], y: 0.70, width: 0.18, height: 0.028))
            )
        }
        for (row, cells) in data.enumerated() {
            let y = 0.64 - CGFloat(row) * 0.05
            for (col, cell) in cells.enumerated() {
                lines.append(
                    OCRLine(text: cell, boundingBox: CGRect(x: xs[col], y: y, width: 0.18, height: 0.028))
                )
            }
        }
        return lines
    }

    static func pngURL() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        guard let data = image.pngData() else {
            throw ZhixiaError.exportFailed
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "zhixia-fig-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }
}

@MainActor
struct ReconstructViewModelTests {
    @Test("On-device reconstruct fills blocks from OCR")
    func reconstructFromRecognizer() async {
        let documentID = UUID()
        let pageID = UUID()
        let document = ScanDocument(
            id: documentID,
            title: "试卷",
            folderID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            isFavorite: false,
            pageIDs: [pageID],
            ocrSearchBlob: ""
        )
        let page = ScanPage(
            id: pageID,
            documentID: documentID,
            index: 0,
            quad: .fullImage,
            enhancement: .original,
            rotationTurns: 0,
            originalRelativePath: "o",
            renderedRelativePath: "r",
            thumbnailRelativePath: "t"
        )
        let viewModel = ReconstructViewModel(
            document: document,
            scanPages: [page],
            fileStore: FakePagePaths(),
            parser: OnDeviceDocumentParser(recognizer: PreviewRecognizer()),
            docx: DocxExportService(),
            searchablePDF: SearchablePDFExportService()
        )
        await viewModel.reconstruct()
        #expect(viewModel.hasContent)
        #expect(viewModel.blocks.contains { $0.text.contains("房屋租赁合同") })
    }
}
