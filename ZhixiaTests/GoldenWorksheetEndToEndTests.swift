import Foundation
import Testing

@testable import Zhixia

/// 金标准端到端（spec/wps-parity-layout US1 / T007）。
///
/// **为什么需要这一层**：`docs/fixtures/images/grammar-worksheet.jpg` +
/// `docs/fixtures/golden-wps-reading-order.txt` 是「对标 WPS」的对照基线
/// （docs/11 §5.2：真机扫整页练习册，WPS 默认导出零假表）。US1 的独立可测承诺
/// ——「默认导出流式、零假表、通路可观测」—— 必须在**这条真实链路**上钉住：
///
/// ① 默认接线（Vision OCR + iOS 26 结构化识别）解析金标准页 → 流式档 docx
///    里 `w:tbl = 0`（散排编号填空文本绝不能聚成假表）；
/// ② 纯几何通路（不注入结构化识别器）解析同一页 → 零表格块
///    （v1 聚类器退役 + v2 锚点门控后，几何通路对无锚文本天然零表）；
/// ③ 通路决策**可断言**：注入替身识别器，结构化成功 → 吃结构化产物（含真表），
///    识别器返回 nil → 回退几何产物（零表）—— 这正是 `reconstructPath` 日志
///    （T004）在行为层的对应物，T008 诊断依赖这套机制；
/// ④ 散排编号填空合成线 → v1 退役回归钉：这组线**恰好落在 v1 聚类器的
///    产表区间内**（直连休眠代码验证非空），几何解析通路必须对它零表。
///
/// 真实 Vision 解析昂贵（两种接线各一次），用 actor 缓存跨用例共享。
struct GoldenWorksheetEndToEndTests {

    /// 固定 pageID：T008 诊断时按它从 `reconstructPath` 决策线里检索金标准页。
    /// （internal：同文件的 `GoldenParseCache` 是独立类型，private 挡不住跨类型访问。）
    static let goldenPageID = UUID(uuidString: "D077A5E7-0000-4000-8000-000000000001")!

    private static func goldenImage() throws -> URL {
        try ReconstructSampleImage.url("grammar-worksheet.jpg").requireExists()
    }

    // MARK: - ① 默认通路：零假表格

