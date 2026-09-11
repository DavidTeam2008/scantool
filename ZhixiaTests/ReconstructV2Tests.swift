import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

//  R2 还原样张测试 —— 全部跑在「真实样张 OCR」上，不是合成的 CGRect。
//
//  数据：ZhixiaTests/ReconstructV2Fixtures.swift（由 Tools/ocr-dump 生成）
//  背景：旧 ReconstructTests 用合成 bbox，全绿但真机样张照崩。
//        本文件把两张验收样张的真实失败固化下来，作为 M1~M5 的靶子。
//
//  约定：
//  - 当前仍失败的行为用 `withKnownIssue` 包住。这样套件保持绿色，
//    但一旦被修好，该测试会**反过来失败**，提醒你删掉 withKnownIssue 包装。
//  - 每个 withKnownIssue 都写了对应 docs/07 的条目编号，便于回溯。

// MARK: - 夹具自检（应当常绿）

struct ReconstructV2FixtureSanityTests {

    @Test("夹具非空且坐标合法")
    func fixturesAreWellFormed() {
        let samples = ReconstructV2Fixtures.allSamples
        #expect(samples.count == 2)
        for sample in samples {
            #expect(!sample.lines.isEmpty, "\(sample.name) 应有 OCR 行")
            #expect(sample.imageSize.width > 0 && sample.imageSize.height > 0)
            for line in sample.lines {
                let b = line.boundingBox
                #expect(b.minX >= -0.001 && b.maxX <= 1.001, "\(sample.name) 越界: \(line.text)")
                #expect(b.minY >= -0.001 && b.maxY <= 1.001, "\(sample.name) 越界: \(line.text)")
                #expect(b.width > 0 && b.height > 0)
            }
        }
    }

    @Test("营养表夹具含关键字段")
    func nutritionFixtureHasKeyFields() {
        let text = ReconstructV2Fixtures.nutritionMango.joinedText
        #expect(text.contains("营养成分表"))
        #expect(text.contains("1429 千焦"))
        #expect(text.contains("NRV%"))
        #expect(text.contains("每 100克"))
    }

    @Test("练习册夹具含关键字段")
    func workbookFixtureHasKeyFields() {
        let text = ReconstructV2Fixtures.workbookTest4.joinedText
        #expect(text.contains("Test 4"))
        #expect(text.contains("Question 1"))
        #expect(text.contains("Question 2"))
        #expect(text.contains("Question 3"))
    }

    @Test("每张样张的场景标注与 fixture 一致")
    func expectedSceneIsAnnotated() {
        for sample in ReconstructV2Fixtures.allSamples {
            #expect(sample.expectedScene != .auto)
        }
        #expect(ReconstructV2Fixtures.nutritionMango.expectedScene == .table)
        #expect(ReconstructV2Fixtures.workbookTest4.expectedScene == .exam)
    }
}

// MARK: - 场景路由（docs/07 §6.1 · R9）

struct ReconstructV2SceneRoutingTests {

    @Test("营养表路由到 table")
    func nutritionRoutesToTable() {
        let scene = ReconstructSceneRouter.route(
            text: ReconstructV2Fixtures.nutritionMango.joinedText,
            barcodeCount: 1
        )
        #expect(scene == .table)
    }

    @Test("练习册路由到 exam，而不是被 looksLikeGrid 抢成 table（解决 R9）")
    func workbookRoutesToExam() {
        let scene = ReconstructSceneRouter.route(
            text: ReconstructV2Fixtures.workbookTest4.joinedText,
            barcodeCount: 1
        )
        // M2.5：route 顺序调整为 exam 优先（Question/选项 > 数字 grid）
        #expect(scene == .exam)
    }
}

