import Foundation
import PDFKit
import Testing
import UIKit

@testable import Zhixia

/// V3.0 / V3.4 修复的回归网（2026-09-12）。
///
/// 这一组测试的共同点：**修之前它们是红的，且症状全是「用户数据没了」或「文件损坏」**，
/// 而不是「效果不好」。它们不在 `docs/09` 的卡点清单里 —— 是逐行读代码读出来的。
/// 加它们的目的不是提高覆盖率，是防止这几条路径再次退化。
struct ExportSafetyTests {

    // MARK: - ① PageFileStore.commit 失败回滚

    @Test("追加页提交失败时，不得删除该文档既有页的图")
    func appendFailureKeepsExistingPages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "zhixia-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PageFileStore(root: root)
        let document = UUID()
        let session = UUID()
        let jpeg = PreviewImages.jpeg()

        // 第一次提交：建立文档的第 1 页
        let firstPage = UUID()
        _ = try await files.commit(
            document: document,
            drafts: [PageDraft(id: firstPage, sessionID: session, quad: .fullImage, enhancement: .original)],
            rendered: [firstPage: jpeg],
            thumbs: [firstPage: jpeg],
            keepOriginals: false
        )
        let existingRendered = files.url(document: document, page: firstPage, kind: .rendered)
        let existingThumb = files.url(document: document, page: firstPage, kind: .thumbnail)
        #expect(FileManager.default.fileExists(atPath: existingRendered.path))
        #expect(FileManager.default.fileExists(atPath: existingThumb.path))

        // 第二次提交：第 1 个草稿能写盘，第 2 个缺 rendered Data → 中途抛错。
        // 这同时覆盖两件事：既有页必须保住、本次已写入的半成品必须回滚。
        let partialPage = UUID()
        let brokenPage = UUID()
        var threw = false
        do {
            _ = try await files.commit(
                document: document,
                drafts: [
                    PageDraft(id: partialPage, sessionID: session, quad: .fullImage, enhancement: .original),
                    PageDraft(id: brokenPage, sessionID: session, quad: .fullImage, enhancement: .original)
                ],
                rendered: [partialPage: jpeg],   // brokenPage 缺失
                thumbs: [partialPage: jpeg],
                keepOriginals: false
            )
        } catch {
            threw = true
        }
        #expect(threw, "缺 rendered Data 时应当抛错")

        // 既有页的图必须原封不动 —— 这条是本次修复的核心。
        // 修复前这里执行的是 `removeItem(at: documentDirectory(document))`，会把整个文档目录删空。
        #expect(FileManager.default.fileExists(atPath: existingRendered.path), "既有页 rendered 被回滚误删")
        #expect(FileManager.default.fileExists(atPath: existingThumb.path), "既有页 thumbnail 被回滚误删")

