import Foundation
import Testing
import UIKit

@testable import Zhixia

/// US4（spec/layout-restore · FR-009 / plan D7）：`.restored` 档 DOCX 的 OOXML 结构契约。
///
/// 版面还原档的 Word 结构（与 LayoutCanvas 预览同构）：
/// - 每页独立 `sectPr`，页面宽高比随原图（映射退化为纯线性缩放）；
/// - **净化底图**内联衬底（擦除已烘进底图像素），引用 `baseImageRelativePath`；
/// - 文本块浮动文本框（`wps:txbx`），内含**真实段落**（可编辑，FR-007）；
/// - figure/barcode/artwork 复用**同一张净化底图** + `a:srcRect` 裁剪（每页 media 单图，FR-010）；
/// - EMU 定位与 Vision y 翻转全部经 `PageLayoutMapper`（posOffset 误用 twips 的旧事故不再重演）。
///
/// 这组测试改的是「Word 打开是否同构」——断言全部对着 document.xml 的具体数值，
/// 不是「导出不报错」级别的烟测。
struct DocxRestoredLayoutTests {

    // MARK: - sectPr（动态页面尺寸 / 多页 section）

    @Test("每页独立 sectPr，页面宽高比随原图")
    func perPageSectPrFollowsImageAspect() async throws {
        let document = ReconstructDocument(documentID: UUID(), title: "双页", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [textBlock("第一页")]),
            makePage(size: CGSize(width: 800, height: 400), blocks: [textBlock("第二页")])
        ])
        let url = try await export(document, name: "sect")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 每页一个 sectPr（400×800px @96dpi → 6000×12000 twips；第二页横过来）
        #expect(DocxProbe.count(of: "<w:sectPr>", in: xml) == 2)
        #expect(xml.contains(#"w:w="6000" w:h="12000""#), "第一页尺寸应随原图 400×800")
        #expect(xml.contains(#"w:w="12000" w:h="6000""#), "第二页尺寸应随原图 800×400")
        // 第 1 页的 sectPr 在分节段落里；body 级 sectPr 只属于最后一页
        #expect(DocxProbe.count(of: "</w:sectPr></w:pPr>", in: xml) == 1, "非末页必须用分节段落断节")
        // 页序正确：第一页的尺寸先出现
        let firstPage = try #require(xml.range(of: #"w:w="6000" w:h="12000""#))
        let secondPage = try #require(xml.range(of: #"w:w="12000" w:h="6000""#))
        #expect(firstPage.lowerBound < secondPage.lowerBound)
    }

    @Test("单页文档不分节（无分节段落）")
    func singlePageHasNoSectionBreak() async throws {
        let document = ReconstructDocument(documentID: UUID(), title: "单页", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [textBlock("唯一一页")])
        ])
        let url = try await export(document, name: "single")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        #expect(DocxProbe.count(of: "<w:sectPr>", in: xml) == 1)
        #expect(DocxProbe.count(of: "</w:sectPr></w:pPr>", in: xml) == 0, "单页无需分节段落")
    }

    // MARK: - 净化底图（内联 / 每页单图）

    @Test("净化底图内联逐页归属，每页恰好一张 media")
    func baseImageInlineSingleMediaPerPage() async throws {
        let base1 = try RestoredBaseImage.writeWhite(width: 400, height: 800)
        let base2 = try RestoredBaseImage.writeWhite(width: 800, height: 400)
        defer {
            try? FileManager.default.removeItem(at: base1)
            try? FileManager.default.removeItem(at: base2)
        }
        let document = ReconstructDocument(documentID: UUID(), title: "底座", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [textBlock("第一页")], baseURL: base1),
            makePage(size: CGSize(width: 800, height: 400), blocks: [textBlock("第二页")], baseURL: base2)
        ])
        let url = try await export(document, name: "base")
        defer { try? FileManager.default.removeItem(at: url) }

        // 每页恰好一张底图 media（净化底图统一编码 JPEG，Content Types 得能认）
        let entries = MiniZip.entries(from: try Data(contentsOf: url))
        let media = entries.keys.filter { $0.hasPrefix("word/media/") }
        #expect(media.count == 2, "每页一张底图：\(media)")
        #expect(media.allSatisfy { $0.hasSuffix(".jpg") }, "净化底图应为 JPEG：\(media)")

        let xml = try DocxProbe.documentXML(from: url)
        // 每页一个内联底图（旧 C 档把多页衬底全堆第 1 页的事故不许重演）；
        // 锚定图在部分宿主渲染器不落图（docs/17 §2.2）→ 底图必须内联，不得再有
        // anchored BaseImage。
        #expect(inlineBaseCount(in: xml) == 2)
        #expect(anchoredBaseCount(in: xml) == 0, "净化底图必须是内联图（锚定图宿主不画）")
        // 衬底铺满动态页：400×800px → 3_810_000×7_620_000 EMU；第二页横过来
        #expect(xml.contains(#"cx="3810000" cy="7620000""#))
        #expect(xml.contains(#"cx="7620000" cy="3810000""#))
        // 两条页图关系各自独立
        let rels = String(decoding: entries["word/_rels/document.xml.rels"] ?? Data(), as: UTF8.self)
        #expect(DocxProbe.count(of: "relationships/image", in: rels) == 2)
    }

    // MARK: - 浮动文本框（可编辑 / EMU 定位）

    @Test("文本块进浮动文本框：EMU 定位 + 可编辑段落")
    func textBlocksBecomeEditableTextBoxes() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "文本框", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [textBlock("可编辑正文")],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "txbx")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 浮动文本框存在，内含真实段落（FR-007 文字可编辑）
        #expect(xml.contains("<wps:txbx>"))
        #expect(DocxProbe.count(of: "<w:txbxContent>", in: xml) == 1)
        #expect(xml.contains("可编辑正文"))
        // wps 命名空间必须声明，否则 Word 无法解析文本框
        #expect(xml.contains("xmlns:wps="))

        // EMU 定位（posOffset 用 EMU，y 翻转经 PageLayoutMapper）：
        // bbox (0.1, 0.7, 0.5, 0.1) @ 400×800px 页
        // 基础 posH = 0.1 × 3_810_000 = 381000；再叠加 WPS 文本校准偏移
        // （LayoutTypography.restoredTextHorizontalOffsetRatio）；
        // 基础 posV = (1 − 0.8) × 7_620_000 = 1524000，再减去垂直校准。
        let calibrationX = Int((3_810_000 * LayoutTypography.restoredTextHorizontalOffsetRatio).rounded())
        let calibrationY = Int((7_620_000 * LayoutTypography.restoredTextVerticalLiftRatio).rounded())
        #expect(xml.contains("<wp:posOffset>\(381000 + calibrationX)</wp:posOffset>"))
        #expect(xml.contains("<wp:posOffset>\(1524000 - calibrationY)</wp:posOffset>"))
        // 文本框尺寸 = bbox 尺寸（0.5×3_810_000） + 高度吸收 0.3% 页高
        // （`restoredPageXML` 的 contentExtra，防 WPS 按 shape 高度裁最后一行）。
        let expectedHeight = 762000 + Int((7_620_000 * 0.003).rounded())
        #expect(xml.contains(#"cx="1905000""#))
        #expect(xml.contains(#"cy="\#(expectedHeight)""#))
    }

    // MARK: - srcRect 复用底图

    @Test("figure/barcode/artwork 复用同一底图 + srcRect 裁剪")
    func figuresReuseBaseImageWithSrcRect() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "srcRect", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(kind: .figure, bbox: CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.15), text: ""),
                    ReconstructBlock(
                        kind: .barcode,
                        bbox: CGRect(x: 0.6, y: 0.3, width: 0.1, height: 0.1),
                        text: "https://example.com/qr",
                        barcodePayload: "https://example.com/qr"
                    ),
                    ReconstructBlock(kind: .artwork, bbox: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.2), text: "")
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "srcrect")
        defer { try? FileManager.default.removeItem(at: url) }

        // 每页 media 单图：底图一份，figure/barcode/artwork 全部 srcRect 复用（FR-010）
        let entries = MiniZip.entries(from: try Data(contentsOf: url))
        let media = entries.keys.filter { $0.hasPrefix("word/media/") }
        #expect(media.count == 1, "srcRect 复用底图，不得重复嵌图：\(media)")

        let xml = try DocxProbe.documentXML(from: url)
        // 底图 + 三个保留区域 = 4 次引用，全部指向同一个 rel
        let embeds = embedIDs(in: xml)
        #expect(embeds.count == 4, "底图 1 次 + 保留区域 3 次：\(embeds)")
        #expect(Set(embeds).count == 1, "所有图片必须引用同一张底图：\(embeds)")

        // figure 区域裁剪（srcRect 单位 = 1/1000 %，从整图四边裁）：
        // bbox (0.25, 0.5, 0.2, 0.15) → l=25000 t=35000 r=55000 b=50000
        #expect(
            xml.contains(#"l="25000" t="35000" r="55000" b="50000""#),
            "figure 区域应按 bbox 裁剪底图"
        )
    }

    // MARK: - 净化底图（擦除烘焙）

    @Test("净化底图：原文字区域烘进像素，docx 不再发射 mask shape")
    func bakedBaseErasesTextRegionWithoutMaskShape() async throws {
        // 浅灰底 + 文字区深色块 + 擦除区外的对照组深色块：
        // - 文字区（bbox + 1.5% 外扩）烘焙后应变回环带 median 浅灰；
        // - 擦除区外的像素一个都不许动。
        let background = UIColor(white: 0.92, alpha: 1)
        let base = try RestoredBaseImage.writeBase(
            width: 400,
            height: 800,
            background: background,
            darkRects: [
                // bbox (0.1, 0.7, 0.5, 0.1) @400×800 → 左上原点 (40,160,200,80)；
                // 外扩 1.5% 后 (34,148,212,104)。深色块严格落在外扩区内。
                CGRect(x: 36, y: 150, width: 202, height: 100),
                // 对照组：远离文字区，烘焙后必须保持深色。
                CGRect(x: 300, y: 400, width: 40, height: 40)
            ],
            darkColor: UIColor(white: 0.08, alpha: 1)
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "净化底图", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [textBlock("正文内容")],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "baked")
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try DocxProbe.documentXML(from: url)
        // 1) 不再发射 mask shape（宿主渲染器不画形状 = 叠字根因，T021/G3'）
        #expect(!xml.contains(#"name="Mask"#), "docx 不应再有 Mask shape")
        #expect(!xml.contains("<a:solidFill>"), "擦除已烘进底图，不应再有 solidFill 覆盖层")
        // 2) 文字仍走可编辑文本框（不得为了擦除退化成图片版）
        #expect(xml.contains("<wps:txbx>"))
        #expect(xml.contains("正文内容"))

        // 3) media = 烘焙后的净化底图（重新编码，不是原文件原字节）
        let entries = MiniZip.entries(from: try Data(contentsOf: url))
        let media = try #require(
            entries.first { $0.key.hasPrefix("word/media/") },
            "缺少底图 media"
        )
        let original = try Data(contentsOf: base)
        #expect(media.value != original, "底图 media 应是烘焙后的字节，不是原图原字节")

        // 4) 擦除区被刷成环带 median 底色；区外像素原样
        let center = try #require(pixelRGB(in: media.value, x: 140, y: 200))
        #expect(isLight(center), "bbox 中心应被刷成环带底色，实际 \(center)")
        // 外扩边带（x=36 在 bbox 左缘 40 之外、外扩左缘 34 之内）也必须净化
        let expandedEdge = try #require(pixelRGB(in: media.value, x: 36, y: 200))
        #expect(isLight(expandedEdge), "bbox 外扩 1.5% 的边带也应被净化，实际 \(expandedEdge)")
        let control = try #require(pixelRGB(in: media.value, x: 320, y: 420))
        #expect(isDark(control), "擦除区外的原像素不得被改，实际 \(control)")
    }

    // MARK: - 控制字符清洗（不回归）

    @Test("版面还原档同样剔除 XML 1.0 非法控制字符")
    func restoredStripsIllegalControlCharacters() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "控制字符", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .paragraph,
                        bbox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1),
                        text: "正常\u{0001}文字\u{000B}结束"
                    )
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "ctl")
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try DocxProbe.documentXML(from: url)
        #expect(xml.contains("正常"))
        #expect(xml.contains("文字"))
        #expect(xml.contains("结束"))
        // 残留 0x01 / 0x0B 会让 Word 判定整个 docx 损坏 —— XMLParser 必须能解析。
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "document.xml 不是合法 XML：\(parser.parserError?.localizedDescription ?? "")")
    }

    // MARK: - 夹具端到端（真实样张 → parse → .restored docx）

    /// FR-009 同构的**链路级**证明（T028）：真实样张 + 固化真实 OCR 走完整 parse，
    /// 导出的 `.restored` DOCX 里——
    /// - 动态 sectPr 随原图尺寸（869×1024 px → 13035×15360 twips）；
    /// - 底图 media 就是 `baseImageRelativePath` 指向的原文件字节（jpg 单图，FR-010）；
    /// - 表格 / 正文都落在浮动文本框里（表格过渡期进 txbx，US5/T031 换 w:tblpPr）；
    /// - **文本框 posOffset 与 `PageLayoutMapper` 对同一 bbox 的输出逐位相等**
    ///   （导出定位 = 预览定位：预览只是 targetSize 不同的同一映射函数）。
    @Test("夹具端到端：样张 → parse → .restored docx，坐标与预览映射一致")
    func fixtureEndToEndMatchesPreviewMapping() async throws {
        let image = try ReconstructSampleImage.nutritionMango()
        let fixture = ReconstructV2Fixtures.nutritionMango

        let parser = OnDeviceDocumentParser(recognizer: FixtureRecognizer(lines: fixture.lines))
        var page = try await parser.parse(imageURL: image, pageID: UUID(), scene: fixture.expectedScene)
        // 底座由 VM 在 App 内注入（T016，来自 PageFileStore rendered 图）；
        // 端到端测试里底座 = 样张原图本身。
        page.baseImageRelativePath = image.path

        let document = ReconstructDocument(documentID: UUID(), title: "营养表", pages: [page])
        let url = try await export(document, name: "e2e-restored")
        defer { try? FileManager.default.removeItem(at: url) }

        let xml = try DocxProbe.documentXML(from: url)
        let entries = MiniZip.entries(from: try Data(contentsOf: url))

        // ① 动态 sectPr：页面尺寸随原图（twips = EMU / 635）
        #expect(DocxProbe.count(of: "<w:sectPr>", in: xml) == 1)
        let emu = PageLayoutMapper.emuPageSize(for: page.size)
        let widthTwips = Int((emu.width / 635).rounded())
        let heightTwips = Int((emu.height / 635).rounded())
        #expect(xml.contains("w:w=\"\(widthTwips)\" w:h=\"\(heightTwips)\""), "sectPr 未随原图尺寸")

        // ② 底图：每页恰一张 media = **净化底图**（擦除已烘进像素，JPEG 重编码）；
        //    figure 若有检出也只 srcRect 复用，不重复嵌图（FR-010 链路级验证）
        let media = entries.keys.filter { $0.hasPrefix("word/media/") }
        #expect(media.count == 1, "每页单图（保留区全靠 srcRect 复用）：\(media)")
        #expect(media.allSatisfy { $0.hasSuffix(".jpg") }, "净化底图应为 JPEG：\(media)")
        let baseName = try #require(media.first)
        let bakedData = try #require(entries[baseName])
        let baseData = try Data(contentsOf: image)
        #expect(bakedData != baseData, "底图必须是烘焙后的净化底图，不能是原文件字节")
        #expect(UIImage(data: bakedData) != nil, "净化底图必须是可解码的 JPEG")
        #expect(inlineBaseCount(in: xml) == 1, "净化底图应为内联图")
        #expect(anchoredBaseCount(in: xml) == 0, "净化底图不得再用锚定图（宿主渲染器不画）")

        // ③ 结构：无 mask shape + 表格 + 正文（可编辑文本框）
        #expect(!xml.contains(#"name="Mask"#), "docx 不应再有 Mask shape")
        #expect(xml.contains("<wps:txbx>"))
        #expect(xml.contains("<w:tbl>"), "表格内容丢了")
        #expect(xml.contains("1429"), "表格数值丢了")
        #expect(xml.contains("芒果干"), "正文没进可编辑文本框")

        // ④ 坐标一致性：文本框 posOffset == PageLayoutMapper 对同一 bbox 的输出。
        let map = PageLayoutMapper.map(pageSize: page.size, targetSize: emu)
        let textBlock = try #require(page.blocks.first { block in
            switch block.kind {
            case .heading, .paragraph, .list, .checkbox, .handwrittenBlank:
                return !block.text.isEmpty
            case .figure, .barcode, .artwork, .table:
                return false
            }
        })
        let rect = map.rect(textBlock.bbox)
        let calibrationX = emu.width * CGFloat(LayoutTypography.restoredTextHorizontalOffsetRatio)
        let calibrationY = emu.height * CGFloat(LayoutTypography.restoredTextVerticalLiftRatio)
        let expectedX = "<wp:posOffset>\(Int64((rect.minX + calibrationX).rounded()))</wp:posOffset>"
        let expectedY = "<wp:posOffset>\(Int64((rect.minY - calibrationY).rounded()))</wp:posOffset>"
        #expect(xml.contains(expectedX), "文本框 posH 应等于预览映射输出 \(expectedX)")
        #expect(xml.contains(expectedY), "文本框 posV 应等于预览映射输出 \(expectedY)")
    }

    // MARK: - 表格原位保真（US5 / FR-008）

    /// 原生浮动表格（plan D7：`w:tbl` + `w:tblpPr`，**不套文本框**）。
    /// 定位数值断言：tblpX/tblpY 单位 twips = EMU / 635 —— bbox (0.1, 0.4, 0.6, 0.3)
    /// @ 400×800px 页 → posH 381000 EMU = **600** twips；posV (1−0.7)×7620000 = 3600 twips；
    /// 表宽贴合 bbox：0.6×3810000 EMU = **3600** twips（dxa）。
    @Test("表格原生浮动：w:tblpPr 定位数值 + 不套文本框")
    func tablesFloatInPlaceViaTblpPr() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "浮动表", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .table,
                        bbox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.3),
                        text: "",
                        table: ReconstructTable(rows: [
                            ["项目", "每100克", "NRV%"],
                            ["能量", "1429千焦", "17%"]
                        ])
                    )
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "tblp")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 原生浮动定位存在，数值 = PageLayoutMapper 输出换算 twips
        #expect(xml.contains("<w:tblpPr"), "表格缺少 w:tblpPr 原生浮动定位")
        #expect(xml.contains(#"w:tblpX="600""#), "tblpX 应为 600 twips（bbox minX × 页宽 EMU ÷ 635）")
        #expect(xml.contains(#"w:tblpY="3600""#), "tblpY 应为 3600 twips（y 翻转后 ÷ 635）")
        // 表宽贴合 bbox（dxa），不再用结构化档的固定 9000
        #expect(xml.contains(#"w:tblW w:w="3600" w:type="dxa""#), "表宽应随 bbox 而非定宽")
        // 不套文本框：本页只有表格块，文本框数应为 0
        #expect(DocxProbe.count(of: "<w:txbxContent>", in: xml) == 0, "表格不得再进文本框")
        // 行列内容保真
        #expect(DocxProbe.count(of: "<w:tr>", in: xml) == 2)
        #expect(xml.contains("1429千焦"))
    }

    /// FR-008 内容一致性：同一 parse 产物双档导出，表格行列内容必须一致
    /// （版面还原档重排的是**位置**，不是内容）。
    @Test("表格行列内容双档一致：同一产物两档导出 rows 相等")
    func tableRowsAreIdenticalAcrossTiers() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let rows = [
            ["项目", "每100克", "NRV%"],
            ["能量", "1429千焦", "17%"],
            ["蛋白质", "1.5克", "3%"]
        ]
        let document = ReconstructDocument(documentID: UUID(), title: "双档表", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .table,
                        bbox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.3),
                        text: "",
                        table: ReconstructTable(rows: rows)
                    )
                ],
                baseURL: base
            )
        ])
        let restoredURL = try await export(document, name: "tiers-restored")
        defer { try? FileManager.default.removeItem(at: restoredURL) }
        let structuredURL = try await DocxExportService().makeDocx(
            document,
            fileName: "tiers-structured-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: structuredURL) }

        let restored = try DocxProbe.documentXML(from: restoredURL)
        let structured = try DocxProbe.documentXML(from: structuredURL)

        // 两档都是 w:tbl 且行数相等
        #expect(restored.contains("<w:tbl>"))
        #expect(structured.contains("<w:tbl>"))
        #expect(DocxProbe.count(of: "<w:tr>", in: structured) == 3)
        #expect(
            DocxProbe.count(of: "<w:tr>", in: restored) == DocxProbe.count(of: "<w:tr>", in: structured),
            "两档行数应相等"
        )
        // 单元格内容两档都在（一个不丢）
        for row in rows {
            for cell in row {
                #expect(restored.contains(cell), "版面还原档丢单元格：\(cell)")
                #expect(structured.contains(cell), "结构化档丢单元格：\(cell)")
            }
        }
    }

    /// nutrition 夹具端到端（US5）：真实样张 parse 出的表格块在 `.restored` 导出里
    /// 原位浮动 —— 表格坐标与 `PageLayoutMapper` 对同一 bbox 的输出逐位相等。
    ///
    /// 该页有正文 + 表格：表格走**浮动文本框（TableBox）**包装，保证 WPS 在
    /// 「内联底图 + 页高承载段落」下仍是一页（WPS 会把 body 级 `w:tbl` 推到下一页）；
    /// 纯表格页仍走原生 `w:tblpPr`（`tablesFloatInPlaceViaTblpPr` 守护）。
    @Test("nutrition 夹具端到端：正文页表格原位浮动，TableBox = 预览映射输出")
    func nutritionFixtureTableFloatsInPlace() async throws {
        let image = try ReconstructSampleImage.nutritionMango()
        let fixture = ReconstructV2Fixtures.nutritionMango
        let parser = OnDeviceDocumentParser(recognizer: FixtureRecognizer(lines: fixture.lines))
        var page = try await parser.parse(imageURL: image, pageID: UUID(), scene: fixture.expectedScene)
        page.baseImageRelativePath = image.path
        let document = ReconstructDocument(documentID: UUID(), title: "营养表", pages: [page])
        let url = try await export(document, name: "e2e-tblp")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        let tableBlock = try #require(page.blocks.first { $0.kind == .table && $0.table?.rows.isEmpty == false })
        let emu = PageLayoutMapper.emuPageSize(for: page.size)
        let rect = PageLayoutMapper.map(pageSize: page.size, targetSize: emu).rect(tableBlock.bbox)
        let tableBox = try #require(xml.range(of: #"name="TableBox"#), "正文页表格应进 TableBox")
        let anchor = try #require(
            xml.range(of: "<wp:anchor", options: .backwards, range: xml.startIndex..<tableBox.lowerBound),
            "TableBox 缺少锚点"
        )
        let anchorPrefix = xml[anchor.lowerBound..<tableBox.lowerBound]
        let expectedX = "<wp:posOffset>\(Int(rect.minX.rounded()))</wp:posOffset>"
        let expectedY = "<wp:posOffset>\(Int(rect.minY.rounded()))</wp:posOffset>"
        #expect(anchorPrefix.contains(expectedX), "TableBox 水平位置应等于映射输出：\(expectedX)")
        #expect(anchorPrefix.contains(expectedY), "TableBox 垂直位置应等于映射输出：\(expectedY)")
        #expect(!xml.contains("<w:tblpPr"), "TableBox 内表格不应再带 tblpPr（定位交给文本框锚点）")
        // 行数保真（表头 + 数据行 ≥ 6）且数值在
        #expect(DocxProbe.count(of: "<w:tr>", in: xml) >= 6, "表格行数不足")
        #expect(xml.contains("1429"))
    }

    // MARK: - US2 实测字号（spec/layout-engine plan D4 / FR-004）

    @Test("密集页字号走实测行高换算，非页高 1.8% 常数（SC-003）")
    func densePageFontSizeFollowsMeasuredLineHeight() async throws {
        // 400×800px 页 @96dpi → 600pt 页高。密集行高 1.0%、常规行高 2.0%：
        // 期望 w:sz = LayoutTypography.fontPT(实测行高, 600pt) × 2
        //   密集 = clamp(0.010 × 600 × 1.05, 7, 28) = 7pt → 14
        //   常规 = clamp(0.020 × 600 × 1.05, 7, 28) = 12.6pt → 25
        // 旧常数路径两者同为 0.018 × 600 = 10.8pt → 22：密集页被放大约 1.7 倍。
        // T007 行级化语义：单行块 line.height == 块级实测，lineFontPT 与块级
        // fontPT 数值恒等（逐行分档判别由 heterogeneousLinesGetPerLineFontSize 钉）。
        let denseBlock = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.03),
            text: "密集正文",
            lines: [BlockLine(text: "密集正文", height: 0.010, gapToPrevious: 0, leadingOffset: 0, width: 0.4)],
            measuredLineHeight: 0.010
        )
        let regularBlock = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.05),
            text: "常规正文",
            lines: [BlockLine(text: "常规正文", height: 0.020, gapToPrevious: 0, leadingOffset: 0, width: 0.4)],
            measuredLineHeight: 0.020
        )
        let document = ReconstructDocument(documentID: UUID(), title: "密集页", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [denseBlock, regularBlock])
        ])
        let url = try await export(document, name: "dense-font")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        let denseHalf = try #require(fontSizeHalfPoints(in: xml, of: "密集正文"))
        let regularHalf = try #require(fontSizeHalfPoints(in: xml, of: "常规正文"))
        let expectedDense = LayoutTypography.fontPT(measuredLineHeight: 0.010, pageHeightPT: 600)
        let expectedRegular = LayoutTypography.fontPT(measuredLineHeight: 0.020, pageHeightPT: 600)
        #expect(
            denseHalf == Int((expectedDense * 2).rounded()),
            "密集块 w:sz 应为实测换算 \(expectedDense)pt → \(Int((expectedDense * 2).rounded()))，实际 \(denseHalf)"
        )
        #expect(
            regularHalf == Int((expectedRegular * 2).rounded()),
            "常规块 w:sz 应为实测换算 \(expectedRegular)pt → \(Int((expectedRegular * 2).rounded()))，实际 \(regularHalf)"
        )
    }

    @Test("同一产物双端字号/页高比例相等（钳制基准统一）")
    func fontSizeRatioIdenticalAcrossPreviewAndDocx() async throws {
        // 照片页 800×2000px @96dpi → 1500pt 页高：heading 实测行高 3% → fontPT =
        // clamp(0.030 × 1500 × 1.05, 7, 28) = 28（钳制只在文档页 pt 空间发生一次）；
        // 正文 0.8% → 12.6pt。预览换算标准（LayoutTypography.canvasFontPT，T016 接入
        // LayoutCanvas）：canvasFont = fontPT / pageHeightPT × 画布页高 —— 字号/页高
        // 比例双端恒等；旧实现两处本地公式各钳各的空间，照片页标题双端大小背离（根因 6）。
        // T007 行级化语义：单行块 line.height == 块级实测，行级/块级数值恒等
        //（逐行分档判别由 heterogeneousLinesGetPerLineFontSize 钉）。
        let headingBlock = ReconstructBlock(
            kind: .heading,
            bbox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.06),
            text: "大标题",
            style: .heading,
            lines: [BlockLine(text: "大标题", height: 0.030, gapToPrevious: 0, leadingOffset: 0, width: 0.3)],
            measuredLineHeight: 0.030
        )
        let bodyBlock = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.04),
            text: "照片页正文",
            lines: [BlockLine(text: "照片页正文", height: 0.008, gapToPrevious: 0, leadingOffset: 0, width: 0.5)],
            measuredLineHeight: 0.008
        )
        let document = ReconstructDocument(documentID: UUID(), title: "照片页", pages: [
            makePage(size: CGSize(width: 800, height: 2000), blocks: [headingBlock, bodyBlock])
        ])
        let url = try await export(document, name: "ratio-font")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        let headingFontPT = LayoutTypography.fontPT(measuredLineHeight: 0.030, pageHeightPT: 1500)
        let bodyFontPT = LayoutTypography.fontPT(measuredLineHeight: 0.008, pageHeightPT: 1500)
        let headingHalf = try #require(fontSizeHalfPoints(in: xml, of: "大标题"))
        let bodyHalf = try #require(fontSizeHalfPoints(in: xml, of: "照片页正文"))
        #expect(
            headingHalf == Int((headingFontPT * 2).rounded()),
            "标题 w:sz 应为钳制后 \(headingFontPT)pt → \(Int((headingFontPT * 2).rounded()))，实际 \(headingHalf)"
        )
        #expect(
            bodyHalf == Int((bodyFontPT * 2).rounded()),
            "正文 w:sz 应为实测换算 \(bodyFontPT)pt → \(Int((bodyFontPT * 2).rounded()))，实际 \(bodyHalf)"
        )
        // heading 样式保留（FR-004：字号走实测，bold/Heading1 不变）
        #expect(xml.contains(#"w:pStyle w:val="Heading1""#), "标题段应保留 Heading1 样式")

        // 双端比例恒等：DOCX 字号/页高 == 预览换算 canvasFont/画布页高（任意画布尺寸）
        let map = PageLayoutMapper.map(
            pageSize: CGSize(width: 800, height: 2000),
            targetSize: CGSize(width: 300, height: 750)
        )
        let canvasHeight = Double(map.pageSize.height) * Double(map.scale)
        let canvasFont = LayoutTypography.canvasFontPT(
            fontPT: headingFontPT,
            pageHeightPT: 1500,
            map: map
        )
        #expect(
            abs(canvasFont / canvasHeight - headingFontPT / 1500) < 1e-9,
            "预览 字号/页高 比例应与 DOCX 恒等（钳制基准统一）"
        )
    }

    // MARK: - US3 行段结构（spec/layout-engine plan D7 / FR-005）

    @Test("有 lines 块 txbx 每行一段：w:line 实测行高×20 exact + w:ind 行首偏移")
    func lineBlocksRenderOneParagraphPerLine() async throws {
        // 400×800px 页 → 页高 600pt（7_620_000 EMU ÷ 12700）、页宽 6000 dxa
        // （3_810_000 EMU ÷ 635）。两行：
        // L1 h0.02 lead0 → w:line = 0.02×600×20 = 240、w:left = 0
        // L2 h0.025 lead0.05 → w:line = 0.025×600×20 = 300、w:left = 0.05×6000 = 300
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1),
            text: "第一行\n第二行",
            lines: [
                BlockLine(text: "第一行", height: 0.02, gapToPrevious: 0, leadingOffset: 0, width: 0.4),
                BlockLine(text: "第二行", height: 0.025, gapToPrevious: 0.01, leadingOffset: 0.05, width: 0.4),
            ],
            measuredLineHeight: 0.02
        )
        let document = ReconstructDocument(documentID: UUID(), title: "行段", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [block])
        ])
        let url = try await export(document, name: "line-paras")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        let content = try #require(txbxContent(in: xml))

        // 每行一个 w:p（两行两段），段前段后 0
        let paragraphCount = DocxProbe.count(of: "<w:p>", in: content)
        #expect(paragraphCount == 2, "两行应两段，实际 \(paragraphCount)")
        #expect(content.contains(#"w:before="0" w:after="0" w:line="240" w:lineRule="exact""#), "L1 行高 0.02×600pt×20 = 240 twips exact")
        // L2 与上一行有 0.01 页高正间隙 → w:before = 0.01×600pt×20 = 120 twips；
        // 行高仍是 0.025×600pt×20 = 300 twips exact。
        #expect(content.contains(#"w:before="120" w:after="0" w:line="300" w:lineRule="exact""#), "L2 正间隙 120 + 行高 300 twips exact")
        #expect(content.contains(#"<w:ind w:left="300"/>"#), "L2 行首偏移 0.05×6000 dxa = 300")
        #expect(content.contains("第一行") && content.contains("第二行"))
        // 每行一段后不应再出现 w:br（行间由段落分隔，不再用软换行）
        #expect(!content.contains("<w:br/>"), "行段路径不应残留 w:br 软换行")
    }

    @Test("无 lines 块保持单段 w:br 路径（行为不变）")
    func noLineBlocksKeepSingleParagraph() async throws {
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1),
            text: "单段第一行\n单段第二行"
        )
        let document = ReconstructDocument(documentID: UUID(), title: "单段", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [block])
        ])
        let url = try await export(document, name: "single-para")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        let content = try #require(txbxContent(in: xml))

        #expect(DocxProbe.count(of: "<w:p>", in: content) == 1, "无 lines 块必须保持单段")
        #expect(content.contains("<w:br/>"), "多行文本仍走 w:br 换行")
    }

    // MARK: - 行级字号 w:sz（spec/scan-fidelity T007 / T027）

    /// T027：w:sz 断言行级化——异构行高块**每行一档**（T007 `lineFontPT` 逐行
    /// 换算，行实测高 × 页高 × 1.05 钳制 [7,28]），不再整块共用块级字号。
    /// 行高退化（≤ 0）的行回退块级基准（`fontPT(for:)`，本夹具块级实测 0.025）。
    ///
    /// @ 400×800px 页（页高 600pt、页宽 6000 dxa）：
    /// - L1 h0.030 → 18.9pt → **38** 半磅（旧块级语义会给 32——大字行被压扁）；
    /// - L2 h0.020 → 12.6pt → **25** 半磅；
    /// - L3 h0（退化）→ 块级 0.025×600×1.05=15.75pt → **32** 半磅。
    /// `w:line` exact 维持逐行实测（L1 360 / L2 240 twips）——字号行级化不动行距。
    @Test("行级字号 w:sz 逐行推导：异构行高每行一档 + 退化行回退块级")
    func heterogeneousLinesGetPerLineFontSize() async throws {
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.12),
            text: "标题行\n正文行\n退化行",
            lines: [
                BlockLine(text: "标题行", height: 0.030, gapToPrevious: 0, leadingOffset: 0, width: 0.3),
                BlockLine(text: "正文行", height: 0.020, gapToPrevious: 0.01, leadingOffset: 0.05, width: 0.4),
                BlockLine(text: "退化行", height: 0, gapToPrevious: 0.01, leadingOffset: 0, width: 0.4),
            ],
            measuredLineHeight: 0.025
        )
        let document = ReconstructDocument(documentID: UUID(), title: "行级字号", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [block])
        ])
        let url = try await export(document, name: "line-sz")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        let content = try #require(txbxContent(in: xml))

        // 每行一段（3 行 3 段）
        #expect(DocxProbe.count(of: "<w:p>", in: content) == 3)

        // w:sz 逐行一档（字面值钉死换算结果，非与实现自洽）
        let titleHalf = try #require(fontSizeHalfPoints(in: content, of: "标题行"))
        let bodyHalf = try #require(fontSizeHalfPoints(in: content, of: "正文行"))
        let fallbackHalf = try #require(fontSizeHalfPoints(in: content, of: "退化行"))
        #expect(titleHalf == 38, "L1 h0.030×600×1.05=18.9pt → 38 半磅，实际 \(titleHalf)")
        #expect(bodyHalf == 25, "L2 h0.020×600×1.05=12.6pt → 25 半磅，实际 \(bodyHalf)")
        #expect(fallbackHalf == 32, "L3 h0 退化回退块级 0.025×600×1.05=15.75pt → 32 半磅，实际 \(fallbackHalf)")
        #expect(titleHalf != bodyHalf, "异构行高必须逐行分档（整块共用字号是叠字根因）")

        // w:line exact 行距维持逐行实测（0.030×600×20=360、0.020×600×20=240）
        #expect(content.contains(#"w:before="0" w:after="0" w:line="360" w:lineRule="exact""#), "L1 行高应保持实测 360 twips")
        #expect(content.contains(#"w:before="120" w:after="0" w:line="240" w:lineRule="exact""#), "L2 正间隙 120 + 行高 240 twips exact")
    }

    /// T012 导出通路（FR-004 出口侧证据，补 SC-006 覆盖）：带 `segments` 的行按
    /// 分段多 run 渲染——宽空隙（≥ 2% 页宽）用绝对 `w:tab` 定位到下一段，
    /// 窄空隙用普通单空格 run 连接；run 与文本 run 同字号（一行一档，T007）。
    ///
    /// @ 400×800px 页（页宽 300pt、页高 600pt），行高 0.02 → 字号 12.6pt：
    /// - L1 段 [Name(0,0.1), Date(0.5,0.1)]：空隙 0.4 → 120pt → tab；
    /// - L2 段 [A(0,0.1), B(0.11,0.1)]：空隙 0.01 → 3pt → 普通单空格。
    @Test("分段行导出：宽空隙绝对 tab + 窄空隙普通空格 run")
    func segmentGapsRenderTabAndPlainSpaceRuns() async throws {
        let block = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1),
            text: "Name Date\nA B",
            lines: [
                BlockLine(
                    text: "Name Date", height: 0.02, gapToPrevious: 0, leadingOffset: 0, width: 0.5,
                    segments: [
                        LineSegment(text: "Name", offset: 0, width: 0.1),
                        LineSegment(text: "Date", offset: 0.5, width: 0.1)
                    ]
                ),
                BlockLine(
                    text: "A B", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0, width: 0.4,
                    segments: [
                        LineSegment(text: "A", offset: 0, width: 0.1),
                        LineSegment(text: "B", offset: 0.11, width: 0.1)
                    ]
                )
            ],
            measuredLineHeight: 0.02
        )
        let document = ReconstructDocument(documentID: UUID(), title: "分段占位", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [block])
        ])
        let url = try await export(document, name: "segment-runs")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        let content = try #require(txbxContent(in: xml))

        // 两行两段，四个分段文本 run 都在
        #expect(DocxProbe.count(of: "<w:p>", in: content) == 2)
        for text in ["Name", "Date", "A", "B"] {
            #expect(content.contains(">\(text)</w:t>"), "分段文本 run 缺失：\(text)")
        }
        // 宽空隙（≥ 2% 页宽）= 栏间/格间 gutter，用绝对 tab 定位到下一段；
        // 下划线空格在 WPS 会因累计宽度超框整行回绕（双栏表头只剩一行可见），
        // 不能再用空格近似宽 gutter（2026-10-23 WPS 真实页回归后的契约）。
        #expect(
            DocxProbe.count(of: "<w:tab/>", in: content) == 1,
            "宽空隙应恰有一个绝对 tab 连接符"
        )
        #expect(
            DocxProbe.count(of: #"<w:u w:val="single"/>"#, in: content) == 0,
            "宽 gutter 不再用下划线空格（WPS 会回绕）"
        )
        // 窄空隙：普通单空格 run 连接（无下划线变体）
        let plainSpace = "<w:t xml:space=\"preserve\"> </w:t>"
        #expect(content.contains(plainSpace), "窄空隙应用普通单空格 run 连接")
        // 空格 run 与文本 run 同字号（一行一档）：L1 文本 run = 行级 12.6pt → 25 半磅
        let nameHalf = try #require(fontSizeHalfPoints(in: content, of: "Name"))
        #expect(nameHalf == 25, "分段行文本 run 字号应为行级换算 25 半磅，实际 \(nameHalf)")
    }

    // MARK: - US4 渲染期兜底（spec/layout-engine plan D6 / FR-006）

    @Test("溢出的无 lines 块字号被布局期预缩（D6 风险注记二选一之 B：预缩 w:sz）")
    func overflowingFallbackTextIsPreScaledToFitRegion() async throws {
        // 400×800px 页 → 页高 600pt、页宽 300pt。无 lines 块（引擎溢出阶梯不作用）：
        // 兜底字号 = clamp(600×1.8%, 7, 28) = 10.8pt → w:sz 22（整半磅，预缩以
        // 量化后 11.0pt 为基准）。块 (0.05, 0.7, 0.5, 0.03)：区域 18pt、可用宽
        // 150pt；16 个全角字符 @11pt 估算换行 2 行 = 22.5pt > 18 → 预缩 × 0.8 =
        // 8.8pt → 单行 10.56pt 放下 → w:sz = 17.6 → 18（未触 7pt 下限，比例
        // 缩放可见）。对照组短文不缩（零扰动）。
        let overflowing = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.7, width: 0.5, height: 0.03),
            text: "这是一段需要两行才能放得下的正文"
        )
        let control = textBlock("短文")
        let document = ReconstructDocument(documentID: UUID(), title: "预缩", pages: [
            makePage(size: CGSize(width: 400, height: 800), blocks: [overflowing, control])
        ])
        let url = try await export(document, name: "prescale")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        let baseHalf = Int((LayoutTypography.fallbackFontPT(pageHeightPT: 600) * 2).rounded())
        #expect(baseHalf == 22, "兜底字号应为 10.8pt → 22，实际 \(baseHalf)")
        let scaledHalf = try #require(fontSizeHalfPoints(in: xml, of: "这是一段需要两行才能放得下的正文"))
        #expect(
            scaledHalf == 18,
            "溢出块应预缩至 8.8pt → w:sz 18（11.0 × 18/22.5），实际 \(scaledHalf)"
        )
        #expect(scaledHalf < baseHalf, "预缩必须生效（存在性断言，plan 测试契约）")
        let controlHalf = try #require(fontSizeHalfPoints(in: xml, of: "短文"))
        #expect(
            controlHalf == baseHalf,
            "装得下的短文保持原字号（零扰动），实际 \(controlHalf)"
        )
        // 二选一之 B 落地：bodyPr 不写 normAutofit（旁注见 textBoxXML）
        #expect(!xml.contains("normAutofit"), "预缩方案下不应残留 normAutofit（避免双重缩放）")
    }

    // MARK: - US5 表格几何（spec/layout-engine plan D8 / FR-008）

    /// 实测列宽上桌（D8）：`w:tblGrid` 按 columnRatios 分配总宽（dxa），单元格
    /// tcW 逐列跟随；行高封顶 `w:trHeight` exact = 区域高 ÷ 行数（诊断根因 5 的
    /// Word 无界下坠修复）。预览（canvasTable）以同一组 `LayoutTypography` 度量
    /// 绘制列宽/行高/字号（编译期共享 = 双端同构；视觉验收 SC-001）。
    ///
    /// @ 400×800px 页：bbox 宽 0.6 → 表宽 3600 twips；ratios [0.5, 0.3, 0.2] →
    /// gridCol 1800 / 1080 / 720；bbox 高 0.3 → 3600 twips ÷ 2 行 = 1800。
    @Test("表格列宽走实测比例：tblGrid 非均分 + trHeight exact = 区域高÷行数")
    func tableGridFollowsMeasuredColumnRatios() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "列宽比例", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .table,
                        bbox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.3),
                        text: "",
                        table: ReconstructTable(
                            rows: [
                                ["项目", "每100克", "NRV%"],
                                ["能量", "1429千焦", "17%"]
                            ],
                            columnRatios: [0.5, 0.3, 0.2]
                        )
                    )
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "tbl-grid")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // tblGrid 按实测比例（非均分）
        #expect(xml.contains(#"<w:gridCol w:w="1800"/>"#), "首列应为 3600 × 0.5 = 1800 dxa")
        #expect(xml.contains(#"<w:gridCol w:w="1080"/>"#), "中列应为 3600 × 0.3 = 1080 dxa")
        #expect(xml.contains(#"<w:gridCol w:w="720"/>"#), "末列应为 3600 × 0.2 = 720 dxa")
        #expect(!xml.contains(#"<w:gridCol w:w="1200"/>"#), "有实测比例时不得均分")
        // 单元格宽度逐列跟随 gridCol（fixed 布局一致性）
        #expect(xml.contains(#"w:tcW w:w="1800" w:type="dxa""#))
        #expect(xml.contains(#"w:tcW w:w="1080" w:type="dxa""#))
        #expect(xml.contains(#"w:tcW w:w="720" w:type="dxa""#))
        // 行高封顶：区域高 3600 twips ÷ 2 行 = 1800，exact
        #expect(
            DocxProbe.count(of: #"<w:trHeight w:val="1800" w:hRule="exact"/>"#, in: xml) == 2,
            "每行 trHeight exact = 区域高 ÷ 行数"
        )
        #expect(!xml.contains("atLeast"), "放得下不得升级 atLeast")
        // 单元格基础字号 = 实测字号 22 半磅 → 11pt × 0.8 = 8.8pt → 18 半磅（本夹具放得下不缩）
        let cellHalf = try #require(fontSizeHalfPoints(in: xml, of: "1429千焦"))
        #expect(cellHalf == 18, "未溢出的单元格保持基础字号，实际 \(cellHalf)")
    }

    /// 放不下 → 整表行高升级 atLeast（D8 升级链）：单元格字号先按实测列宽自适应
    /// （下限 7pt），到 7pt 仍放不下时**该表所有行** hRule 转 atLeast（1800 变保底
    /// 值，Word 增长到内容高度，文字不截断）+ tableGrowthUpgrade 日志；预览以
    /// 同一判定同步增长行高（FR-008 同构）。
    ///
    /// 150 个全角字 @ 7pt：首列 90pt − 内边距 ≈ 80pt 可用 → 14 行 × 8.4pt ≈
    /// 117.6pt > 行高 90pt（3600 twips ÷ 2）→ 7pt 下限仍溢出 → 升级。
    @Test("放不下的表格升级 atLeast：字号到 7pt 下限仍溢出则整表行高转增长")
    func overflowingTableCellUpgradesRowHeightToAtLeast() async throws {
        let longCell = String(repeating: "长", count: 150)
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "行高升级", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .table,
                        bbox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.3),
                        text: "",
                        table: ReconstructTable(
                            rows: [
                                ["项目", "每100克", "NRV%"],
                                [longCell, "1", "2%"]
                            ],
                            columnRatios: [0.5, 0.3, 0.2]
                        )
                    )
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "tbl-atleast")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 整表升级：两行都是 atLeast，val 保持区域高 ÷ 行数（保底值不变）
        #expect(
            DocxProbe.count(of: #"<w:trHeight w:val="1800" w:hRule="atLeast"/>"#, in: xml) == 2,
            "放不下时整表行高转 atLeast（val 仍为 1800 保底）"
        )
        #expect(!xml.contains(#"w:hRule="exact""#), "升级后不得残留 exact")
        // 溢出单元格字号钳在 7pt（14 半磅）
        let overflowHalf = try #require(fontSizeHalfPoints(in: xml, of: longCell))
        #expect(overflowHalf == 14, "溢出单元格字号下限 7pt，实际 \(overflowHalf)")
        // 未溢出单元格保持基础字号（零扰动）
        let controlHalf = try #require(fontSizeHalfPoints(in: xml, of: "每100克"))
        #expect(controlHalf == 18, "放得下的单元格不缩（零扰动），实际 \(controlHalf)")
        // 文字不截断：完整长文本必须原样写入（FR-006/FR-008）
        #expect(xml.contains(longCell), "atLeast 升级后文字必须完整保留")
    }

    /// 回退通路（无 columnRatios——几何识别未产出列信息）：tblGrid 均分兜底，
    /// 定位/表宽/行高策略不劣化。
    @Test("无实测列宽的表格均分兜底：几何与策略不劣化")
    func tableWithoutRatiosKeepsEqualColumnFallback() async throws {
        let base = try RestoredBaseImage.writeWhite()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ReconstructDocument(documentID: UUID(), title: "均分兜底", pages: [
            makePage(
                size: CGSize(width: 400, height: 800),
                blocks: [
                    ReconstructBlock(
                        kind: .table,
                        bbox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.3),
                        text: "",
                        table: ReconstructTable(rows: [
                            ["项目", "每100克", "NRV%"],
                            ["能量", "1429千焦", "17%"]
                        ])
                    )
                ],
                baseURL: base
            )
        ])
        let url = try await export(document, name: "tbl-equal")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 均分兜底：3600 ÷ 3 = 1200 ×3
        #expect(
            DocxProbe.count(of: #"<w:gridCol w:w="1200"/>"#, in: xml) == 3,
            "无比例时 tblGrid 均分兜底"
        )
        // 行高封顶策略与比例通路一致
        #expect(
            DocxProbe.count(of: #"<w:trHeight w:val="1800" w:hRule="exact"/>"#, in: xml) == 2,
            "兜底通路同样写 trHeight exact"
        )
        // 既有定位/表宽/行数断言不劣化（tablesFloatInPlaceViaTblpPr 关键子集）
        #expect(xml.contains(#"w:tblpX="600""#))
        #expect(xml.contains(#"w:tblW w:w="3600" w:type="dxa""#))
        #expect(DocxProbe.count(of: "<w:tr>", in: xml) == 2)
        #expect(!xml.contains("atLeast"))
    }

    // MARK: - 夹具与辅助

    private func makePage(
        size: CGSize,
        blocks: [ReconstructBlock],
        baseURL: URL? = nil
    ) -> ReconstructPage {
        ReconstructPage(
            pageID: UUID(),
            size: size,
            scene: .plain,
            usedCloud: false,
            blocks: blocks,
            baseImageRelativePath: baseURL?.path
        )
    }

    private func textBlock(_ text: String) -> ReconstructBlock {
        ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1),
            text: text
        )
    }

    /// 提取第一个 `<w:txbxContent>` 子串（文本框内容段落区域）。
    private func txbxContent(in xml: String) -> String? {
        guard let start = xml.range(of: "<w:txbxContent>"),
              let end = xml.range(of: "</w:txbxContent>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    /// 提取包含 `text` 的 run 的字号（`w:sz` 半磅值）：run 的 rPr 紧邻 `<w:t>` 之前，
    /// 从文本位置向前找最近一次 `w:sz w:val="N"`（即该 run 自己的字号）。
    /// `w:szCs` 不匹配该模式（sz 后紧跟 Cs，非空格）。
    private func fontSizeHalfPoints(in xml: String, of text: String) -> Int? {
        let needle = "<w:t xml:space=\"preserve\">\(text)</w:t>"
        guard let textRange = xml.range(of: needle) else { return nil }
        let head = String(xml[xml.startIndex..<textRange.lowerBound])
        guard let regex = try? NSRegularExpression(pattern: "w:sz w:val=\"(\\d+)\"") else { return nil }
        guard
            let match = regex.matches(in: head, range: NSRange(head.startIndex..., in: head)).last,
            match.numberOfRanges > 1,
            let numberRange = Range(match.range(at: 1), in: head)
        else { return nil }
        return Int(head[numberRange])
    }

    private func export(_ document: ReconstructDocument, name: String) async throws -> URL {
        try await DocxExportService().makeDocx(
            document,
            fileName: "\(name)-\(UUID().uuidString).docx",
            tier: .restored
        )
    }

    /// 提取 document.xml 里全部 `r:embed="rIdN"` 的 rel id。
    private func embedIDs(in xml: String) -> [String] {
        var result: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let range = xml.range(of: "r:embed=\"", range: searchRange) {
            result.append(String(xml[range.upperBound...].prefix { $0 != "\"" }))
            searchRange = range.upperBound..<xml.endIndex
        }
        return result
    }

    /// 内联底图计数：按 `</wp:inline>` 分块后取最后出现的 `<wp:inline` 片段，
    /// 只看该 drawing 自己的 docPr（避免把下一块的内容算进来）。
    private func inlineBaseCount(in xml: String) -> Int {
        xml.components(separatedBy: "</wp:inline>").filter { chunk in
            guard let start = chunk.range(of: "<wp:inline", options: .backwards) else {
                return false
            }
            return chunk[start.lowerBound...].contains(#"name="BaseImage"#)
        }.count
    }

    /// 锚定底图计数（旧路径）：按 `</wp:anchor>` 分块后取最后出现的 `<wp:anchor`
    /// 片段。净化底图必须内联（锚定图/形状在宿主渲染器不落图），此计数应恒为 0。
    private func anchoredBaseCount(in xml: String) -> Int {
        xml.components(separatedBy: "</wp:anchor>").filter { chunk in
            guard let start = chunk.range(of: "<wp:anchor", options: .backwards) else {
                return false
            }
            return chunk[start.lowerBound...].contains(#"name="BaseImage"#)
        }.count
    }

    /// 读解码后图片在**左上原点**坐标 `(x, y)` 处的 RGB（0~255）。
    /// 整图一次性画进 RGBA 位图再取样：JPEG/色彩空间差异由 CG 统一。
    private func pixelRGB(in data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // 位图缓冲首行 = 图片顶行（与 CGImage 的行序一致）：左上原点直接取 y。
        let index = (y * width + x) * 4
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
    }

    private func isLight(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        color.r > 150 && color.g > 150 && color.b > 150
    }

    private func isDark(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        color.r < 100 && color.g < 100 && color.b < 100
    }
}

/// 确定性 OCR 替身（与 `ReconstructEndToEndTests.FixedRecognizer` 同型 ——
/// 那边是 private，这里自带一份），让「parse → 导出」这段完全确定，
/// 不依赖模拟器的 Vision 识别质量。
private struct FixtureRecognizer: TextRecognizing {
    let lines: [OCRLine]
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: lines)
    }
}

/// 纯白 JPEG 底座。`LayoutMaskBuilder` 的环带 median 采样 → (255,255,255)，
/// 净化底图的烘焙底色断言（浅色）得以钉死。
private enum RestoredBaseImage {
    static func writeWhite(width: Int = 400, height: Int = 800) throws -> URL {
        try writeBase(
            width: width,
            height: height,
            background: .white,
            darkRects: [],
            darkColor: .black
        )
    }

    /// 指定底色的 JPEG 底座，可画若干深色块（模拟原文字迹）。坐标用**左上原点**，
    /// 与 `LayoutMaskBuilder` 的 y 翻转互为镜像（测试里按此换算）。
    static func writeBase(
        width: Int = 400,
        height: Int = 800,
        background: UIColor,
        darkRects: [CGRect],
        darkColor: UIColor
    ) throws -> URL {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            darkColor.setFill()
            for rect in darkRects {
                context.fill(rect)
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw ZhixiaError.exportFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zhixia-restored-base-\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }
}

/// 测试端最小 ZIP 读取器：项目 `ZipArchive` 只写 **stored**（未压缩）条目，
/// 逐个解析 local file header 即可拿到「文件名 → 内容」，不需要引入解压库。
private enum MiniZip {
    static func entries(from data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= bytes.count {
            // local file header 签名 PK\x03\x04
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x4B,
                  bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04
            else { break }
            let dataSize = Int(readLE32(bytes, offset + 18))
            let nameLength = Int(readLE16(bytes, offset + 26))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength
            guard dataStart + dataSize <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<dataStart], as: UTF8.self)
            result[name] = Data(bytes[dataStart..<dataStart + dataSize])
            offset = dataStart + dataSize
        }
        return result
    }

    private static func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