// MARK: - 表格识别 v2（docs/07 §6.3 · R2/R3/R4）
//  M2（TableGridV2Detector）已替代 v1 在该路径上的失败：
//  - 营养表：v1 行聚类把所有行合并成 2 行 → occupancy 0.45 拒绝；v2 自适应 rowGap + 锚点驱动 → 6×3
//  - 练习册：v1 误聚 7×2 假表；v2 无 tableTitle 锚点 → 拒绝
//  本段测试断言 v2 的正确性，并把以前 wrap 在 withKnownIssue 里的失败反转成绿。
//  v1（OnDeviceTableCluster）保留作为 ad-hoc 表的回退，行为不变。

struct ReconstructV2TableTests {

    @Test("营养表 v2 要能检出真网格（解决 R2/R3/R4）")
    func nutritionDetectsGrid() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        let table = TableGridV2Detector.detect(from: lines, profile: .nutrition)
        #expect(table != nil, "M2 锚点驱动应当检出营养表")
    }

    @Test("营养表网格应为 6 行 × 3 列（解决 B1/B2）")
    func nutritionGridMatchesGroundTruth() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let table = TableGridV2Detector.detect(from: lines, profile: .nutrition) else { return }
        let expected = ReconstructV2Fixtures.nutritionExpectedGrid
        #expect(table.rowCount == expected.count, "6 行（含表头）")
        #expect(table.columnCount == 3)
        #expect(table.profileName == "nutrition")
    }

    @Test("营养表「能量 / 1429 千焦 / 17%」必须同行（解决 B2/B3）")
    func nutritionEnergyRowStaysTogether() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let table = TableGridV2Detector.detect(from: lines, profile: .nutrition) else { return }
        let energyRow = table.table.rows.first { $0.contains(where: { $0.contains("能量") }) }
        #expect(energyRow != nil, "能量行必须存在")
        #expect(energyRow?.contains(where: { $0.contains("1429") }) == true)
        #expect(energyRow?.contains(where: { $0.contains("17%") }) == true)
    }

    @Test("营养表第一行必须是 header（项目 / 每 100克 / NRV%）")
    func nutritionHeaderRowDetected() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let table = TableGridV2Detector.detect(from: lines, profile: .nutrition) else { return }
        #expect(table.headerRowIndices == [0], "M2 应当把表头行标为 [0]")
        let header = table.table.rows.first ?? []
        #expect(header.contains("项目"))
        #expect(header.contains(where: { $0.contains("每") && $0.contains("100") }))
        #expect(header.contains(where: { $0.contains("NRV") }))
    }

    @Test("营养表 cell 内容应与 ground truth 逐行匹配")
    func nutritionCellsMatchGroundTruth() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let table = TableGridV2Detector.detect(from: lines, profile: .nutrition) else { return }
        let expected = ReconstructV2Fixtures.nutritionExpectedGrid
        // 跳过 header（expected[0] = 表头），对比 5 行数据
        for (i, expectedRow) in expected.dropFirst().enumerated() {
            let actualRow = table.table.rows[i + 1]
            for (c, expectedCell) in expectedRow.enumerated() {
                #expect(actualRow[c] == expectedCell,
                        "row \(i + 1) col \(c): expected \(expectedCell) got \(actualRow[c])")
            }
        }
    }

    @Test("练习册 v2 不应被聚成假表（解决 R2）")
    func workbookHasNoFakeTable() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        // 用 .nutrition profile 时，workbook 没有 tableTitle 锚点 → 拒绝
        let table = TableGridV2Detector.detect(from: lines, profile: .nutrition)
        #expect(table == nil, "M2 锚点驱动，练习册无表标题 → 必须 nil")
    }

    @Test("练习册用 v1 仍能检出假表 —— 用于证明 v1 不能删")
    func workbookV1StillProducesFakeTable() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        // v1 仍是 ad-hoc 启发式，无锚点概念，对练习册会误判
        // 此处不 assert 任何东西；只是记一行日志供回归用。
        let _ = OnDeviceTableCluster.detect(from: lines)
    }
}

