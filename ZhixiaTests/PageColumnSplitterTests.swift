import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// 分栏切分 + 按栏排阅读序（2026-09-12 真机反馈）。
///
/// 用户现象：一本**左右两栏**的教材拍下来做「还原」，导出的 Word / PDF 里
/// 左栏和右栏**逐行交错** —— 左栏第 4 题的后半句和右栏第 2 段拼在一起。
///
/// 根因：`OnDeviceReadingOrder` 的段落聚类与 `OnDeviceDocumentParser` 的最终排序
/// 都假设页面是单栏的。
struct PageColumnSplitterTests {

    /// 造一条 OCR 行。x 用页面归一化坐标，y 是 Vision 语义（越大越靠上）。
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.36) -> OCRLine {
        OCRLine(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: 0.03))
    }

    /// 模拟一页左右两栏的教材：左栏 x≈0.06 起，右栏 x≈0.52 起，中间是 gutter。
    private func twoColumnPage() -> [OCRLine] {
        let left = [
            "1 Complete the dialogues with the correct past simple form",
            "of the verbs in the box. You need to use some of the verbs",
            "more than once. do earn go have make meet spend take",
            "A: Yesterday I three hours doing those physics exercises"
        ]
        let right = [
            "3 Complete the text with the past simple or past continuous",
            "form of the verbs in brackets. A terrible trip it was",
            "On the day of the school trip I wake up as usual at 8",
            "o'clock to go to school. I leave the house when I realised"
        ]
        var lines: [OCRLine] = []
        for (index, text) in left.enumerated() {
            lines.append(line(text, x: 0.06, y: 0.86 - CGFloat(index) * 0.06))
        }
        for (index, text) in right.enumerated() {
            lines.append(line(text, x: 0.52, y: 0.86 - CGFloat(index) * 0.06))
        }
        return lines
    }

    // MARK: - 切分器

    @Test("两栏页面被切成左右两栏，行不丢不重")
    func splitsTwoColumns() {
        let lines = twoColumnPage()
        let columns = PageColumnSplitter.split(lines)

        #expect(columns.count == 2)
        // **无损**是最重要的性质：每一行都要落进恰好一栏，否则内容会静默消失。
        #expect(columns.flatMap(\.lines).count == lines.count)

        let left = columns[0], right = columns[1]
        #expect(left.xRange.upperBound < right.xRange.lowerBound, "两栏的 x 范围不该重叠")
        #expect(left.lines.allSatisfy { $0.boundingBox.midX < 0.4 })
        #expect(right.lines.allSatisfy { $0.boundingBox.midX > 0.4 })
    }

    @Test("单栏页面原样返回一栏（单栏行为必须与改动前一致）")
    func singleColumnStaysSingle() {
        let lines = (0..<8).map { index in
            line("这是第 \(index) 行正文内容，用来验证单栏不会被切开", x: 0.08, y: 0.86 - CGFloat(index) * 0.06)
        }
        let columns = PageColumnSplitter.split(lines)
        #expect(columns.count == 1)
        #expect(columns[0].lines.count == lines.count)
    }

    @Test("行数太少不切栏，避免被一行超长标题切成两半")
    func tooFewLinesStaysSingle() {
        let lines = [
            line("短标题", x: 0.1, y: 0.8),
            line("另一行", x: 0.6, y: 0.7),
            line("第三行", x: 0.2, y: 0.6)
        ]
        #expect(PageColumnSplitter.split(lines).count == 1)
    }

    @Test("只有页边留白造成的空带时不算分栏")
    func edgeWhitespaceIsNotAGutter() {
        // 所有行都挤在右半边，左边的空是「页边」而不是「栏沟」
        let lines = (0..<10).map { index in
            line("正文内容正文内容正文内容正文内容", x: 0.55, y: 0.9 - CGFloat(index) * 0.06, width: 0.3)
        }
        #expect(PageColumnSplitter.split(lines).count == 1)
    }

    @Test("空输入不崩")
    func emptyInput() {
        let columns = PageColumnSplitter.split([])
        #expect(columns.count == 1)
        #expect(columns[0].lines.isEmpty)
    }

    // MARK: - 端到端：按栏排阅读序

    /// 这条直接对应用户看到的现象：左栏的内容必须整段出现在右栏之前，
    /// 且**不能有任何一个块同时含有两栏的文字**（那正是「逐行交错」的形态）。
    @Test("双栏页面：左栏必须整段排在右栏之前，且块不得跨栏")
    func blocksAreOrderedByColumn() async throws {
        let parser = OnDeviceDocumentParser(recognizer: TwoColumnRecognizer(lines: twoColumnPage()))
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .plain)

        let text = page.blocks.map(\.text).joined(separator: "\n")
        let left = try #require(text.range(of: "1 Complete the dialogues"))
        let right = try #require(text.range(of: "3 Complete the text"))
        #expect(left.lowerBound < right.lowerBound, "右栏内容排到了左栏前面：\n\(text)")

        // 跨栏合并 = 同一个块里既有左栏句子又有右栏句子
        let leftMarker = "more than once"
        let rightMarker = "A terrible trip"
        for block in page.blocks {
            let hasLeft = block.text.contains(leftMarker)
            let hasRight = block.text.contains(rightMarker)
            #expect(!(hasLeft && hasRight), "左栏与右栏的文字被合进了同一个块：\(block.text)")
        }
    }

    @Test("单栏页面：块顺序与改动前一致（按 y 从上到下）")
    func singleColumnOrderIsUnchanged() async throws {
        let lines = [
            line("第一段的内容比较长，用来避免被当成页眉丢掉", x: 0.08, y: 0.86, width: 0.8),
            line("第二段的内容同样很长，继续往下排", x: 0.08, y: 0.70, width: 0.8),
            line("第三段的内容，收尾用", x: 0.08, y: 0.54, width: 0.8)
        ]
        let parser = OnDeviceDocumentParser(recognizer: TwoColumnRecognizer(lines: lines))
        let page = try await parser.parse(imageURL: URL(fileURLWithPath: "/dev/null"), pageID: UUID(), scene: .plain)

        let texts = page.blocks.map(\.text)
        #expect(texts.count == 3)
        #expect(texts[0].contains("第一段"))
        #expect(texts[1].contains("第二段"))
        #expect(texts[2].contains("第三段"))
    }
}

/// 返回固定 OCR 结果的替身（本文件私有，避免和其它测试文件的替身重名）。
private struct TwoColumnRecognizer: TextRecognizing {
    let lines: [OCRLine]
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: lines)
    }
}
