import Foundation
import Testing
import UIKit

@testable import Zhixia

/// V3.1：iOS 26 结构化通路（`RecognizeDocumentsRequest`）的接线契约。
///
/// 这一组测试**不碰真实的 Vision**（模拟器上跑不出稳定结果，而且老系统上根本没有这个 API），
/// 验证的是「接线」本身：结构化结果优先、拿不到就回退、回退时行为与改动前完全一致。
struct DocumentStructureTests {

    // MARK: - 通路选择

    @Test("结构化通路给出表格时，必须直接用它的行列结构")
    func structuredTableIsUsed() async throws {
        let structured = StructuredDocumentPage(
            lines: [OCRLine(text: "营养成分表", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05))],
            tables: [
                DetectedTable(
                    table: ReconstructTable(rows: [["项目", "每100克", "NRV%"], ["能量", "1429千焦", "17%"]]),
                    bbox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.25)
                )
            ],
            barcodes: [],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)

        let tables = page.blocks.filter { $0.kind == .table }
        #expect(tables.count == 1)
        #expect(tables.first?.table?.rows.count == 2)
        #expect(tables.first?.table?.rows.first == ["项目", "每100克", "NRV%"])
    }

    @Test("结构化通路返回 nil 时必须回退几何管线")
    func fallsBackWhenStructureReturnsNil() async throws {
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: nil)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)
        #expect(page.blocks.contains { $0.text.contains("房屋租赁合同") })
    }

    @Test("结构化通路返回空结果时必须回退，而不是当成「这页没内容」")
    func fallsBackWhenStructureIsEmpty() async throws {
        let empty = StructuredDocumentPage(lines: [], tables: [], barcodes: [], source: .documentRequest)
        #expect(empty.hasContent == false)

        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: empty)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)
        #expect(page.blocks.contains { $0.text.contains("房屋租赁合同") })
    }

    @Test("不注入结构化识别器时行为不变（iOS 18/25 的真实情形）")
    func geometricOnlyStillWorks() async throws {
        let parser = OnDeviceDocumentParser(recognizer: PreviewRecognizer())
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)
        #expect(page.blocks.contains { $0.text.contains("房屋租赁合同") })
    }

    /// T007（spec/layout-engine plan D3）：`ReconstructPage.layout` 字段自 IR v2 起就存在，
    /// 但此前**从未被赋值**。现在 `LayoutAnalyzer` 产物必须页级落盘 —— 区域布局引擎
    /// （US1）与配图检测消费同一份度量。图缺失（/dev/null）也必须照写：layout 是
    /// 纯几何产物，不依赖图像。
    ///
    /// 不复用 `PreviewRecognizer`：它给的 bbox 是 `.zero`，度量值全是 0，
    /// 断言不出「度量真的来自行几何」。
    @Test("parser 必须把页级版面度量写进 page.layout（图缺失也一样）")
    func parserWritesPageLayout() async throws {
        let parser = OnDeviceDocumentParser(recognizer: LayoutMetricRecognizer())
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)

        let layout = try #require(page.layout, "有文本行的页必须有版面度量")
        #expect(abs(layout.medianLineHeight - 0.03) < 1e-9)
        #expect(abs(layout.contentBounds.width - 0.6) < 1e-9)
    }

    @Test("结构化通路的表格区域内的行不再进正文段落")
    func tableRowsDoNotLeakIntoParagraphs() async throws {
        let structured = StructuredDocumentPage(
            lines: [
                OCRLine(text: "配料：饮用水", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.7, height: 0.04)),
                // 这一行落在表格 bbox 内 → 应被剔除，不能既进表格又进正文
                OCRLine(text: "能量1429千焦17%", boundingBox: CGRect(x: 0.15, y: 0.6, width: 0.6, height: 0.03))
            ],
            tables: [
                DetectedTable(
                    table: ReconstructTable(rows: [["能量", "1429千焦", "17%"]]),
                    bbox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.2)
                )
            ],
            barcodes: [],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)

        let paragraphText = page.blocks
            .filter { $0.kind != .table }
            .map(\.text)
            .joined(separator: "\n")
        #expect(paragraphText.contains("配料"))
        #expect(paragraphText.contains("能量1429千焦17%") == false)
    }

    /// 回归：实测 `RecognizeDocumentsRequest` 的 `container.barcodes` 在样张上是 **0 个**，
    /// 而 `VNDetectBarcodesRequest` 能检出。条码漏掉 = 导出产物里少一张图 + 少个 payload，
    /// 所以两条来源必须取并集，不能用新的替换旧的。
    ///
    /// ⚠️ 这里必须注入替身：`VNDetectBarcodesRequest` 在 iOS 模拟器上**恒定返回 0**
    /// （已用真实样张 + 全部 symbology 验证过），拿真检测器写这条测试会得到假绿。
    @Test("结构化通路漏掉的条码，要用几何检测补回来")
    func structuredPathMergesGeometricBarcodes() async throws {
        let image = try #require(PageImageFixture.write())
        defer { try? FileManager.default.removeItem(at: image) }

        // 结构化通路「什么都没检到」——正是样张上的真实情形
        let structured = StructuredDocumentPage(
            lines: [OCRLine(text: "配料：饮用水", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.7, height: 0.04))],
            tables: [],
            barcodes: [],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                DetectedBarcode(payload: "https://qrcode.5rs.me/abc", bbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let barcodes = page.blocks.filter { $0.kind == .barcode }
        #expect(barcodes.isEmpty == false, "结构化通路漏掉的条码没有被几何检测补回来")
        #expect(barcodes.contains { $0.barcodePayload?.contains("qrcode.5rs.me") == true })
    }

    @Test("条码合并要去重：同一位置 / 同一 payload 不能出两块")
    func barcodeMergeDeduplicates() async throws {
        let image = try #require(PageImageFixture.write())
        defer { try? FileManager.default.removeItem(at: image) }

        let shared = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let structured = StructuredDocumentPage(
            lines: [OCRLine(text: "配料：饮用水", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.7, height: 0.04))],
            tables: [],
            barcodes: [DetectedBarcode(payload: "same-payload", bbox: shared)],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                // 位置重叠 → 视为同一个
                DetectedBarcode(payload: "same-payload", bbox: shared),
                // 位置不同、payload 也不同 → 应当保留
                DetectedBarcode(payload: "another-code", bbox: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1))
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)
        let payloads = page.blocks.filter { $0.kind == .barcode }.compactMap(\.barcodePayload)
        #expect(Set(payloads).count == payloads.count, "同一个条码重复成块：\(payloads)")
        #expect(payloads.contains("same-payload"))
        #expect(payloads.contains("another-code"), "不同位置的条码被误去重了：\(payloads)")
    }

    @Test("几何通路也得用注入的条码检测器")
    func geometricPathUsesInjectedBarcodeDetector() async throws {
        let image = try #require(PageImageFixture.write())
        defer { try? FileManager.default.removeItem(at: image) }

        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            barcodeDetector: StubBarcodeDetector(barcodes: [
                DetectedBarcode(payload: "geo-only", bbox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
            ])
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)
        #expect(page.blocks.contains { $0.barcodePayload == "geo-only" })
    }

    @Test("结构化通路的 isTitle 提示能让这一行判成标题")
    func titleHintProducesHeading() {
        // 行高刻意做成「不大」— 光靠启发式（height > medianH * 1.1）判不出标题，
        // 只有 isTitle 提示能救。几何通路没有这个字段，行为不受影响。
        let plain = [
            OCRLine(text: "季度经营情况汇报", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.03)),
            OCRLine(text: "本季度收入较上季度增长一成，主要来自新客户。", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.03)),
            OCRLine(text: "成本端基本持平，毛利率略有改善。", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.03))
        ]
        let hinted = plain.enumerated().map { index, line in
            OCRLine(text: line.text, boundingBox: line.boundingBox, isTitle: index == 0)
        }

        let withoutHint = OnDeviceReadingOrder.makeBlocks(from: plain)
        let withHint = OnDeviceReadingOrder.makeBlocks(from: hinted)

        #expect(withoutHint.first?.kind != .heading, "没有提示时按启发式不该判成标题")
        #expect(withHint.first?.kind == .heading, "给了 isTitle 提示就该判成标题")
    }

    // MARK: - 表格拉平（合并单元格）

    @Test("合并单元格只在左上角保留文本，不重复 N 遍")
    func mergedCellKeepsTextOnce() {
        // 一个 2 行 × 2 列的网格，左上角那个 cell 跨了 2 行。
        // 它在 `rows` 里会出现在两个视觉行里 —— 只能保留一次。
        let spanning = VisionDocumentStructureRecognizer.RawCell(
            text: "项目",
            rowRange: 0...1,
            columnRange: 0...0
        )
        let grid = VisionDocumentStructureRecognizer.flatten([
            [spanning, .init(text: "1429千焦", rowRange: 0...0, columnRange: 1...1)],
            [spanning, .init(text: "17%", rowRange: 1...1, columnRange: 1...1)]
        ])
        #expect(grid == [["项目", "1429千焦"], ["", "17%"]])
    }

    @Test("跨列的单元格在右侧留下空位，而不是把后面的列挤前")
    func spanningColumnsLeaveGap() {
        let grid = VisionDocumentStructureRecognizer.flatten([
            [
                .init(text: "标题横跨两列", rowRange: 0...0, columnRange: 0...1),
                .init(text: "C", rowRange: 0...0, columnRange: 2...2)
            ],
            [
                .init(text: "a", rowRange: 1...1, columnRange: 0...0),
                .init(text: "b", rowRange: 1...1, columnRange: 1...1),
                .init(text: "c", rowRange: 1...1, columnRange: 2...2)
            ]
        ])
        #expect(grid == [["标题横跨两列", "", "C"], ["a", "b", "c"]])
        #expect(grid.allSatisfy { $0.count == 3 })
    }

    @Test("参差不齐的行要补成矩形，否则导出会静默丢列")
    func raggedRowsArePadded() {
        let grid = VisionDocumentStructureRecognizer.flatten([
            [.init(text: "a", rowRange: 0...0, columnRange: 0...0),
             .init(text: "b", rowRange: 0...0, columnRange: 1...1),
             .init(text: "c", rowRange: 0...0, columnRange: 2...2)],
            [.init(text: "d", rowRange: 1...1, columnRange: 0...0)]
        ])
        #expect(grid.count == 2)
        #expect(grid[1].count == 3)
        #expect(grid[1] == ["d", "", ""])
    }

    @Test("空表格拉平成空数组")
    func emptyTableFlattensToNothing() {
        #expect(VisionDocumentStructureRecognizer.flatten([]) == [])
        #expect(VisionDocumentStructureRecognizer.flatten([[]]) == [])
    }

    // MARK: - 列宽比例（T006：不再丢弃列边界）

    @Test("列宽比例来自各列内容区域的并集，相邻边界取中点")
    func columnRatiosMeasureContentExtents() {
        let row0: [VisionDocumentStructureRecognizer.RawCell] = [
            .init(text: "项目", rowRange: 0...0, columnRange: 0...0,
                  frame: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.05)),
            .init(text: "每100克", rowRange: 0...0, columnRange: 1...1,
                  frame: CGRect(x: 0.40, y: 0.50, width: 0.40, height: 0.05))
        ]
        let row1: [VisionDocumentStructureRecognizer.RawCell] = [
            .init(text: "能量", rowRange: 1...1, columnRange: 0...0,
                  frame: CGRect(x: 0.10, y: 0.40, width: 0.18, height: 0.05)),
            .init(text: "1429千焦", rowRange: 1...1, columnRange: 1...1,
                  frame: CGRect(x: 0.42, y: 0.40, width: 0.30, height: 0.05))
        ]
        let ratios = VisionDocumentStructureRecognizer.columnRatios([row0, row1])
        // 列 0 内容并集 [0.10, 0.30]，列 1 [0.40, 0.80]；
        // 边界 0.10 / 0.35 / 0.80 → 宽 0.25 / 0.45，归一化和为 1。
        #expect(ratios?.count == 2)
        #expect(abs((ratios?[0] ?? 0) - 0.25 / 0.70) < 1e-9)
        #expect(abs((ratios?[1] ?? 0) - 0.45 / 0.70) < 1e-9)
        #expect(abs((ratios?.reduce(0, +) ?? 0) - 1) < 1e-9)
    }

    @Test("跨列单元格不参与列宽测量，只有单列单元格决定边界")
    func spanningCellsAreExcludedFromRatios() {
        let header: [VisionDocumentStructureRecognizer.RawCell] = [
            .init(text: "营养成分表", rowRange: 0...0, columnRange: 0...2,
                  frame: CGRect(x: 0.10, y: 0.60, width: 0.70, height: 0.05))
        ]
        let body: [VisionDocumentStructureRecognizer.RawCell] = [
            .init(text: "项目", rowRange: 1...1, columnRange: 0...0,
                  frame: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.05)),
            .init(text: "NRV%", rowRange: 1...1, columnRange: 1...1,
                  frame: CGRect(x: 0.40, y: 0.50, width: 0.15, height: 0.05)),
            .init(text: "17%", rowRange: 1...1, columnRange: 2...2,
                  frame: CGRect(x: 0.62, y: 0.50, width: 0.18, height: 0.05))
        ]
        let ratios = VisionDocumentStructureRecognizer.columnRatios([header, body])
        // 表头跨列 frame 不许污染测量：三列内容 [0.10,0.30] [0.40,0.55] [0.62,0.80]，
        // 边界 0.10 / 0.35 / 0.585 / 0.80 → 宽 0.25 / 0.235 / 0.215。
        #expect(ratios?.count == 3)
        #expect(abs((ratios?[0] ?? 0) - 0.25 / 0.70) < 1e-9)
        #expect(abs((ratios?[1] ?? 0) - 0.235 / 0.70) < 1e-9)
        #expect(abs((ratios?[2] ?? 0) - 0.215 / 0.70) < 1e-9)
    }

    @Test("合成输入没有 frame 时返回 nil（下游均分兜底）")
    func ratiosRequireFrames() {
        let synthetic = [[
            VisionDocumentStructureRecognizer.RawCell(
                text: "a", rowRange: 0...0, columnRange: 0...0
            ),
            .init(text: "b", rowRange: 0...0, columnRange: 1...1)
        ]]
        #expect(VisionDocumentStructureRecognizer.columnRatios(synthetic) == nil)
    }

    @Test("某列只有跨列单元格时信息不完整，返回 nil")
    func ratiosNeedEveryColumnMeasured() {
        let row: [VisionDocumentStructureRecognizer.RawCell] = [
            .init(text: "a", rowRange: 0...0, columnRange: 0...0,
                  frame: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.05)),
            .init(text: "跨两列", rowRange: 0...0, columnRange: 1...2,
                  frame: CGRect(x: 0.40, y: 0.50, width: 0.40, height: 0.05))
        ]
        let ratios = VisionDocumentStructureRecognizer.columnRatios([row])
        #expect(ratios == nil)
    }

    @Test("空表格与单列表格返回 nil")
    func ratiosDegenerateInputs() {
        #expect(VisionDocumentStructureRecognizer.columnRatios([]) == nil)
        #expect(VisionDocumentStructureRecognizer.columnRatios([[]]) == nil)
        let singleColumn: [[VisionDocumentStructureRecognizer.RawCell]] = [
            [.init(text: "a", rowRange: 0...0, columnRange: 0...0,
                   frame: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.05))]
        ]
        #expect(VisionDocumentStructureRecognizer.columnRatios(singleColumn) == nil)
    }

    // MARK: - wps-parity-layout T014（FR-004 containment 不变量，T009 落地）

    /// splitCarriedLines 的「救回」分支：行落在表格 bbox 里，但文字不在任何
    /// 单元格里（识别端把表格外一行圈进了表框 / 表格行被结构端丢弃）——
    /// 依 FR-004 不得静默丢弃，必须保留回文字层；表格块本身照常产出。
    /// （「被携带 → 剔除」方向由 `tableRowsDoNotLeakIntoParagraphs` 钉住，
    /// 这里钉的是没被携带时不能赌「结构丢了它」。）
    @Test("表格 bbox 内未被单元格携带的行必须救回文字层（FR-004 不静默丢字）")
    func uncoveredLineInsideTableBBoxIsRescued() async throws {
        let structured = StructuredDocumentPage(
            lines: [
                // 落在表格 bbox 内、但文字不在任何单元格 → 救回
                OCRLine(text: "这行文字不在任何单元格里", boundingBox: CGRect(x: 0.15, y: 0.62, width: 0.5, height: 0.03)),
                OCRLine(text: "配料：饮用水", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.7, height: 0.04))
            ],
            tables: [
                DetectedTable(
                    table: ReconstructTable(rows: [["项目", "每100克"], ["能量", "1429千焦"]]),
                    bbox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.2)
                )
            ],
            barcodes: [],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)

        let paragraphText = page.blocks
            .filter { $0.kind != .table }
            .map(\.text)
            .joined(separator: "\n")
        #expect(paragraphText.contains("这行文字不在任何单元格里"), "表格 bbox 内未被携带的文字必须救回文字层")
        #expect(paragraphText.contains("配料"))
        // 表格块本身不受救回影响
        let tables = page.blocks.filter { $0.kind == .table }
        #expect(tables.count == 1)
        #expect(tables.first?.table?.rows.first == ["项目", "每100克"])
    }

    /// 条码 bbox 内未被 payload 携带的行（二维码旁的中文说明）必须救回文字层；
    /// 条码块与 payload 照常产出。注意与「URL 降级文本并入条码块」
    /// （`BarcodeDedupTests`，OCRNoiseFilter `.demoteToBarcode` 通路）区分：
    /// 这里的说明行不是 URL、不降级，走的是 containment 覆盖判定。
    @Test("条码 bbox 内非 payload 的说明行救回文字层，条码块照常")
    func barcodeCaptionNotMatchingPayloadIsRescued() async throws {
        // 条码块产出在 `if let image` 门内（要裁码图）→ 这里必须给可解码页图，
        // /dev/null 会让 .barcode 块整体不发。图内容不重要（白底 + 黑块），
        // 真条码检测器在模拟器上恒为空，条码来自 structured.barcodes。
        let image = try #require(PageImageFixture.write())
        defer { try? FileManager.default.removeItem(at: image) }

        let structured = StructuredDocumentPage(
            lines: [
                // 中心 (0.75, 0.23) 落在条码 bbox (0.55..0.95, 0.05..0.35) 内
                OCRLine(text: "扫码查看完整答案", boundingBox: CGRect(x: 0.60, y: 0.20, width: 0.30, height: 0.06)),
                OCRLine(text: "参考答案见下期", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.04))
            ],
            tables: [],
            barcodes: [
                DetectedBarcode(payload: "https://example.com/answer-key", bbox: CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.3))
            ],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured)
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let paragraphText = page.blocks
            .filter { $0.kind != .barcode }
            .map(\.text)
            .joined(separator: "\n")
        #expect(paragraphText.contains("扫码查看完整答案"), "条码 bbox 内非 payload 文字必须救回文字层")
        #expect(paragraphText.contains("参考答案见下期"))
        let payloads = page.blocks.filter { $0.kind == .barcode }.compactMap(\.barcodePayload)
        #expect(payloads.contains("https://example.com/answer-key"), "条码块与 payload 照常产出")
    }

    /// 空 payload 的码（未解码）判不了覆盖 —— 落在它 bbox 里的行必须救回，
    /// 不能赌「码里就是这行字」。
    @Test("未解码（空 payload）的码不能认领覆盖，行救回文字层")
    func undecodedBarcodeCannotClaimCoverage() async throws {
        let structured = StructuredDocumentPage(
            lines: [
                OCRLine(text: "未解码二维码上方的文字", boundingBox: CGRect(x: 0.60, y: 0.20, width: 0.30, height: 0.06))
            ],
            tables: [],
            barcodes: [
                DetectedBarcode(payload: "", bbox: CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.3))
            ],
            source: .documentRequest
        )
        let parser = OnDeviceDocumentParser(
            recognizer: PreviewRecognizer(),
            structureRecognizer: StubStructureRecognizer(result: structured)
        )
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .auto)

        let paragraphText = page.blocks
            .filter { $0.kind != .barcode }
            .map(\.text)
            .joined(separator: "\n")
        #expect(paragraphText.contains("未解码二维码上方的文字"), "空 payload 判不了覆盖，行必须救回文字层")
    }
}

/// 可控的结构化识别替身。
private struct StubStructureRecognizer: DocumentStructureRecognizing {
    let result: StructuredDocumentPage?
    func recognize(imageURL: URL, pageID: UUID) async -> StructuredDocumentPage? { result }
}

/// 带真实行几何的 OCR 替身（`PreviewRecognizer` 的 bbox 是 `.zero`，
/// 验证不了「版面度量来自行几何」这条通路）。
private struct LayoutMetricRecognizer: TextRecognizing {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: [
            OCRLine(text: "第一行正文", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.03)),
            OCRLine(text: "第二行正文", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.03))
        ])
    }
}

/// 条码检测替身。真检测器在模拟器上恒为空，见 `BarcodeDetecting` 的说明。
private struct StubBarcodeDetector: BarcodeDetecting {
    let barcodes: [DetectedBarcode]
    func detect(in image: CGImage) -> [DetectedBarcode] { barcodes }
}

/// 一张「存在即可」的页面图 —— 解析器需要它能被解码，用来裁图与取尺寸。
/// 内容不重要，因为条码检测已经换成替身了。
enum PageImageFixture {
    static func write() -> URL? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 520), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 520))
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 60, width: 320, height: 40))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zhixia-page-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }
}
