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
    /// M4：当前选中的导出档位（A / B / C）。默认 A（结构化）。
    ///
    /// 档位**同时**影响两件事：① 导出的 Word 产物；② 页面预览的渲染方式。
    /// 早期版本档位只作用于 ①，预览永远是结构化块流 —— 用户切 A/B/C 看到画面纹丝不动，
    /// 直接反馈「选了没反应」。现在 `ReconstructView.preview` 按档位分三种渲染。
    var outputTier: R2OutputTier = .structured

    /// 切换档位。必须走这个方法而不是直接赋值：
    /// 切档后旧产物即失效 —— 若不清 `docxURL`，导出按钮会一直是 ShareLink，
    /// 点了分享的是上一次的老文件，用户就会觉得「切了档但没变化」。
    func setTier(_ tier: R2OutputTier) {
        guard tier != outputTier else { return }
        outputTier = tier
        docxURL = nil
    }

    private let document: ScanDocument
    private let scanPages: [ScanPage]
    private let fileStore: any PageFileStoring
    private let parser: any DocumentParsing
    private let docx: any DocxRendering
    private let searchablePDF: any SearchablePDFRendering

    init(
        document: ScanDocument,
        scanPages: [ScanPage],
        fileStore: any PageFileStoring,
        parser: any DocumentParsing,
        docx: any DocxRendering,
        searchablePDF: any SearchablePDFRendering
    ) {
        self.document = document
        self.scanPages = scanPages
        self.fileStore = fileStore
        self.parser = parser
        self.docx = docx
        self.searchablePDF = searchablePDF
    }

    var blocks: [ReconstructBlock] {
        reconstructed?.pages.flatMap(\.blocks) ?? []
    }

    /// B / C 档预览要按页还原版面位置，所以这里暴露**按页**的结果，
    /// 而不是 A 档那种全文档拍平的块流。
    var pages: [ReconstructPage] {
        reconstructed?.pages ?? []
    }

    /// C 档（衬底图）需要页面原图。
    /// 取 `.rendered` 而不是 `.original` —— 与 OCR 同源（见 2026-09-08 真机回归 R1：
    /// 版面坐标是相对 rendered 图算的，拿 original 会对不上）。
    func pageImageURL(for pageID: UUID) -> URL? {
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
                if let parsed = await parse(url: candidate, pageID: page.id) {
                    parsedPage = parsed
                    break
                }
            }
            if let parsedPage {
                pages.append(parsedPage)
            } else {
                pages.append(
                    ReconstructPage(pageID: page.id, size: .zero, scene: .plain, usedCloud: false, blocks: [])
                )
            }
        }
        let result = ReconstructDocument(documentID: document.id, title: document.title, pages: pages)
        reconstructed = result
        if !result.hasContent {
            error = .reconstructFailed
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
            store(try await make(reconstructed))
        } catch {
            self.error = .exportFailed
        }
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
