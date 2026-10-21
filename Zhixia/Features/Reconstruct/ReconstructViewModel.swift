import Foundation

@MainActor
@Observable
final class ReconstructViewModel {
    var reconstructed: ReconstructDocument?
    var isWorking = false
    var error: ZhixiaError?
    var docxURL: URL?
    var pdfURL: URL?
    var isExporting = false
    /// 当前选中的导出档位（流式 / 高保真 / 图片版，spec/wps-parity-layout plan D1/FR-001、
    /// spec/word-fidelity T002/FR-002）。
    ///
    /// **默认图片版**（`ExportTier.defaultTier`）——WPS 的 Word 导出实测就是页面图
    /// （docs/16 §二），且浮点重建在复杂页面上不可靠（用户实测「样式会乱」）。
    /// 进入页面时 `ReconstructView` 会用持久化偏好覆盖它（`setTier`）。
    var outputTier: R2OutputTier = ExportTier.defaultTier.outputTier

    /// 切换档位。必须走这个方法而不是直接赋值：
    /// 切档后旧产物即失效 —— 若不清 `docxURL`，导出按钮会一直是 ShareLink，
    /// 点了分享的是上一次的老文件，用户就会觉得「切了档但没变化」。
    ///
    /// 切档**不重跑 parse**（plan D9）：两个档共用同一次解析产物（含底座路径），
    /// 切档只是换渲染方式与导出分支。
    func setTier(_ tier: R2OutputTier) {
        guard tier != outputTier else { return }
        outputTier = tier
        docxURL = nil
        ZhixiaLog.reconstructTier(tier, isDefault: tier == .structured)
    }

    /// US4 / R3（spec/scan-fidelity plan D4）：重建成功后的全文回填回调。
    /// `reconstruct()` 成功且 `hasContent` 时触发**一次**；失败 / 空产物不触发。
    /// `ReconstructView.task` 在调用 `reconstruct()` 之前接线（T017），由
    /// `DocumentView` 接到 `DocumentViewModel.applyOCRBlob` —— 与手动 OCR 同一条
    /// 落库路径（含「标题含『扫描』才改写」防覆盖语义），重建完成的文档
    /// 直接可全文检索、标题自动更新。
    var onContentReady: ((String) -> Void)?

    private let document: ScanDocument
    private let scanPages: [ScanPage]
    private let fileStore: any PageFileStoring
    private let parser: any DocumentParsing
    private let docx: any DocxRendering
    private let searchablePDF: any SearchablePDFRendering
    /// 墨迹提取（FR-006 哨兵证据源，T013 接线）。默认 `InkRegionProvider()`：
    /// 既有调用点（ReconstructView / 测试替身）不传即得生产行为，注入替身可控墨迹。
    private let inkRegions: any InkRegionProviding

    init(
        document: ScanDocument,
        scanPages: [ScanPage],
        fileStore: any PageFileStoring,
        parser: any DocumentParsing,
        docx: any DocxRendering,
        searchablePDF: any SearchablePDFRendering,
        inkRegions: any InkRegionProviding = InkRegionProvider()
    ) {
        self.document = document
        self.scanPages = scanPages
        self.fileStore = fileStore
        self.parser = parser
        self.docx = docx
        self.searchablePDF = searchablePDF
        self.inkRegions = inkRegions
    }

    var blocks: [ReconstructBlock] {
        reconstructed?.pages.flatMap(\.blocks) ?? []
    }

    /// B / C 档预览要按页还原版面位置，所以这里暴露**按页**的结果，
    /// 而不是 A 档那种全文档拍平的块流。
    var pages: [ReconstructPage] {
        reconstructed?.pages ?? []
    }