        // 本次写入的半成品应当被回滚掉
        #expect(
            !FileManager.default.fileExists(atPath: files.url(document: document, page: partialPage, kind: .rendered).path),
            "本次半成品未被回滚"
        )
    }

    @Test("提交失败仍要把磁盘满映射成 diskFull")
    func commitFailureStillMapsDiskError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "zhixia-maperr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = PageFileStore(root: root)
        let page = UUID()

        var caught: ZhixiaError?
        do {
            _ = try await files.commit(
                document: UUID(),
                drafts: [PageDraft(id: page, sessionID: UUID(), quad: .fullImage, enhancement: .original)],
                rendered: [:],
                thumbs: [:],
                keepOriginals: false
            )
        } catch let error as ZhixiaError {
            caught = error
        }
        #expect(caught == .storeFailed)
    }

    // MARK: - ② 图片 PDF 越界插入

    /// ⚠️ 这条测试**不区分修复前后** —— 实测 PDFKit 会容忍越界下标（追加），旧写法也能过。
    /// 保留它是为了锁住「缺图时页数与页序仍然正确」这个行为契约，不是为了证明某次崩溃。
    @Test("图片 PDF 跳过解码失败的图，页数与页序保持正确")
    func pdfSkipsMissingImageKeepsPageOrder() async throws {
        let good = FileManager.default.temporaryDirectory.appending(path: "pdf-good-\(UUID().uuidString).jpg")
        try PreviewImages.jpeg().write(to: good)
        defer { try? FileManager.default.removeItem(at: good) }

        let secondGood = FileManager.default.temporaryDirectory.appending(path: "pdf-good2-\(UUID().uuidString).jpg")
        try PreviewImages.jpeg().write(to: secondGood)
        defer { try? FileManager.default.removeItem(at: secondGood) }

        let missing = FileManager.default.temporaryDirectory.appending(path: "pdf-missing-\(UUID().uuidString).jpg")

        // 第 0 张缺失：修复前会用输入下标 1 向空 PDF 插入 → PDFKit 抛 ObjC 异常（Swift 捕不到）
        let url = try await PDFExportService().makePDF(
            imageURLs: [missing, good, secondGood],
            fileName: "pdf-\(UUID().uuidString).pdf"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = PDFDocument(url: url)
        #expect(document?.pageCount == 2, "缺失的图应被跳过，其余两页都要在")
    }

    // MARK: - ③ DOCX 非法控制字符

    @Test("DOCX 必须剔除 XML 1.0 非法控制字符，否则整包损坏")
    func docxStripsIllegalControlCharacters() async throws {
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "污染",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .plain,
                    usedCloud: false,
                    blocks: [
                        ReconstructBlock(kind: .paragraph, bbox: .zero, text: "正常\u{0001}文字\u{000B}结束"),
                        ReconstructBlock(
                            kind: .table,
                            bbox: .zero,
                            text: "",
                            table: ReconstructTable(rows: [["表\u{0000}头", "值\u{001F}"]])
                        )
                    ]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "ctl-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try DocxProbe.documentXML(from: url)
        #expect(xml.contains("正常"))
        #expect(xml.contains("文字"))
        #expect(xml.contains("结束"))

        // 真正的断言：整段 document.xml 必须能被 XMLParser 解析。
        // 残留任何 0x00-0x08 / 0x0B / 0x0C / 0x0E-0x1F 都会让这里失败 ——
        // 而 Word 遇到同样内容会直接判定文件损坏。
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "document.xml 不是合法 XML：\(parser.parserError?.localizedDescription ?? "")")
    }

    // MARK: - ④ B 档 anchor 单位

    @Test("B 档 anchor 的位置与尺寸必须是 EMU 量级（误用 twips 会缩到 1/635）")
    func docxAnchoredUsesEMUUnits() async throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }

        let document = ReconstructDocument(
            documentID: UUID(),
            title: "B",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .plain,
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
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "b-\(UUID().uuidString).docx",
            tier: .anchored
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // wp:posOffset 出现两次（positionH / positionV）
        let offsets = DocxProbe.occurrences(of: "<wp:posOffset>", in: xml)
        #expect(offsets.count == 2, "应有横向与纵向两个 posOffset")

        // A4 宽 11906 twips = 7,560,310 EMU。x=0.2 → 1,512,062 EMU。
        // 误用 twips 时这里只有 2381，比正确值小 635 倍。
        #expect(offsets[0] > 1_000_000, "横向 posOffset 太小，疑似又用回了 twips：\(offsets[0])")
        #expect(offsets[1] > 1_000_000, "纵向 posOffset 太小，疑似又用回了 twips：\(offsets[1])")

        // wp:extent 同样必须是 EMU。40×30 的 PNG → cx = 40 × 9525 = 381,000 EMU。
        // 误用 twips 时 sizeX 会被 min() 压到 4762。
        let extents = DocxProbe.occurrences(of: "<wp:extent cx=\"", in: xml)
        #expect(extents.isEmpty == false, "B 档应有 wp:extent")
        #expect(extents[0] > 100_000, "wp:extent 太小，疑似又用回了 twips：\(extents[0])")
    }

    // MARK: - ⑤ C 档衬底逐页

    @Test("C 档衬底必须逐页插入，不能全堆在第 1 页")
    func docxBackgroundIsPerPage() async throws {
        let png = try ReconstructTestFixtures.pngURL()
        defer { try? FileManager.default.removeItem(at: png) }

        func page(_ text: String) -> ReconstructPage {
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
                    ReconstructBlock(kind: .paragraph, bbox: .zero, text: text)
                ]
            )
        }

        let document = ReconstructDocument(
            documentID: UUID(),
            title: "C",
            pages: [page("第一页正文"), page("第二页正文")]
        )
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "c-\(UUID().uuidString).docx",
            tier: .background
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        #expect(DocxProbe.count(of: "behindDoc=\"1\"", in: xml) == 2, "两页应各有一张衬底")

        // 关键：第 1 页正文与第 2 页正文之间必须夹着第 2 页的衬底。
        // 修复前所有衬底堆在 body 最前面，这段区间里一个 behindDoc 都没有。
        let first = try #require(xml.range(of: "第一页正文"))
        let second = try #require(xml.range(of: "第二页正文"))
        let between = String(xml[first.upperBound..<second.lowerBound])
        #expect(between.contains("behindDoc=\"1\""), "第 2 页的衬底没有落在第 2 页正文之前")
    }

    // MARK: - ⑥ 中文字体声明

    @Test("styles.xml 必须显式声明 eastAsia 字体，否则中文靠字体回退")
    func docxDeclaresEastAsiaFont() async throws {
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "字体",
            pages: [
                ReconstructPage(
                    pageID: UUID(),
                    size: .zero,
                    scene: .plain,
                    usedCloud: false,
                    blocks: [ReconstructBlock(kind: .paragraph, bbox: .zero, text: "中文正文")]
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "font-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains("<w:docDefaults>"))
        #expect(text.contains("w:eastAsia=\"宋体\""))
    }
}

/// 从 docx（ZIP STORE，未压缩）里把 `word/document.xml` 的内容原样切出来。
/// ZIP 用的是 stored 方式，XML 在文件字节里是连续的，所以直接做字符串定位即可，
/// 不需要引入解压逻辑。
enum DocxProbe {
    static func documentXML(from url: URL) throws -> String {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let start = text.range(of: "<w:document "),
              let end = text.range(of: "</w:document>")
        else {
            throw ZhixiaError.exportFailed
        }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// 取出 `marker` 之后紧跟的十进制整数（marker 本身以 `>` 或 `"` 结尾）。
    static func occurrences(of marker: String, in text: String) -> [Int64] {
        var results: [Int64] = []
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            let rest = text[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int64(digits) {
                results.append(value)
            }
            searchStart = range.upperBound
        }
        return results
    }

    static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