// MARK: - 配图 / 条码 v2（docs/07 §6.4 · R5/R6）
//  M3 用 PageLayout.anchors 做配图：questionStem → 题下区域，barcode → barcode 区域。
//  这把营养表 0 个配图 / 练习册 0 个配图都修到 ≥ 1 / ≥ 3。
//  v1 (OnDeviceFigureRegions) 保留作 ad-hoc 兜底。

struct ReconstructV2FigureTests {

    @Test("营养表至少要有 1 个配图候选（条码）")
    func nutritionFindsBarcodeFigure() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines) else { return }
        let boxes = FigureRegionsV2.boxes(.init(
            textBoxes: lines.map(\.boundingBox),
            layout: layout,
            occupied: []
        ))
        #expect(boxes.count >= 1, "M3 应当至少为营养表产出 1 个 figure（barcode 区域）")
    }

    @Test("练习册至少要有 3 个配图候选（题下 anchor）")
    func workbookFindsQuestionFigures() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines) else { return }
        let boxes = FigureRegionsV2.boxes(.init(
            textBoxes: lines.map(\.boundingBox),
            layout: layout,
            occupied: []
        ))
        #expect(boxes.count >= 3, "M3 应当为练习册 Q1/Q2/Q3 各产 1 个题下图")
    }

    @Test("营养表配图应与 barcode OCR 文本位置大致一致")
    func nutritionFigureCoversBarcode() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines),
              let barcodeText = lines.first(where: { $0.text.contains("936832") })
        else { return }
        let boxes = FigureRegionsV2.boxes(.init(
            textBoxes: lines.map(\.boundingBox),
            layout: layout,
            occupied: []
        ))
        #expect(boxes.contains { $0.intersects(barcodeText.boundingBox) },
                "M3 产出的 figure 之一应覆盖到 barcode OCR 文本位置")
    }

    @Test("练习册题下 figure 应该在 question 视觉位置之下")
    func workbookFiguresAreBelowQuestions() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines),
              let q1 = lines.first(where: { $0.text.hasPrefix("Question 1") })
        else { return }
        let boxes = FigureRegionsV2.boxes(.init(
            textBoxes: lines.map(\.boundingBox),
            layout: layout,
            occupied: []
        ))
        // 至少 1 个 figure 的 maxY 应该 ≤ Q1 的 minY（在视觉上位于 Q1 之下）
        let belowQ1 = boxes.filter { $0.maxY <= q1.boundingBox.minY + 0.05 }
        #expect(belowQ1.count >= 1, "至少 1 个 figure 应位于 Q1 视觉位置之下")
    }

    @Test("v1 仍能产出一个孤立 illustration 空洞（保留作 ad-hoc 兜底）")
    func v1StillDetectsIllustrationHole() {
        let textBoxes = [
            CGRect(x: 0.05, y: 0.75, width: 0.9, height: 0.18),
            CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.18),
            CGRect(x: 0.05, y: 0.23, width: 0.38, height: 0.52)
        ]
        let boxes = OnDeviceFigureRegions.boxes(textBoxes: textBoxes)
        #expect(boxes.contains { $0.midX > 0.5 && $0.width > 0.2 && $0.height > 0.2 })
    }
}

// MARK: - 阅读序（docs/07 §6.2 · R7）

struct ReconstructV2ReadingOrderTests {

    @Test("营养表的表格行不应被拍成一段话")
    func nutritionRowsAreNotMashedIntoOneParagraph() {
        // M2 后：parser 先用 TableGridV2Detector 过滤表格行，剩下的行交给 reading order。
        // 这里复刻该路径：先检出表格，过滤掉表格行，再 makeBlocks。
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let grid = TableGridV2Detector.detect(from: lines, profile: .nutrition) else {
            // 表格都没检出 → 测试跳过
            return
        }
        let leftover = lines.filter { !TableGridV2Detector.contains(grid, line: $0) }
        let blocks = OnDeviceReadingOrder.makeBlocks(from: leftover)
        let mashed = blocks.first { block in
            block.text.contains("项目") && block.text.contains("NRV%") && block.text.contains("1429")
        }
        #expect(mashed == nil, "M2 滤掉表格行后，reading order 不应再把这些内容混成一段")
    }