    /// 识别全文 blob（US4 / plan D4）：pages 各块文本聚合，按 "\n" 分行 ——
    /// 供 `DocumentViewModel.applyOCRBlob` 做全文检索回填。
    ///
    /// 取 `displayText` 而非 `text`（对 D4 字面「各块 text」的偏差，已记录在
    /// T016 日志）：表格块的行列内容只在 `displayText`（`text` 恒空串），取
    /// `text` 会把表格页聚合成空 blob，搜索失效——与 US4「重建后内容可搜」
    /// 的目标冲突。空白块（figure 无文字等）不贡献行。
    var recognizedTextBlob: String {
        let chunks = reconstructed?.pages.flatMap { page in
            page.blocks.compactMap { block -> String? in
                let text = block.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        } ?? []
        return chunks.joined(separator: "\n")
    }

    /// 版面还原档的画布底座。parse 产物注入的 `baseImageRelativePath` 优先 ——
    /// 它就是**坐标参照系**那张图（rendered 优先、original 兜底，与 parse 用图一致），
    /// 预览对位才准（见 2026-09-08 真机回归 R1）。旧产物 / 替身产物没带底座时
    /// 退回 fileStore 的 rendered 图。
    func pageImageURL(for pageID: UUID) -> URL? {
        if let base = reconstructed?.pages.first(where: { $0.pageID == pageID })?.baseImageRelativePath,
           !base.isEmpty,
           FileManager.default.fileExists(atPath: base) {
            return URL(fileURLWithPath: base)
        }
        guard scanPages.contains(where: { $0.id == pageID }) else { return nil }
        let url = fileStore.url(document: document.id, page: pageID, kind: .rendered)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var needsCloudHint: Bool {
        reconstructed?.needsCloudParsing == true
    }

    var hasContent: Bool {
        reconstructed?.hasContent == true
    }

    func reconstruct() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        ZhixiaLog.reconstructTier(outputTier, isDefault: outputTier == .structured)
        defer { isWorking = false }
        var pages: [ReconstructPage] = []
        for page in scanPages {
            // 真机回归（2026-09-07）：原来这里**优先 original**，一张原图存在就
            // 永远轮不到 rendered。而 original 是相机直出、未透视矫正、未去阴影的
            // 图，rendered 才是矫正+增强后的。OCR 跑在 original 上的后果：
            //   · 倾斜 → Vision 行切分错乱（营养表出现「17%蛋白」这种跨行合并）
            //   · 阴影/低对比 → 字符误识（Lemice / Ahorthe / JWCe / CAKSS）
            //   · 未裁边 → 状态栏、App UI、二维码全进正文
            // 一个反直觉的后果：关掉「保留原图」开关反而还原效果更好。
            // 现在改成 rendered 优先，original 只作兜底。
            let original = fileStore.url(document: document.id, page: page.id, kind: .original)
            let rendered = fileStore.url(document: document.id, page: page.id, kind: .rendered)
            // rendered 优先，original 兜底。不做存在性检查 —— `parse` 读不到图
            // 自然返回 nil，交给下一候选即可（顺带兼容「页面本身无文字」的情况）。
            var parsedPage: ReconstructPage?
            for candidate in [rendered, original] {
                if var parsed = await parse(url: candidate, pageID: page.id) {
                    // 底座注入（spec/layout-restore plan D2/D9）：底座 = parse 实际用的那张图
                    // （坐标参照系），文件真实存在才注入 —— 双档共用同一次产物，切档只重渲染。
                    parsed.baseImageRelativePath = fileExists(candidate) ? candidate.path : nil
                    ZhixiaLog.reconstructBaseImage(
                        path: parsed.baseImageRelativePath,
                        pixelWidth: Int(parsed.size.width),
                        pixelHeight: Int(parsed.size.height)
                    )
                    parsedPage = parsed
                    break
                }
            }
            if let parsedPage {
                pages.append(parsedPage)
            } else {
                ZhixiaLog.reconstructBaseImage(path: nil, pixelWidth: 0, pixelHeight: 0)
                pages.append(
                    ReconstructPage(pageID: page.id, size: .zero, scene: .plain, usedCloud: false, blocks: [])
                )
            }
        }
        let result = ReconstructDocument(documentID: document.id, title: document.title, pages: pages)
        reconstructed = result
        if !result.hasContent {
            error = .reconstructFailed
        } else {
            // US4 / plan D4：成功且 hasContent 才回填全文 blob（本次重建恰一次）；
            // 失败 / 空产物不触发 —— 避免「离开即写、失败态误写半截内容」。
            onContentReady?(recognizedTextBlob)
        }
    }

    func exportDocx() async {
        await export { doc in
            try await docx.makeDocx(doc, fileName: fileName(extension: "docx"), tier: outputTier)
        } store: { docxURL = $0 }
    }

    func exportPDF() async {
        await export { doc in
            try await searchablePDF.makeSearchablePDF(doc, fileName: fileName(extension: "pdf"))
        } store: { pdfURL = $0 }
    }

    func cleanupExports() {
        if let docxURL {
            try? FileManager.default.removeItem(at: docxURL)
        }
        if let pdfURL {
            try? FileManager.default.removeItem(at: pdfURL)
        }
        docxURL = nil
        pdfURL = nil
    }

    private func parse(url: URL, pageID: UUID) async -> ReconstructPage? {
        do {
            let page = try await parser.parse(imageURL: url, pageID: pageID, scene: .auto)
            return page.hasContent ? page : nil
        } catch {
            return nil
        }
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func export(
        _ make: (ReconstructDocument) async throws -> URL,
        store: (URL) -> Void
    ) async {
        guard let reconstructed, reconstructed.hasContent else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            // FR-006（T013）：导出前逐页墨迹-文本对账 —— 只记日志，不阻断，
            // 对账自身异常也不让导出失败（内部吞掉，见 `runTextSentinel`）。
            await runTextSentinel()
            store(try await make(reconstructed))
        } catch {
            self.error = .exportFailed
        }
    }

    /// 丢字哨兵（FR-006 / plan D5，T013 接线）：导出前逐页对账
    /// 「原页墨迹（`InkRegionProviding`）vs 文字层（`InkTextReconciler`）」，
    /// 缺口四分类计数进 `ZhixiaLog.textSentinel`（每页一条）。
    ///
    /// - **只记不阻断**：墨迹为空（图不可解码 / 无墨）→ 零缺口报告照常记；
    /// - 墨迹取 `pageImageURL` —— 即 parse 用图（`baseImageRelativePath` 优先），
    ///   与块 bbox 同一坐标参照系；
    /// - 解码/栅格化是百毫秒级 CPU 活：主线程只解析 URL，重活丢后台线程，
    ///   不卡导出按钮。
    private func runTextSentinel() async {
        guard let reconstructed else { return }
        let entries: [(index: Int, page: ReconstructPage, imageURL: URL?)] =
            reconstructed.pages.enumerated().map { index, page in
                (index, page, pageImageURL(for: page.pageID))
            }
        let provider = inkRegions
        await Task.detached(priority: .utility) {
            for entry in entries {
                let ink = entry.imageURL.map { provider.inkRegions(imageURL: $0) } ?? []
                let report = InkTextReconciler.reconcile(page: entry.page, inkRegions: ink)
                ZhixiaLog.textSentinel(
                    page: entry.index,
                    gaps: report.gaps.count,
                    figureOverlap: report.count(of: .figureOverlap),
                    structureSwallow: report.count(of: .structureSwallow),
                    edgeBand: report.count(of: .edgeBand),
                    likelyMissed: report.count(of: .likelyMissed)
                )
            }
        }.value
    }

    private func fileName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let slug = document.title
            .replacingOccurrences(of: "/", with: "-")
            .prefix(24)
        return "Zhixia-\(slug)-\(formatter.string(from: Date())).\(ext)"
    }
}
