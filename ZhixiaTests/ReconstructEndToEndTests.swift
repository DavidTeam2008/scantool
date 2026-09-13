import Foundation
import Testing

@testable import Zhixia

/// V3.3 端到端断言：**图片 → parse → docx**，断言产物里真的存在 `w:tbl`。
///
/// 为什么必须补这一层（docs/09 §7 的 P3-2）：以前的断言全停在单元级
/// ——「表格检测器返回了什么」。链路中间任何一环断了（检测器返回了、但 parser 没往块里放、
/// 或 docx 没把它写成表），**测试照样全绿**。docs/09 §6.2 那笔「测试全绿 ≠ 真机能用」的账，
/// 一半就欠在这一层上。
///
/// 这一组从真实样张图片出发，一路走到真实 `.docx` 字节。
struct ReconstructEndToEndTests {

    // MARK: - 结构化通路（iOS 26，本次新增）

    /// **本次改造的头号验证**：iOS 26 的 `RecognizeDocumentsRequest` 让真机表格
    /// 第一次有了行列结构，这一条从真实样张图一路断言到 `.docx` 里的 `w:tbl`。
    ///
    /// 实测数据（2026-09-12，iPhone 17 模拟器 + `docs/fixtures/images/nutrition-mango.jpg`）：
    /// 识别出 **1 张 7 行 × 3 列**的表，行切分完全正确
    /// （`["能量", "1429千焦", "17%"]`），连真机丢失的「营养成分表」表头都恢复了。
    /// 对照：几何通路在同一张图上靠「按 OCR 行 midX 聚类推列」，这是它在真机上做不到的事。
    ///
    /// ⚠️ 模拟器 ≠ 真机，Vision 的识别质量理论上可能不同；但**结构识别**这件事
    /// （表格 → 行列）不依赖像素级细节，这里验证的正是结构。
    @Test("端到端：结构化通路必须产出带 w:tbl 的 DOCX")
    func structuredPathProducesTableInDocx() async throws {
        guard #available(iOS 26.0, *) else {
            // iOS 18~25 上根本没有 `RecognizeDocumentsRequest`，这条通路不存在。
            // 不是失败，是「这个系统上没有它」—— 老系统的兜底由下一条几何通路测试守卫。
            return
        }
        let image = try ReconstructSampleImage.nutritionMango()

        let parser = OnDeviceDocumentParser(
            recognizer: FixedRecognizer(lines: []),
            structureRecognizer: VisionDocumentStructureRecognizer()
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)

        let tables = page.blocks.filter { $0.kind == .table }
        try #require(tables.count >= 1, "结构化通路没有产出表格")
        let grid = try #require(tables.first?.table?.rows)