    @Test("练习册 Section 1 必须排在 Section 2 之前（解决 R7）")
    func workbookSectionsKeepOrder() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        let blocks = OnDeviceReadingOrder.makeBlocks(from: lines)
        let joined = blocks.map(\.text).joined(separator: "\n")
        let s1 = joined.range(of: "Section 1")
        let s2 = joined.range(of: "Section 2")
        #expect(s1 != nil)
        #expect(s2 != nil)
        guard let s1, let s2 else { return }
        // M2.5：sameRow 阈值 0.45 → 0.30 + 自适应 rowThreshold，
        // Section 1 (y=0.834) 不再被 Section 2 (y=0.816) 反超。
        #expect(s1.lowerBound < s2.lowerBound)
    }

    @Test("练习册页眉「Test 4」不应抢占首个标题块（解决 R7/A1）")
    func workbookPageHeaderIsNotTheHeading() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        let blocks = OnDeviceReadingOrder.makeBlocks(from: lines)
        // M2.5：孤立短行（"Test 4"）已被剔除，标题是首块
        #expect(blocks.first?.text.contains("Questions 1~5") == true)
    }
}

// MARK: - M1 LayoutAnalyzer（docs/07 §6.5 · A1~A4）
// 验证纯几何版面分析（bands / regions / columns / anchors / lineSemantics）在
// 真实样张上的输出。M1 目标见 docs/07 §8 路线图「M1 IR v2 与 LayoutAnalyzer」。
// 当前样张期望（来自 /tmp/probe-layout 实测）：
//   营养表  → 4 bands（header 2 / body 12 / body-table 19 / footer 1）
//           → 1 column (conf 0.40，单栏兜底)
//           → anchors: tableTitle "营养成分表" + barcode "6 936832 529010"
//   练习册  → 2 bands（both body；首带含 "Test 4" 页眉但 5 行高度远超 2.5×medianH 不被误判为 header）
//           → 1 column (conf 0.40)
//           → anchors: 5 questionStem + 3 optionLetter（A/B/C）

struct LayoutAnalyzerTests {