    @Test("金标准默认通路：流式 docx 零假表格（w:tbl = 0）且无浮动文本框")
    func defaultPathExportContainsNoFakeTables() async throws {
        let page = try await GoldenParseCache.shared.defaultPathPage()
        // 不是空产物才谈得上「零假表」—— 先钉住解析确实出了内容。
        #expect(page.hasContent, "金标准页默认通路解析为空，夹具链路坏了")
        #expect(page.blocks.count >= 10, "金标准页块数异常少：\(page.blocks.count)")

        let document = ReconstructDocument(documentID: UUID(), title: "金标准-语法练习", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "golden-flow-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // US1 Goal 的头号断言：散排编号填空场景，产物里一个表都不许有。
        #expect(
            DocxProbe.count(of: "<w:tbl>", in: xml) == 0,
            "流式产物出现假表格（w:tbl = \(DocxProbe.count(of: "<w:tbl>", in: xml))）"
        )
        // 流式档是段落流 + 内联图，浮动文本框是高保真档（.restored）的构造。
        #expect(
            DocxProbe.count(of: "<w:txbxContent>", in: xml) == 0,
            "流式产物混入了浮动文本框（w:txbxContent）"
        )
    }

    // MARK: - ② 几何通路：零表格块

    @Test("金标准几何通路：散排编号填空不产表")
    func geometricPathProducesNoTables() async throws {
        let page = try await GoldenParseCache.shared.geometricPathPage()
        #expect(page.hasContent, "金标准页几何通路解析为空，夹具链路坏了")

        let tables = page.blocks.filter { $0.kind == .table }
        #expect(tables.isEmpty, "几何通路对金标准页产出 \(tables.count) 张假表")
    }

    // MARK: - ③ 通路决策可断言（替身识别器）

    @Test("通路决策可断言：结构化成功吃结构化产物（含真表），返回 nil 回退几何（零表）")
    func pathDecisionIsAssertableViaFakes() async throws {
        let geometricLines = [
            OCRLine(text: "GEOMETRIC-MARKER 几何通路的段落", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.04)),
            OCRLine(text: "几何通路第二行", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.04))
        ]
        let structuredPage = StructuredDocumentPage(
            lines: [
                OCRLine(text: "STRUCTURED-MARKER 结构化通路的段落", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.6, height: 0.04))
            ],
            tables: [
                DetectedTable(
                    table: ReconstructTable(rows: [["项目", "数值"], ["能量", "1429千焦"]]),
                    bbox: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.2)
                )
            ],
            barcodes: [],
            source: .documentRequest
        )

        // 结构化成功：结构化 marker 进产物、几何 marker 不在、表格块存在
        // —— 对应 `reconstructPath(.structured, .structuredSuccess)` 决策线。
        let structuredParser = OnDeviceDocumentParser(
            recognizer: FixedOCRRecognizer(lines: geometricLines),
            structureRecognizer: FixedStructureRecognizer(result: structuredPage)
        )
        let viaStructured = try await structuredParser.parse(
            imageURL: URL(fileURLWithPath: "/dev/null"),
            pageID: Self.goldenPageID,
            scene: .auto
        )
        let structuredText = viaStructured.blocks.map(\.text).joined(separator: "\n")
        #expect(structuredText.contains("STRUCTURED-MARKER"), "结构化通路成功时产物必须是结构化识别结果")
        #expect(structuredText.contains("GEOMETRIC-MARKER") == false, "结构化通路成功时几何 OCR 不应再进产物")
        #expect(viaStructured.blocks.contains { $0.kind == .table }, "结构化通路的表格没有进产物")

        // 识别器返回 nil（低版本/请求失败/结果无效）：回退几何
        // —— 对应识别器捕获点发出的 `.lowVersionFallback`/`.requestFailed`/`.invalidResult`。
        let fallbackParser = OnDeviceDocumentParser(
            recognizer: FixedOCRRecognizer(lines: geometricLines),
            structureRecognizer: FixedStructureRecognizer(result: nil)
        )
        let viaFallback = try await fallbackParser.parse(
            imageURL: URL(fileURLWithPath: "/dev/null"),
            pageID: Self.goldenPageID,
            scene: .auto
        )
        let fallbackText = viaFallback.blocks.map(\.text).joined(separator: "\n")
        #expect(fallbackText.contains("GEOMETRIC-MARKER"), "识别器返回 nil 时必须回退几何产物")
        #expect(fallbackText.contains("STRUCTURED-MARKER") == false, "回退后不应残留结构化产物")
        #expect(viaFallback.blocks.contains { $0.kind == .table } == false, "回退通路不应携带结构化表格")
    }

    // MARK: - ④ v1 退役回归钉（合成线）

    /// 这组线刻意落在 v1 `OnDeviceTableCluster` 的产表区间内（2 列 × 3 行、
    /// 全部 ≤28 字符、occupancy = 1.0、无单字母占比问题）—— 先直连休眠代码
    /// 证明「v1 本会把它聚成假表」，再断言几何解析通路现在必须对它零表。
    /// 若 v1 有朝一日复活而不过这条钉，这里会立刻变红。
    @Test("散排编号填空合成线：v1 本会聚成假表，几何通路现在必须零表")
    func scatteredNumberedFillInLinesDoNotClusterIntoTables() async throws {
        let lines: [OCRLine] = [
            // 左列（midX ≈ 0.18）                    右列（midX ≈ 0.63）
            OCRLine(text: "(1) I am a student.", boundingBox: CGRect(x: 0.08, y: 0.88, width: 0.20, height: 0.03)),
            OCRLine(text: "(4) She is from China.", boundingBox: CGRect(x: 0.52, y: 0.88, width: 0.22, height: 0.03)),
            OCRLine(text: "(2) You are my friend.", boundingBox: CGRect(x: 0.08, y: 0.78, width: 0.22, height: 0.03)),
            OCRLine(text: "(5) They are happy.", boundingBox: CGRect(x: 0.52, y: 0.78, width: 0.20, height: 0.03)),
            OCRLine(text: "(3) He is a teacher.", boundingBox: CGRect(x: 0.08, y: 0.68, width: 0.21, height: 0.03)),
            OCRLine(text: "(6) We are at school.", boundingBox: CGRect(x: 0.52, y: 0.68, width: 0.21, height: 0.03))
        ]

        // 钉的有效性前提：这组输入确实在 v1 的聚类产表区间内（休眠代码直连验证）。
        #expect(OnDeviceTableCluster.detect(from: lines) != nil, "合成线不在 v1 产表区间内，回归钉失效")

        let parser = OnDeviceDocumentParser(recognizer: FixedOCRRecognizer(lines: lines))
        let page = try await parser.parse(
            imageURL: URL(fileURLWithPath: "/dev/null"),
            pageID: Self.goldenPageID,
            scene: .auto
        )
        let tables = page.blocks.filter { $0.kind == .table }
        #expect(tables.isEmpty, "散排编号填空被聚成了 \(tables.count) 张假表 —— v1 退役被绕过")
        // 内容本身不能丢：6 行文本必须还在正文块里。
        let text = page.blocks.map(\.text).joined(separator: "\n")
        for line in lines {
            #expect(text.contains(line.text), "编号行被误剔出产物：\(line.text)")
        }
    }

    // MARK: - ⑤ 金标准丢字追踪（T015 / FR-004 / FR-006）

    /// US2 独立可测承诺："wrong bus!" 出现在导出文本，**或**哨兵报告该区域的
    /// likelyMissed 证据。金标准取证（2026-09-23）：该文本在两条通路的
    /// 故事块里**从未丢失**（T008 已定性此前的「丢失」判定是全角 ！ 的
    /// ASCII 检索假阴性），所以主断言走「文本在」分支，故事块其余文本
    /// 一并钉完整。检索用去全部空白折叠（WPS 原文 "wrong    bus!"、
    /// OCR 原文 "wrong bus！" 都折成 "wrongbus…"；锚点刻意不含叹号，
    /// 避开全角/半角标点差异）。
    @Test("金标准丢字追踪：wrong bus! 在两条通路的产物里都在，故事文本完整")
    func wrongBusSurvivesExportOnBothPaths() async throws {
        let anchors: [(fragment: String, name: String)] = [
            ("wrongbus", "丢字锚点"),
            ("Onthedayofthescho", "故事首行"),
            ("excursion", "故事中段")
        ]
        let paths: [(label: String, page: ReconstructPage)] = [
            ("默认通路", try await GoldenParseCache.shared.defaultPathPage()),
            ("几何通路", try await GoldenParseCache.shared.geometricPathPage())
        ]
        for path in paths {
            let text = Self.squeezed(path.page.blocks.map(\.text).joined(separator: "\n"))
            for anchor in anchors {
                #expect(
                    text.contains(anchor.fragment),
                    "\(path.label)：故事\(anchor.name)「\(anchor.fragment)」丢失"
                )
            }
        }
    }

    /// 哨兵在金标准页的行为证据（复现 T013 导出前对账计算：`InkRegionProvider`
    /// → `InkTextReconciler.reconcile(page:inkRegions:)`，与
    /// `ReconstructViewModel.export()` 逐页执行的同一条链）：
    /// - "wrong bus" 行的墨迹被行框解释 → 该行区域**不得**出现在 likelyMissed
    ///   —— 丢字防护的两面：真丢了要报得出来（下方非平凡断言），没丢的
    ///   不能误报（本断言）；
    /// - 哨兵在真实页上非平凡：figureOverlap（漫画条大 figure #7）与
    ///   likelyMissed（填空下划线/页边号等行外墨迹）都有产出。
    ///
    /// 断言只钉结构性下限，不钉精确计数（2026-09-23 金标准取证值：
    /// gaps 33 = figureOverlap 15 / structureSwallow 0 / edgeBand 3 /
    /// likelyMissed 15 —— 精确值随 OCR/检测器小版本漂移，钉死即脆断）。
    /// 用几何通路页（取证同款接线；默认通路的哨兵接线本身由
    /// `ReconstructViewModelTests` 钉住，这里不重复）。
    @Test("金标准哨兵：wrong bus 行不误报 likelyMissed，报告非平凡")
    func sentinelExplainsStoryInkOnGoldenPage() async throws {
        let page = try await GoldenParseCache.shared.geometricPathPage()
        let ink = InkRegionProvider().inkRegions(imageURL: try Self.goldenImage())
        #expect(!ink.isEmpty, "金标准页墨迹提取为空，哨兵链路坏了")
        let report = InkTextReconciler.reconcile(page: page, inkRegions: ink)

        #expect(report.count(of: .figureOverlap) >= 1, "漫画条大 figure 的墨应归因 figureOverlap")
        #expect(report.count(of: .likelyMissed) >= 1, "行外墨迹（下划线/页边号）应产出 likelyMissed 证据")

        // "wrong bus" 行区域不得被 likelyMissed 实质覆盖（行框 padding 0.003
        // 与相邻下划线墨迹可能有一线之交 → 允许 < 10% 行面积的擦边交集）。
        let wrongBusFrame = try wrongBusLineFrame(in: page)
        for gap in report.likelyMissedGaps {
            let intersection = gap.frame.intersection(wrongBusFrame)
            guard !intersection.isNull else { continue }
            let ratio = intersection.width * intersection.height
                / (wrongBusFrame.width * wrongBusFrame.height)
            #expect(
                ratio < 0.1,
                "wrong bus 行区域被 likelyMissed 覆盖 \(ratio)：行墨迹未被解释，丢字防护误报"
            )
        }
    }

    /// 镜像 `InkTextReconciler.lineRegions` 的行框重建，定位 "wrong bus" 行。
    /// `BlockLine` 是块相对几何（首行顶 = 块顶、下行顶 = 上行底 − gap），
    /// 页框 = 块 bbox + 行偏移逐行下移，口径与对账内部完全一致。
    private func wrongBusLineFrame(in page: ReconstructPage) throws -> CGRect {
        let storyBlock = try #require(
            page.blocks.first { Self.squeezed($0.text).contains("wrongbus") },
            "金标准页找不到 wrong bus 故事块"
        )
        let lines = try #require(storyBlock.lines, "故事块缺行几何")
        let target = try #require(
            lines.firstIndex { Self.squeezed($0.text).contains("wrongbus") },
            "故事块行里找不到 wrong bus 行"
        )
        var previousMinY = storyBlock.bbox.maxY
        for (index, line) in lines.enumerated() {
            let top = previousMinY - CGFloat(line.gapToPrevious)
            let y = top - CGFloat(line.height)
            if index == target {
                return CGRect(
                    x: storyBlock.bbox.minX + CGFloat(line.leadingOffset),
                    y: y,
                    width: CGFloat(line.width),
                    height: CGFloat(line.height)
                )
            }
            previousMinY = y
        }
        throw CocoaError(.fileNoSuchFile)  // unreachable：target < lines.count
    }

    // MARK: - ⑥ US3 漫画条 figure 检测（T016）

    /// T016：fixture 上漫画条被检出为**单一** figure（不拆碎、不漏检）。
    /// T008 取证：默认通路 10 块 = 8 文本 + 2 figure —— #4 漫画条
    /// （x:0.417 y:0.312 w:0.083 h:0.146，140×321 px，与 WPS srcRect 精确对应，
    /// 金标准 [image]①）+ #7 右侧大图（0.517, 0.076, 0.417×0.796，[image]②）。
    /// 检索用**中心点落带**而非相交：#7 左缘（x 0.517）与漫画条查询带右缘
    /// 仅隔 0.003，相交判据会把大图误算进漫画条。几何断言给 ±30% 量级
    /// 容差（细长竖条 ~0.08×0.15），不钉死精确值防检测器微漂脆断。
    @Test("金标准默认通路：漫画条检出为单一 figure（不拆碎不漏检）")
    func comicStripIsASingleUnfragmentedFigureOnDefaultPath() async throws {
        let page = try await GoldenParseCache.shared.defaultPathPage()
        // 漫画条查询带（T008 #4 几何外扩容忍带）
        let comicZone = CGRect(x: 0.38, y: 0.26, width: 0.15, height: 0.24)
        let figures = page.blocks.filter { $0.kind == .figure }
        #expect(!figures.isEmpty, "默认通路零 figure，配图通道坏了")

        let comicFigures = figures.filter { comicZone.contains(CGPoint(x: $0.bbox.midX, y: $0.bbox.midY)) }
        #expect(
            comicFigures.count == 1,
            "漫画条区域应有恰一个 figure（实际 \(comicFigures.count) 个：\(figures.map(\.bbox))）"
        )
        let comic = try #require(comicFigures.first)
        // 细长竖条量级：宽 ~0.083（140px）、高 ~0.146（321px）
        #expect(comic.bbox.width > 0.055 && comic.bbox.width < 0.11, "漫画条宽异常：\(comic.bbox.width)")
        #expect(comic.bbox.height > 0.10 && comic.bbox.height < 0.19, "漫画条高异常：\(comic.bbox.height)")

        // 右侧大图（金标准 [image]②）也在 —— 两图段都有权威 figure 表示
        #expect(
            figures.contains { $0.bbox.width > 0.3 },
            "右侧大图 figure 缺失（金标准 [image]②）"
        )
    }

    // MARK: - ⑦ US3 漫画条流式档内联 + 阅读序原位（T017）

    /// T017：US3 独立可测承诺的导出侧钉——流式档（structured）里漫画条
    /// **单张完整内联**且阅读序位置与金标准 [image]① 一致。
    /// 取证（2026-09-23 默认通路 + structured 导出，10 段）：
    /// 段落序 = 左栏 41 行大块（'…8 We decided…'）→ [DRAWING 漫画条] →
    /// 'Complete the text with…' → 'A terrible trip!' → [DRAWING 大图] →
    /// 故事块 → '2 At school' —— 漫画条内联恰落金标准 [image]① 的位置。
    /// 两张图用 wp:extent 的 cy 尺寸类区分：漫画条 ~3.56M EMU（374px ≥
    /// 检出框全高 321px → 完整性下限）vs 右侧大图 ~7.32M EMU，间隙足够宽。
    /// 锚点检索用去空白折叠 + 刻意避开首字母大小写（'edecided'/
    /// 'ompletethetextwith'，OCR/WPS 的大小写不稳定）。
    /// 已知差异（记录不修，详录 implementation-notes.md）：右侧大图按
    /// maxY 降序装配排在故事块**前**（其顶缘 y 0.876 高于故事块顶缘），
    /// 金标准 [image]② 在故事块后 —— 属 assemble 全局排序的既有语义
    /// （大图是纵贯故事区的背景插画，前后语义均通），不在 US3 验收范围。
    @Test("金标准流式档：漫画条单张完整内联且阅读序原位（金标准 [image]①）")
    func comicStripInlinesCompleteInFlowDocxReadingOrder() async throws {
        let page = try await GoldenParseCache.shared.defaultPathPage()
        let document = ReconstructDocument(documentID: UUID(), title: "金标准-漫画条内联", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "golden-comic-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 恰两张内联图：漫画条（[image]①）+ 右侧大图（[image]②）
        let drawingCount = DocxProbe.count(of: "<w:drawing>", in: xml)
        #expect(drawingCount == 2, "流式档应恰两张内联图（实际 \(drawingCount)）")

        // 段落切分："<w:p>" 前缀 → 组件 0 是 XML 前导（不含正文锚点），段落体从 1 起
        let bodies = xml.components(separatedBy: "<w:p>")
        let paragraphText: (String) -> String = { body in
            Self.squeezed(body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }

        // 漫画条内联图：cy ∈ (2M, 5M) 尺寸类恰一个（与大图 ~7.3M 分离清晰）
        let comicIndexes = bodies.indices.filter { index in
            guard bodies[index].contains("<w:drawing>"),
                  let cy = Self.drawingExtentCY(in: bodies[index]) else { return false }
            return cy > 2_000_000 && cy < 5_000_000
        }
        #expect(comicIndexes.count == 1, "漫画条尺寸类应恰一个内联图（实际 \(comicIndexes.count)）")
        let comicIndex = try #require(comicIndexes.first)
        #expect(bodies[comicIndex].contains("<wp:inline"), "漫画条必须是内联图（流式档段落流语义）")

        // 完整性下限：drawing 高度 ≥ 检出框全高（140×321px → 321px × 9525 EMU/px）
        let comicCY = try #require(Self.drawingExtentCY(in: bodies[comicIndex]))
        #expect(comicCY >= 321 * 9525, "漫画条内联高度 \(comicCY) EMU 低于检出框全高 321px —— 抠图不完整")

        // 右侧大图（金标准 [image]②）也在 —— 两图段各有权威内联表示
        #expect(
            bodies.indices.contains { index in
                guard index != comicIndex, bodies[index].contains("<w:drawing>"),
                      let cy = Self.drawingExtentCY(in: bodies[index]) else { return false }
                return cy > 5_000_000
            },
            "右侧大图内联缺失（金标准 [image]②）"
        )

        // 阅读序原位：左栏收尾（'8 We decided…'）之后、故事区起点（'Complete the text with…'）之前
        let leftEndIndex = try #require(
            bodies.firstIndex { paragraphText($0).contains("edecided") },
            "流式档里找不到左栏收尾文本（'We decided'）"
        )
        let storyStartIndex = try #require(
            bodies.firstIndex { paragraphText($0).contains("ompletethetextwith") },
            "流式档里找不到故事区起点（'Complete the text with'）"
        )
        #expect(leftEndIndex < comicIndex, "漫画条内联排到了左栏文本之前 —— 阅读序错位")
        #expect(comicIndex < storyStartIndex, "漫画条内联排到了故事区之后 —— 阅读序错位")
    }

    // MARK: - ⑧ US4 段落粒度与阅读序对照（T019）

    /// US4 独立可测承诺：流式档段落粒度收敛金标准 ±30%（42 段量级）。
    /// 金标准 = `docs/fixtures/golden-wps-reading-order.txt` 的 42 个非空文本段
    /// （44 行 − 2 个 [image] 行）；收敛带 [29.4, 54.6]。取证值（2026-09-24
    /// 探针，`FlowParagraphSplitter` 接线后）：8 文本块 → **32 文本段** +
    /// 2 图段 = 34 个 w:p，偏差 −23.8% —— 左栏 41 行大块按条目号/回撤/句界
    /// 细化，第 2 节条目 1~8 每条一段与金标准逐条对齐。
    @Test("金标准流式档：段落粒度收敛金标准 ±30%（42 段量级）")
    func flowDocxParagraphCountConvergesToGolden() async throws {
        let page = try await GoldenParseCache.shared.defaultPathPage()
        let document = ReconstructDocument(documentID: UUID(), title: "金标准-段落粒度", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "golden-paragraphs-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)

        // 文本段 = 非 DRAWING 且去标签后非空（组件 0 是 XML 前导，不是段落体）
        let textParagraphs = xml.components(separatedBy: "<w:p>").dropFirst().filter { body in
            !body.contains("<w:drawing>")
                && !Self.squeezed(
                    body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                ).isEmpty
        }
        let golden = 42.0
        let count = Double(textParagraphs.count)
        #expect(
            count >= golden * 0.7,
            "流式档文本段 \(Int(count)) 低于金标准 ±30% 下沿 \(golden * 0.7) —— 段落仍过合并"
        )
        #expect(
            count <= golden * 1.3,
            "流式档文本段 \(Int(count)) 超过金标准 ±30% 上沿 \(golden * 1.3) —— 段落过碎"
        )
    }

    /// US4 阅读序锚点链：全页关键锚点在流式档段落流里保持金标准文档序。
    /// 主链（金标准 7~50 行）：页标题 → 对话引言 → 动词框 → 对话条目 1 →
    /// 第 2 节标题 → 条目 1 → 条目 8 → 故事引言 → 故事标题 → 故事首行 →
    /// wrong bus → 页脚；另钉两个图段的 slot：漫画条（金标准 [image]①）在
    /// 条目 8 与故事引言之间，右侧大图（[image]②）在故事标题与页脚之间。
    /// 已知偏序（T017 记录不修）：assemble 把大图排在故事块**前**（金标准在
    /// 后），故不钉大图与故事文本行的相对位置，只钉「故事标题 < 大图 < 页脚」
    /// 的包含关系。检索口径 = 去全部空白折叠 + 小写（OCR/WPS 的空格形态与
    /// 大小写都不稳定：'Yesterday l'/'Yesterdayl'、'used to enjoy' 折叠后同源）；
    /// 锚点避开 the/a 类功能词（'completethedialogues' vs 'completedialogues'
    /// 的 OCR 变体用 'dialogueswith' 兜住）。
    @Test("金标准流式档：全页阅读序锚点链与金标准一致")
    func flowDocxReadingOrderAnchorsMatchGolden() async throws {
        let page = try await GoldenParseCache.shared.defaultPathPage()
        let document = ReconstructDocument(documentID: UUID(), title: "金标准-阅读序锚点", pages: [page])
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "golden-anchors-\(UUID().uuidString).docx",
            tier: .structured
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        let bodies = xml.components(separatedBy: "<w:p>")

        let paragraphText: (Int) -> String = { index in
            Self.squeezed(
                bodies[index].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            ).lowercased()
        }
        func anchorIndex(_ fragment: String, _ name: String) throws -> Int {
            try #require(
                bodies.indices.first { paragraphText($0).contains(fragment) },
                "流式档里找不到锚点「\(name)」（\(fragment)）"
            )
        }

        let mainChain: [(fragment: String, name: String)] = [
            ("grammar", "页标题"),
            ("dialogueswith", "对话引言"),
            ("doearn", "动词框"),
            ("doingthosephysics", "对话条目 1"),
            ("continuousandusedto", "第 2 节标题"),
            ("usedtoenjoy", "第 2 节条目 1"),
            ("edecided", "第 2 节条目 8"),
            ("ompletethetextwith", "故事引言"),
            ("aterribletrip", "故事标题"),
            ("onthedayofthescho", "故事首行"),
            ("wrongbus", "wrong bus 行"),
            ("2atschool", "页脚")
        ]
        var previous = try anchorIndex(mainChain[0].fragment, mainChain[0].name)
        for anchor in mainChain.dropFirst() {
            let index = try anchorIndex(anchor.fragment, anchor.name)
            #expect(
                previous < index,
                "阅读序错位：「\(anchor.name)」应在上一锚点之后（段落 \(previous) !< \(index)）"
            )
            previous = index
        }

        // 漫画条 [image]① 的 slot：条目 8 之后、故事引言之前
        let comicIndex = try #require(
            bodies.indices.first { index in
                guard bodies[index].contains("<w:drawing>"),
                      let cy = Self.drawingExtentCY(in: bodies[index]) else { return false }
                return cy > 2_000_000 && cy < 5_000_000
            },
            "漫画条内联图缺失（cy 2M~5M 尺寸类零命中）"
        )
        let item8 = try anchorIndex("edecided", "第 2 节条目 8")
        let storyIntro = try anchorIndex("ompletethetextwith", "故事引言")
        #expect(
            item8 < comicIndex && comicIndex < storyIntro,
            "漫画条不在条目 8 与故事引言之间 —— 阅读序错位"
        )

        // 右侧大图 [image]② 的包含关系（偏序容忍，见方法注释）
        let bigImageIndex = try #require(
            bodies.indices.first { index in
                guard bodies[index].contains("<w:drawing>"),
                      let cy = Self.drawingExtentCY(in: bodies[index]) else { return false }
                return cy > 5_000_000
            },
            "右侧大图内联缺失（cy > 5M 尺寸类零命中）"
        )
        let storyTitle = try anchorIndex("aterribletrip", "故事标题")
        let footer = try anchorIndex("2atschool", "页脚")
        #expect(storyTitle < bigImageIndex, "右侧大图排到了故事标题之前 —— 阅读序错位")
        #expect(bigImageIndex < footer, "右侧大图排到了页脚之后 —— 阅读序错位")
    }

    /// 去全部空白（含全角空格）—— containment 覆盖判定与丢字锚点检索共用口径。
    private static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// 从段落体抠 `<wp:extent cx="…" cy="…"/>` 的 cy（EMU）。图段落里
    /// wp:extent 是第一个 extent 标签（wp:effectExtent 用 l/t/r/b 属性，
    /// a:ext 的 cy 与 wp:extent 同值，任取其一皆可）。
    private static func drawingExtentCY(in body: String) -> Int? {
        guard let extentStart = body.range(of: "wp:extent cx=\"") else { return nil }
        let rest = body[extentStart.upperBound...]
        guard let cxEnd = rest.firstIndex(of: "\"") else { return nil }
        let afterCX = rest[rest.index(after: cxEnd)...]
        guard let cyStart = afterCX.range(of: "cy=\"") else { return nil }
        let afterCY = afterCX[cyStart.upperBound...]
        guard let cyEnd = afterCY.firstIndex(of: "\"") else { return nil }
        return Int(afterCY[..<cyEnd])
    }
}

