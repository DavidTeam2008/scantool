import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// T009（spec/scan-fidelity US1 / FR-002）：行级排版度量的契约测试。
///
/// 覆盖对象（T003/T006/T007 的落地验证）：
/// - `LayoutTypography.lineFontPT`：行级字号 = 行实测高 × 页高 × 1.05 钳制，
///   与块级 `fontPT(for:)` 同式但基准换成该行——异构行高块每行一档（叠字根因
///   「整块一个字号」的修复核心）；
/// - `LayoutTypography.estimatedRenderHeight`：换行估算基准行级化（T006）——
///   估算与渲染同字号，异构块不再系统性误判换行；
/// - `LayoutTypography.gapPlaceholderSpaces`：空隙占位阈值两侧与换算边界
///   （T012/T013 共用）；
/// - `DocxExportService` 行段逐行 `w:sz`（T007）端到端：异构两行在 document.xml
///   里各自成档，且每行字号 ≤ 行槽 × 1.05 + 半点量化容差（exact 行距下字号
///   超过行槽即上行裁切下行——叠字）。
struct LineTypographyPerLineTests {

    // MARK: - lineFontPT 行级换算

    @Test("lineFontPT 逐行换算：字号 = 行槽 × 1.05 钳制，异构行高块每行一档")
    func lineFontPTDerivesPerLine() {
        let pageHeightPT = 600.0
        let tallLine = BlockLine(text: "标题行", height: 0.030, gapToPrevious: 0, leadingOffset: 0, width: 0.3)
        let shortLine = BlockLine(text: "正文行", height: 0.020, gapToPrevious: 0.01, leadingOffset: 0, width: 0.25)
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.1),
            text: "标题行\n正文行",
            lines: [tallLine, shortLine],
            measuredLineHeight: 0.030
        )

        let tall = LayoutTypography.lineFontPT(line: tallLine, block: block, pageHeightPT: pageHeightPT)
        let short = LayoutTypography.lineFontPT(line: shortLine, block: block, pageHeightPT: pageHeightPT)

        // 行槽（pt）= 行高 × 页高：0.030×600 = 18、0.020×600 = 12
        // 字号 = 槽 × 1.05：18.9 / 12.6（均未触钳制）
        #expect(abs(tall - 18.9) < 1e-9, "高行应为 0.030×600×1.05 = 18.9pt，实际 \(tall)")
        #expect(abs(short - 12.6) < 1e-9, "矮行应为 0.020×600×1.05 = 12.6pt，实际 \(short)")
        // 关键区分性：同一块内两行字号必须不同（旧块级路径两者同为 18.9——
        // 矮行字号比自身行槽大 58%，exact 行距下即叠字）
        #expect(tall > short, "行级字号必须随行高分化")

        // 性质（FR-002 不变量）：字号 ≤ max(下限, 行槽 × 1.05) + ε
        // ——未触钳制时恰好贴槽比例；触下限时 = 7 不超；触上限时 = 28 < 槽比例。
        for line in [tallLine, shortLine] {
            let font = LayoutTypography.lineFontPT(line: line, block: block, pageHeightPT: pageHeightPT)
            let slot = line.height * pageHeightPT
            #expect(
                font <= max(LayoutTypography.minFontPT, slot * LayoutTypography.absorption) + 1e-9,
                "字号不得超过行槽 × 1.05（行槽 \(slot)pt，字号 \(font)pt）"
            )
            #expect(font >= LayoutTypography.minFontPT && font <= LayoutTypography.maxFontPT)
        }

        // 钳制两侧：极小行高 → 7pt 下限；极大行高 → 28pt 上限
        let tiny = BlockLine(text: "微", height: 0.005, gapToPrevious: 0, leadingOffset: 0, width: 0.1)
        let huge = BlockLine(text: "巨", height: 0.060, gapToPrevious: 0, leadingOffset: 0, width: 0.1)
        #expect(LayoutTypography.lineFontPT(line: tiny, block: block, pageHeightPT: pageHeightPT) == 7)
        #expect(LayoutTypography.lineFontPT(line: huge, block: block, pageHeightPT: pageHeightPT) == 28)
    }

    @Test("lineFontPT 退化回退：行高 ≤ 0 走块级实测，页高非法走 7pt 下限")
    func lineFontPTDegenerateFallback() {
        let synthetic = BlockLine(text: "合成行", height: 0, gapToPrevious: 0, leadingOffset: 0, width: 0)
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.1),
            text: "合成行",
            lines: [synthetic],
            measuredLineHeight: 0.018
        )
        // 行高 0（引擎合成行）→ 块级实测：0.018×600×1.05 = 11.34pt（同源不产生第二套语义）
        let expectedBlockLevel = 0.018 * 600 * LayoutTypography.absorption
        #expect(
            abs(LayoutTypography.lineFontPT(line: synthetic, block: block, pageHeightPT: 600) - expectedBlockLevel) < 1e-9
        )
        // 负行高同路径
        let negative = BlockLine(text: "负", height: -0.01, gapToPrevious: 0, leadingOffset: 0, width: 0)
        #expect(
            abs(LayoutTypography.lineFontPT(line: negative, block: block, pageHeightPT: 600) - expectedBlockLevel) < 1e-9
        )
        // 页高退化 → 块级兜底链 → 7pt 下限（不产生 NaN / 0）
        #expect(LayoutTypography.lineFontPT(line: synthetic, block: block, pageHeightPT: 0) == 7)
    }

    // MARK: - estimatedRenderHeight 行级基准（T006）

    @Test("estimatedRenderHeight 行级基准：异构块换行估算与逐行渲染同字号")
    func estimatedRenderHeightUsesPerLineBase() {
        // 块宽 300.15pt（0.667×450），页高 600pt，块级字号 18.9pt（高行实测）。
        // 正文行 18 个全角字：行级基准 12.6pt → 估算宽 18×12.6×1.05 = 238.1pt
        // ≤ 300.15 → 1 行，pitch 12pt → 总高 18 + 12 = 30pt。
        // 旧块级基准 18.9pt → 18×18.9×1.05 > 300.15 → 误判 2 行 → 总高 42pt。
        // （渲染端该行实际用 12.6pt 单行放得下——旧估算系统性虚高 40%。）
        let tallLine = BlockLine(text: "标题行", height: 0.030, gapToPrevious: 0, leadingOffset: 0, width: 0.3)
        let shortLine = BlockLine(
            text: String(repeating: "正", count: 18),
            height: 0.020,
            gapToPrevious: 0,
            leadingOffset: 0,
            width: 0.6
        )
        let total = LayoutTypography.estimatedRenderHeight(
            lines: [tallLine, shortLine],
            blockWidth: 0.667,
            pageWidthPT: 450,
            pageHeightPT: 600,
            baseFontPT: 18.9
        )
        #expect(abs(total - 30) < 1e-6, "行级基准估算应为 30pt（旧块级基准为 42pt），实际 \(total)")

        // 合成行（height = 0）路径零扰动：行级基准回退调用方 baseFontPT——
        // 15 字 × 18.9 × 1.05 = 297.7 ≤ 300.15 → 1 行，pitch = 18.9×1.2 = 22.68。
        let synthetic = BlockLine(
            text: String(repeating: "合", count: 15),
            height: 0,
            gapToPrevious: 0,
            leadingOffset: 0,
            width: 0.6
        )
        let fallbackTotal = LayoutTypography.estimatedRenderHeight(
            lines: [synthetic],
            blockWidth: 0.667,
            pageWidthPT: 450,
            pageHeightPT: 600,
            baseFontPT: 18.9
        )
        #expect(abs(fallbackTotal - 22.68) < 1e-6, "合成行必须继续用块级 baseFontPT，实际 \(fallbackTotal)")
    }

    // MARK: - gapPlaceholderSpaces 阈值与换算（T003）

    @Test("gapPlaceholderSpaces：0.6 字符宽阈值两侧 + round(空隙÷0.25字号) 钳 [2, 60]")
    func gapPlaceholderSpacesThresholds() {
        // fontPT 12 → 字符宽 0.6×12 = 7.2pt → 阈值 4.32pt = 0.0096 归一化（页宽 450pt）
        #expect(
            LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0.005, fontPT: 12, pageWidthPT: 450) == nil,
            "低于 0.6 字符宽 → nil（普通空格连接）"
        )
        #expect(
            LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0.0097, fontPT: 12, pageWidthPT: 450) == 2,
            "刚过阈值 round(4.365÷3)=1 → 钳下限 2"
        )
        #expect(
            LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0.05, fontPT: 12, pageWidthPT: 450) == 8,
            "22.5pt ÷ 3 = 7.5 → round 8"
        )
        #expect(
            LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 1.0, fontPT: 12, pageWidthPT: 450) == 60,
            "巨大空隙钳上限 60"
        )
        // 退化输入 → nil（不产生 NaN / 0 占位）
        #expect(LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0, fontPT: 12, pageWidthPT: 450) == nil)
        #expect(LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: -0.01, fontPT: 12, pageWidthPT: 450) == nil)
        #expect(LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0.05, fontPT: 0, pageWidthPT: 450) == nil)
        #expect(LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: 0.05, fontPT: 12, pageWidthPT: 0) == nil)
    }

    // MARK: - DOCX 逐行 w:sz 端到端（T007）

    @Test("DOCX 行段逐行 w:sz：异构行高块每行一档，字号 ≤ 行槽 × 1.05 + 量化容差")
    func docxEmitsPerLineFontSize() async throws {
        // 400×800px 页 → 页高 600pt、页宽 6000 dxa。异构两行（块级实测 0.030）：
        // L1 h0.030 → 18.9pt → w:sz 38、w:line 360 exact
        // L2 h0.020 → 12.6pt → w:sz 25、w:line 240 exact
        // 旧块级路径两行同为 38：L2 字号 19pt > 行槽 12pt × 1.05 —— exact 行距下
        // 上行 descender 裁进本行（叠字根因 2/6）。行级化后每行与自身行槽同源。
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1),
            text: "高大标题行\n矮小正文行",
            lines: [
                BlockLine(text: "高大标题行", height: 0.030, gapToPrevious: 0, leadingOffset: 0, width: 0.3),
                BlockLine(text: "矮小正文行", height: 0.020, gapToPrevious: 0.01, leadingOffset: 0.02, width: 0.25),
            ],
            measuredLineHeight: 0.030
        )
        let document = ReconstructDocument(documentID: UUID(), title: "行级字号", pages: [
            ReconstructPage(
                pageID: UUID(),
                size: CGSize(width: 400, height: 800),
                scene: .plain,
                usedCloud: false,
                blocks: [block]
            )
        ])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "per-line-font-\(UUID().uuidString).docx",
            tier: .restored
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        let tallHalf = try #require(nearestAttribute(in: xml, before: "高大标题行", pattern: "w:sz w:val=\"(\\d+)\""))
        let shortHalf = try #require(nearestAttribute(in: xml, before: "矮小正文行", pattern: "w:sz w:val=\"(\\d+)\""))
        let tallLineTwips = try #require(nearestAttribute(in: xml, before: "高大标题行", pattern: "w:line=\"(\\d+)\""))
        let shortLineTwips = try #require(nearestAttribute(in: xml, before: "矮小正文行", pattern: "w:line=\"(\\d+)\""))

        // 每行一档：L1 38 / L2 25（半磅），必须不同（旧路径同为 38）
        #expect(tallHalf == 38, "L1 字号应 18.9pt → 38 半磅，实际 \(tallHalf)")
        #expect(shortHalf == 25, "L2 字号应 12.6pt → 25 半磅，实际 \(shortHalf)")
        #expect(tallHalf != shortHalf, "异构行高必须逐行分化字号（叠字修复的存在性断言）")
        // 行距 exact 保真：实测行高 × 20 twips
        #expect(tallLineTwips == 360, "L1 w:line 应 0.030×600×20 = 360，实际 \(tallLineTwips)")
        #expect(shortLineTwips == 240, "L2 w:line 应 0.020×600×20 = 240，实际 \(shortLineTwips)")
        // 性质（FR-002 核心不变量）：字号 ≤ 行槽 × 1.05 + 半点量化容差
        // （行槽 pt = w:line ÷ 20；+0.26 = 0.25 半点量化 + 舍入余量）
        #expect(
            Double(tallHalf) / 2 <= Double(tallLineTwips) * LayoutTypography.absorption / 20 + 0.26,
            "L1 字号 \(Double(tallHalf) / 2)pt 超出行槽 \(Double(tallLineTwips) / 20)pt × 1.05"
        )
        #expect(
            Double(shortHalf) / 2 <= Double(shortLineTwips) * LayoutTypography.absorption / 20 + 0.26,
            "L2 字号 \(Double(shortHalf) / 2)pt 超出行槽 \(Double(shortLineTwips) / 20)pt × 1.05"
        )
        // 行首偏移保真：L2 leadingOffset 0.02 × 6000 dxa = 120
        #expect(xml.contains(#"<w:ind w:left="120"/>"#), "L2 行首偏移应 0.02×6000 = 120 dxa")
    }

    // MARK: - 辅助

    /// 从含 `text` 的 run 位置向前找最近一次 `pattern` 捕获的十进制整数。
    /// 行段结构固定为 `spacing(w:line) → ind → rPr(w:sz) → w:t`，向前最近命中
    /// 即该 run 自己的属性（与 DocxRestoredLayoutTests.fontSizeHalfPoints 同型）。
    /// `w:szCs` / `w:lineRule` 不会被误匹配（模式要求 sz/line 后紧跟 `="`）。
    private func nearestAttribute(in xml: String, before text: String, pattern: String) -> Int? {
        let needle = "<w:t xml:space=\"preserve\">\(text)</w:t>"
        guard let textRange = xml.range(of: needle) else { return nil }
        let head = String(xml[xml.startIndex..<textRange.lowerBound])
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard
            let match = regex.matches(in: head, range: NSRange(head.startIndex..., in: head)).last,
            match.numberOfRanges > 1,
            let numberRange = Range(match.range(at: 1), in: head)
        else { return nil }
        return Int(head[numberRange])
    }
}