        // 结构断言：至少 6 行 × 3 列，且数值落在正确的列里。
        #expect(grid.count >= 6, "行数不足：\(grid.count)")
        #expect(grid.map(\.count).allSatisfy { $0 >= 3 }, "列数不足：\(grid.map(\.count))")
        #expect(
            grid.contains { row in row.contains { $0.contains("1429") } },
            "没找到能量行：\(grid)"
        )
        // 几何通路做不到的那一点：单元格必须被拆开，而不是整行糊成一段。
        #expect(
            grid.contains { row in row.contains { $0.contains("NRV") } },
            "表头行没有被拆成独立单元格：\(grid)"
        )

        // 链路断言：整个文档必须真的被写成 `w:tbl`。
        let document = ReconstructDocument(documentID: UUID(), title: "营养表", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "e2e-structured-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        #expect(xml.contains("<w:tbl>"), "DOCX 里没有 w:tbl —— 整张表塌成了段落")
        #expect(DocxProbe.count(of: "<w:tr>", in: xml) >= 6, "表格行数不足")
    }

    // MARK: - 几何通路（iOS 18~25 的兜底）

    /// 老系统走的是 Vision OCR + 几何聚类。用**固化的真实样张 OCR**（确定性）
    /// 走「解析 → 导出」这一段，保证兜底通路在链路级别也仍然出表。
    @Test("端到端：几何兜底通路也必须产出带 w:tbl 的 DOCX")
    func geometricPathProducesTableInDocx() async throws {
        let image = try ReconstructSampleImage.nutritionMango()
        let fixture = ReconstructV2Fixtures.nutritionMango

        let parser = OnDeviceDocumentParser(recognizer: FixedRecognizer(lines: fixture.lines))
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: fixture.expectedScene)

        let tables = page.blocks.filter { $0.kind == .table }
        try #require(tables.count >= 1, "几何兜底通路没有产出表格（样张夹具）")

        let document = ReconstructDocument(documentID: UUID(), title: "营养表", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "e2e-geometric-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        #expect(xml.contains("<w:tbl>"), "几何兜底通路的 DOCX 里没有 w:tbl")
    }

    // MARK: - 真机输入（当前仍失败的诚实断言）

    /// 真机实拍反解出来的 OCR（docs/08 §2.3）。
    ///
    /// ⚠️ **保真度说明**：这里固化的**文本是真实反解结果**（逐字照抄 docs/08），
    /// 但 **bbox 是重建的** —— 原始测量只留下了「x 跨度 0.082~0.25，占页宽 17%」
    /// 和从上到下的视觉顺序（真机仪器记录没有逐行坐标）。
    /// 所以它能守住「真机这种输入长什么样」，但不能当成精确的几何基准。
    @Test("端到端：真机 OCR 输入在几何通路上仍然出不了表（已知问题）")
    func realDeviceOcrStillLacksTable() async throws {
        let image = try ReconstructSampleImage.nutritionMango()
        let parser = OnDeviceDocumentParser(recognizer: FixedRecognizer(lines: RealDeviceOCR.nutritionLines))

        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .auto)
        let tables = page.blocks.filter { $0.kind == .table }

        // 这一条**当前应当失败** —— 它记录的是 docs/08 §3 的 R2/R3 根因还没在几何通路上解决。
        // 用 withKnownIssue 包住：命中时日志是 `recorded an expected failure`（不是 passed），
        // 一旦哪天几何通路也能出表了，它会**反向失败**提醒我们删掉这层包装。
        withKnownIssue("真机 OCR 把整行单元格合并成一个 line，几何通路无法拆列 → w:tbl = 0") {
            #expect(
                tables.isEmpty == false,
                "真机几何通路仍然出不了表（行数 \(page.blocks.count)）"
            )
        }
    }
}

// MARK: - 支撑

enum ReconstructSampleImage {
    /// 从仓库根定位样张原图。测试跑在模拟器里，宿主机文件系统可读。
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZhixiaTests/
            .deletingLastPathComponent()   // 仓库根
            .appending(path: "docs/fixtures/images/\(name)")
    }

    static func nutritionMango() throws -> URL {
        try #require(FileManager.default.fileExists(atPath: url("nutrition-mango.jpg").path))
        return url("nutrition-mango.jpg")
    }
}

/// 返回固定 OCR 结果的替身 —— 让「解析 → 导出」这段完全确定，不依赖模拟器的 Vision 质量。
private struct FixedRecognizer: TextRecognizing {
    let lines: [OCRLine]
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: lines)
    }
}

/// 真机反解出来的 OCR（docs/08 §2.3）。
enum RealDeviceOCR {
    /// 文本逐字照抄 docs/08 §2.3 的「视觉行从上到下」；
    /// bbox 按「x 跨度 0.082~0.25、行高约 0.03、自上而下」重建（见上面的保真度说明）。
    static var nutritionLines: [OCRLine] {
        let texts = [
            "项目每100克NRV%",
            "能量1429千焦",
            "17%蛋白",
            "质1.5克3%脂肪0.8",
            "克碳水化",
            "合物8.8克2",
            "7%"
        ]
        let top: CGFloat = 0.62
        return texts.enumerated().map { index, text in
            OCRLine(
                text: text,
                boundingBox: CGRect(
                    x: 0.082,
                    y: top - CGFloat(index) * 0.035,
                    width: 0.168,
                    height: 0.028
                )
            )
        }
    }
}