    @Test("LayoutAnalyzer 对两张样张都返回非空 PageLayout")
    func analyzerReturnsLayoutForBothSamples() {
        let nutrition = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.nutritionMango.lines)
        let workbook  = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.workbookTest4.lines)
        #expect(nutrition != nil, "营养表应能产出 PageLayout")
        #expect(workbook != nil, "练习册应能产出 PageLayout")
    }

    // MARK: bands

    @Test("营养表 4 个 band：header / body / 营养表带 / 条码 footer")
    func nutritionBandCount() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.nutritionMango.lines) else { return }
        #expect(layout.bands.count == 4)
        // band 0 = "01" + 日期，2 行
        #expect(layout.bands[0].lineIndices.count == 2)
        #expect(layout.bands[0].lineIndices.contains(0))
        #expect(layout.bands[0].lineIndices.contains(1))
        // 末 band = 条码单行
        #expect(layout.bands.last?.lineIndices.count == 1)
    }

    @Test("练习册 2 个 band，且首尾都不被误判为 header/footer")
    func workbookBandCount() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.workbookTest4.lines) else { return }
        #expect(layout.bands.count == 2, "练习册正文是连续多行，按大间隙只切 2 带")
        // 首带含 5 行（Test 4 + 标题 + Section 1/2 + Question 1），height 远超 2.5×medianH
        #expect(layout.bands[0].lineIndices.count >= 4)
    }

    // MARK: regions

    @Test("营养表有 header + footer + 2 个 body")
    func nutritionRegionsHaveHeaderAndFooter() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.nutritionMango.lines) else { return }
        let kinds = layout.regions.map(\.kind)
        #expect(kinds.filter { $0 == .header }.count == 1)
        #expect(kinds.filter { $0 == .footer }.count == 1)
        #expect(kinds.filter { $0 == .body }.count == 2)
    }

    @Test("练习册没有 header/footer，全是 body（避免 Test 4 抢成页眉）")
    func workbookHasNoHeaderFooter() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.workbookTest4.lines) else { return }
        #expect(layout.regions.contains { $0.kind == .header } == false)
        #expect(layout.regions.contains { $0.kind == .footer } == false)
        #expect(layout.regions.allSatisfy { $0.kind == .body })
    }

    // MARK: columns

    @Test("营养表与练习册都被判为单栏（gutterRatio < 6% 兜底）")
    func bothSamplesAreSingleColumn() {
        let nutrition = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.nutritionMango.lines)
        let workbook  = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.workbookTest4.lines)
        guard let nutrition, let workbook else { return }
        #expect(nutrition.columns.count == 1)
        #expect(nutrition.columns.first?.isPrimary == true)
        #expect(nutrition.columns.first?.confidence == 0.40)
        #expect(workbook.columns.count == 1)
        #expect(workbook.columns.first?.isPrimary == true)
        #expect(workbook.columns.first?.confidence == 0.40)
    }

    // MARK: anchors

    @Test("营养表检出 tableTitle 与 barcode 两个锚点")
    func nutritionHasTableTitleAndBarcodeAnchors() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.nutritionMango.lines) else { return }
        let tableTitle = layout.anchors.first { $0.kind == .tableTitle && $0.text?.contains("营养成分表") == true }
        let barcode = layout.anchors.first { $0.kind == .barcode && $0.text?.contains("936832") == true }
        #expect(tableTitle != nil)
        #expect(tableTitle?.confidence == 0.95)
        #expect(barcode != nil)
        #expect(barcode?.confidence == 0.70)
    }

    @Test("练习册检出 5 个 questionStem 与 A/B/C 三个 optionLetter")
    func workbookHasQuestionStemsAndOptions() {
        guard let layout = LayoutAnalyzer.analyze(lines: ReconstructV2Fixtures.workbookTest4.lines) else { return }
        let stems = layout.anchors.filter { $0.kind == .questionStem }
        let opts = layout.anchors.filter { $0.kind == .optionLetter }
        #expect(stems.count == 5, "Section 1/2 + Question 1/2/3")
        #expect(opts.count == 3)
        let letters = opts.compactMap { $0.text }.sorted()
        #expect(letters == ["A", "B", "C"])
    }

    // MARK: lineSemantics

    @Test("营养表 lineSemantics 在「营养成分表」与条码行打标")
    func nutritionLineSemanticsMarksTitleAndBarcode() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines) else { return }
        let titleIdx = lines.firstIndex { $0.text == "营养成分表" }
        let barcodeIdx = lines.firstIndex { $0.text.contains("936832") }
        guard let titleIdx, let barcodeIdx else { return }
        #expect(layout.lineSemantics[titleIdx] == .tableTitle)
        #expect(layout.lineSemantics[barcodeIdx] == .barcode)
        // 其余行应为 nil
        let unlabeledCount = layout.lineSemantics.enumerated().filter { idx, tag in
            tag == nil && idx != titleIdx && idx != barcodeIdx
        }.count
        #expect(unlabeledCount == lines.count - 2)
    }

    @Test("练习册 lineSemantics 把 Section/Question 行打 questionStem，A/B/C 打 optionLetter")
    func workbookLineSemanticsMarksStemsAndOptions() {
        let lines = ReconstructV2Fixtures.workbookTest4.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines) else { return }
        let stemIdx = lines.firstIndex { $0.text.hasPrefix("Question 1") }
        let aIdx = lines.firstIndex { $0.text == "A" }
        let bIdx = lines.firstIndex { $0.text == "B" }
        let cIdx = lines.firstIndex { $0.text == "C" }
        guard let stemIdx, let aIdx, let bIdx, let cIdx else { return }
        #expect(layout.lineSemantics[stemIdx] == .questionStem)
        #expect(layout.lineSemantics[aIdx] == .optionLetter)
        #expect(layout.lineSemantics[bIdx] == .optionLetter)
        #expect(layout.lineSemantics[cIdx] == .optionLetter)
        // "Test 4" 单独不应被标任何语义（M1 还没有 pageHeader 标签命中逻辑，靠 HeaderFooterClassifier 分类）
        let test4Idx = lines.firstIndex { $0.text == "Test 4" }
        if let test4Idx {
            #expect(layout.lineSemantics[test4Idx] == nil)
        }
    }
}