// MARK: - 金标准解析缓存（真实 Vision，昂贵，跨用例共享）

/// 金标准页的两种真实接线各解析一次：
/// - 默认接线 = 生产配置（`AppEnvironment` 的 `VisionTextRecognizer` + `VisionDocumentStructureRecognizer`）；
/// - 几何接线 = 不注入结构化识别器（iOS 18/25 的真实情形）。
///
/// 并发安全（2026-09-24 修复，wps-parity-layout T018）：套件内用例**并行**首调
/// 时，「查缓存 → parse（await）→ 存结果」之间的窗口会让多个调用各自发起
/// 真实 parse；而 `OnDeviceDocumentParser.parse` 每次都先清空
/// `cropDirectory(pageID)` 再重写裁图 —— 并发 parse 对同一目录交错
/// 「清空/写文件」，后到的一次清空会把先写的裁图 unlink 成悬空路径，缓存页
/// 的 `figureRelativePath` 从此指向不存在的文件，导出静默丢内联图
/// （`comicStripInlinesCompleteInFlowDocxReadingOrder` 双执行偶发红：冷跑
/// 导出赶在好时机两图俱全，热跑读到竞态残局只剩大图）。两层修复：
/// ① 在飞 Task 去重 —— 同一通路并发首调只发起一次 parse，全体等同一结果
///    （失败不驻留：清掉在飞槽位，下一个调用重新解析，保持原重试语义；
///    generation 防止后来者的新 Task 被旧的失败清理误删）；
/// ② 两条通路各用独立固定 pageID —— 裁图目录按 pageID 隔离，几何通路的
///    parse 不再抹掉默认通路已写的裁图。默认通路保持 `goldenPageID`
///    （T008 / 真机验收按它检索 reconstructPath 决策线），几何通路用 …0002。
private actor GoldenParseCache {
    static let shared = GoldenParseCache()

    /// 几何通路专属固定 pageID（与默认通路隔离，见类型注释②）。
    private static let geometricPageID = UUID(uuidString: "D077A5E7-0000-4000-8000-000000000002")!

    private var defaultPageTask: Task<ReconstructPage, Error>?
    private var geometricPageTask: Task<ReconstructPage, Error>?
    private var defaultGeneration = 0
    private var geometricGeneration = 0

    func defaultPathPage() async throws -> ReconstructPage {
        let generation = defaultGeneration
        let task: Task<ReconstructPage, Error>
        if let existing = defaultPageTask {
            task = existing
        } else {
            task = Task {
                let parser = OnDeviceDocumentParser(
                    recognizer: VisionTextRecognizer(),
                    structureRecognizer: VisionDocumentStructureRecognizer()
                )
                return try await parser.parse(
                    imageURL: try GoldenWorksheetEndToEndTests.goldenImageThrowing(),
                    pageID: GoldenWorksheetEndToEndTests.goldenPageID,
                    scene: .auto
                )
            }
            defaultPageTask = task
        }
        do {
            return try await task.value
        } catch {
            if generation == defaultGeneration {
                defaultPageTask = nil
                defaultGeneration += 1
            }
            throw error
        }
    }

    func geometricPathPage() async throws -> ReconstructPage {
        let generation = geometricGeneration
        let task: Task<ReconstructPage, Error>
        if let existing = geometricPageTask {
            task = existing
        } else {
            task = Task {
                let parser = OnDeviceDocumentParser(recognizer: VisionTextRecognizer())
                return try await parser.parse(
                    imageURL: try GoldenWorksheetEndToEndTests.goldenImageThrowing(),
                    pageID: Self.geometricPageID,
                    scene: .auto
                )
            }
            geometricPageTask = task
        }
        do {
            return try await task.value
        } catch {
            if generation == geometricGeneration {
                geometricPageTask = nil
                geometricGeneration += 1
            }
            throw error
        }
    }
}

// MARK: - 支撑

private extension GoldenWorksheetEndToEndTests {
    /// actor 缓存内部取图（actor 隔离上下文里不能直接调 throwing static 属性）。
    static func goldenImageThrowing() throws -> URL {
        let url = ReconstructSampleImage.url("grammar-worksheet.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }
}

private extension URL {
    /// 与 `ReconstructSampleImage.nutritionMango()` 同款存在性检查，但报错而非返回 optional。
    func requireExists() throws -> URL {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        return self
    }
}

/// 返回固定 OCR 结果的替身（`ReconstructEndToEndTests.FixedRecognizer` 是 private，本文件自带一份）。
private struct FixedOCRRecognizer: TextRecognizing {
    let lines: [OCRLine]
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: lines)
    }
}

/// 可控的结构化识别替身（`DocumentStructureTests.StubStructureRecognizer` 是 private，本文件自带一份）。
private struct FixedStructureRecognizer: DocumentStructureRecognizing {
    let result: StructuredDocumentPage?
    func recognize(imageURL: URL, pageID: UUID) async -> StructuredDocumentPage? { result }
}