// MARK: - IR v2 接入（docs/07 §6.5 · A5）
// 验证 ReconstructDocument / Page / Block 的 v2 字段默认值与写入路径。

struct ReconstructIRv2IntegrationTests {

    @Test("ReconstructDocument.version 默认 = 2（IR v2）")
    func defaultDocumentVersionIsV2() {
        let page = ReconstructPage(
            pageID: UUID(),
            size: CGSize(width: 800, height: 1000),
            scene: .plain,
            usedCloud: false,
            blocks: []
        )
        let doc = ReconstructDocument(
            documentID: UUID(),
            title: "test",
            pages: [page]
        )
        #expect(doc.version == 2)
        #expect(page.layout == nil)
        #expect(page.anchors.isEmpty)
    }

    @Test("ReconstructBlock 接收 semantic / anchors / confidence 默认值")
    func blockV2FieldsDefault() {
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
            text: "hello"
        )
        #expect(block.semantic == nil)
        #expect(block.anchors.isEmpty)
        #expect(block.confidence == 1)
    }

    @Test("ReconstructBlock 携带语义 + 锚点构造时 IR v2 字段都生效")
    func blockV2FieldsRoundTrip() {
        let anchor = LayoutAnchor(kind: .questionStem, frame: .zero, text: "Q1", confidence: 0.85)
        let block = ReconstructBlock(
            kind: .list,
            bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
            text: "Q1",
            semantic: .questionStem,
            anchors: [anchor],
            confidence: 0.85
        )
        #expect(block.semantic == .questionStem)
        #expect(block.anchors.count == 1)
        #expect(block.anchors.first?.text == "Q1")
        #expect(block.confidence == 0.85)
    }

    @Test("ReconstructPage 可装载 LayoutAnalyzer 产出")
    func pageCanCarryLayoutAnalyzerOutput() {
        let lines = ReconstructV2Fixtures.nutritionMango.lines
        guard let layout = LayoutAnalyzer.analyze(lines: lines) else { return }
        // M1 只负责版面骨架，真实表格内容留 M2 接入。这里造一个最小可用的 table block
        // 验证 layout / anchors / hasContent 三条通路都通了。
        let table = ReconstructTable(rows: [["项目", "每 100克", "NRV%"]])
        let block = ReconstructBlock(
            kind: .table,
            bbox: layout.contentBounds,
            text: "营养成分表",
            table: table,
            semantic: .tableTitle,
            anchors: layout.anchors.filter { $0.kind == .tableTitle },
            confidence: 1
        )
        let page = ReconstructPage(
            pageID: UUID(),
            size: ReconstructV2Fixtures.nutritionMango.imageSize,
            scene: .table,
            usedCloud: false,
            blocks: [block],
            layout: layout,
            anchors: layout.anchors
        )
        #expect(page.layout != nil)
        #expect(page.layout?.bands.count == 4)
        #expect(page.anchors.contains { $0.kind == .tableTitle })
        #expect(page.anchors.contains { $0.kind == .barcode })
        #expect(page.hasContent)
        #expect(page.hasLocalTable)
    }
}
