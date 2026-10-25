import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// DOCX 导出（双档，spec/layout-restore plan D7/D9）：
/// - `.structured`：流式段落重排（A4 固定页）；
/// - `.restored`：与 LayoutCanvas 预览同构的版面还原（FR-009）—— 每页独立动态
///   sectPr + **净化底图**（擦除已烘进像素，内联铺页）+ 浮动文本框（可编辑，
///   FR-007）+ figure/barcode/artwork 的 srcRect 裁剪复用（每页 media 单图，FR-010）
///   + 表格原生浮动（`w:tblpPr` 原位，US5/FR-008，不套文本框）。
///   EMU 定位 / Vision y 翻转全部经 `PageLayoutMapper`（posOffset 误用 twips 的
///   旧 B 档事故不再重演）。
actor DocxExportService: DocxRendering {
    func makeDocx(_ document: ReconstructDocument, fileName: String, tier: R2OutputTier = .structured) async throws -> URL {
        guard document.hasContent else {
            throw ZhixiaError.reconstructFailed
        }
        var media: [(name: String, data: Data)] = []
        var imageRels: [(id: String, target: String)] = []
        var nextImage = 1
        var nextDocPr = 1
        let xml = documentXML(
            document,
            tier: tier,
            media: &media,
            imageRels: &imageRels,
            nextImage: &nextImage,
            nextDocPr: &nextDocPr
        )
        let mediaExtensions = Set(
            media.map { ($0.name as NSString).pathExtension.lowercased() }
        )
        var entries: [(name: String, data: Data)] = [
            (name: "[Content_Types].xml", data: Data(contentTypes(extensions: mediaExtensions).utf8)),
            (name: "_rels/.rels", data: Data(Self.rootRels.utf8)),
            (name: "word/_rels/document.xml.rels", data: Data(documentRels(imageRels).utf8)),
            (name: "word/styles.xml", data: Data(Self.styles.utf8)),
            (name: "word/document.xml", data: Data(xml.utf8))
        ]
        entries.append(contentsOf: media)
        let zip = ZipArchive.data(entries: entries)
        let output = FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: fileName)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try zip.write(to: output, options: .atomic)
        return output
    }

    private func documentXML(
        _ document: ReconstructDocument,
        tier: R2OutputTier,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String {
        let body: String
        switch tier {
        case .pageImage:
            body = pageImageBodyXML(
                document,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage,
                nextDocPr: &nextDocPr
            )
        case .restored:
            body = restoredBodyXML(
                document,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage,
                nextDocPr: &nextDocPr
            )
        case .structured:
            body = structuredBodyXML(
                document,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage,
                nextDocPr: &nextDocPr
            )
        }
        return Self.documentShell(body)
    }

    /// document.xml 外壳。`xmlns:wps`（Word 2010 wordprocessingShape）供版面还原档的
    /// 浮动 shape / 文本框使用；两档共用同一外壳。
    private static func documentShell(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
          <w:body>
        \(body)
          </w:body>
        </w:document>
        """
    }

    // MARK: - 图片版（.pageImage，整页图铺满页面）

    /// 图片版正文（spec/word-fidelity T002 / FR-002）：**每页 = 页面尺寸的
    /// section + 一张铺满该页的整页图**。没有浮动文本框、没有净化 mask、
    /// 没有重排 —— 页面上的一切都在图里，**样式不可能乱**。
    ///
    /// 与 WPS 的实测行为一致（docs/16 §二）：WPS 的「扫描件 → Word」产物
    /// 就是页面本身（导出预览渲染页面图，文档标记「只读」）。
    ///
    /// 页面尺寸取自**底图（page rendered 图）**的实际像素比（`page.size`），
    /// 页边距全 0 —— 图片按页面等比铺满（`aspectFill` 语义：页面比例与图
    /// 一致时为等比拉伸，比例不一致时按放置矩形铺满，不留白、不变形）。
    private func pageImageBodyXML(
        _ document: ReconstructDocument,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String {
        guard let lastPage = document.pages.last else { return "" }
        var body = ""
        var relativeHeight = 0
        for (index, page) in document.pages.enumerated() {
            let spaces = Self.pageImageSpaces(for: page)
            let cx = max(Int64(spaces.image.width.rounded()), 1)
            let cy = max(Int64(spaces.image.height.rounded()), 1)
            var runs = ""
            // 底图 = 该页的 rendered 图（透视矫正 + 增强后的整页）。
            if let path = page.baseImageRelativePath, !path.isEmpty,
               let base = registerImageMedia(
                   path: path,
                   media: &media,
                   imageRels: &imageRels,
                   nextImage: &nextImage
               ) {
                nextDocPr += 1
                runs += inlinePictureXML(
                    relID: base.relID,
                    name: base.fileName,
                    cx: cx,
                    cy: cy,
                    docPrID: nextDocPr
                )
            }
            // 承载段落：行高**钉成图高**（`lineRule="exact"`）——行盒既不被
            // 段落标记的字号压扁（那会把内联图裁成一条线 → 渲染出空白页），
            // 也不比图高（那会把整页图挤到第二页 → 预览器只显示空白的第一页）。
            // 行高 = 图高 → 行盒恰好等于页面高度 → 图**精确铺满整页**（无白边、
            // 无错位，SSIM 才可能过门限）。
            let lineTwips = max(1, Int((Double(cy) / 635.0).rounded()))
            body += "<w:p><w:pPr>"
                + "<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(lineTwips)\" w:lineRule=\"exact\"/>"
                + "</w:pPr>"
                + runs
                + "</w:p>"
            if index < document.pages.count - 1 {
                body += sectionBreakXML(sectionPropertiesXML(emuSize: spaces.page))
            }
        }
        body += sectionPropertiesXML(emuSize: Self.pageImageSpaces(for: lastPage).page)
        return body
    }

    /// A4 贴合尺寸（共用）：按源比例把页面等比放进 A4 纸面（不拉伸）。
    /// 图片更宽 → 宽取满 A4、高按比例；更高 → 高取满 A4、宽按比例。
    private static func fittedPageEMU(for source: CGSize) -> CGSize {
        let a4 = Self.a4PageSizeEMU
        guard source.width > 0, source.height > 0 else { return a4 }
        let aspect = source.width / source.height
        let a4Aspect = a4.width / a4.height
        if aspect >= a4Aspect {
            return CGSize(width: a4.width, height: a4.width / aspect)
        }
        return CGSize(width: a4.height * aspect, height: a4.height)
    }

    /// 图片版的**页面尺寸**：A4 纸面内按图片比例**贴合**（aspect-fit）。
    ///
    /// ## 为什么不用「按像素算页面」（`.restored` 档的老口径）
    /// 老口径把页面像素按 96 DPI 换算成纸面尺寸：一张 1633×2200 的页 →
    /// **41.5cm × 55.9cm**（比 A4 大一倍）。Word 会照此建页，但**渲染器按
    /// 纸面裁切**（macOS QuickLook / 常见预览器），于是整页图只露出左上角一块
    /// ——导出产物「看起来是空的」。这正是图片版必须用 A4 贴合尺寸的原因。
    ///
    /// 贴合规则：图片更宽 → 宽取满 A4、高按比例；更高 → 高取满 A4、宽按比例。
    /// 页面与图片同比例 → 图片铺满页面且**不拉伸、不留白**。
    private static func pageImageSpaces(
        for page: ReconstructPage
    ) -> (source: CGSize, page: CGSize, image: CGSize) {
        let a4 = Self.a4PageSizeEMU
        let source = page.size
        guard source.width > 0, source.height > 0 else {
            return (source: source, page: a4, image: a4)
        }
        let fitted = Self.fittedPageEMU(for: source)
        // 页面 = 图片的贴合尺寸（**不**留余量）：承载段落的行高被钉成图高，
        // 行盒恰好等于页面高度 → 图精确铺满整页（余量会让图与页差 1%，比对时
        // 变成整体错位，SSIM 失真）。
        return (
            source: source,
            page: fitted,
            image: fitted
        )
    }

    /// 内联图片（`wp:inline`）——**图片版专用**。
    ///
    /// ## 为什么用内联而不是锚定（behindDoc）
    /// 锚定图（`wp:anchor` + `behindDoc`）在部分渲染器上不落图（macOS
    /// QuickLook 渲染出**空白页**；`.restored` 档的底图能显示是因为它同时还有
    /// 文本框等前景内容，图片是否落图被掩盖）。内联图是 OOXML 最基础的构造
    /// （Word / Pages / QuickLook / LibreOffice 一致支持）——保真优先，不冒险。
    ///
    /// 尺寸：与页面**等大**（图片即页面），承载段落行高压到 1pt（浮动/内联图
    /// 不额外占行），页边距全 0 → 图铺满整页。
    private func inlinePictureXML(
        relID: String,
        name: String,
        cx: Int64,
        cy: Int64,
        docPrID: Int
    ) -> String {
        return "<w:r><w:drawing>"
            + "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:docPr id=\"\(docPrID)\" name=\"\(name)\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"\(Self.pictureGraphicURI)\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
            + "</a:graphicData></a:graphic>"
            + "</wp:inline></w:drawing></w:r>"
    }

    private func structuredBodyXML(
        _ document: ReconstructDocument,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String {
        var body = ""
        for (index, page) in document.pages.enumerated() {
            if document.pages.count > 1 {
                body += paragraphXML(
                    String(localized: "ocr.pageHeader \(index + 1)"),
                    style: "Heading2",
                    bold: true,
                    size: 28
                )
            }
            for block in page.blocks {
                switch block.kind {
                case .heading:
                    body += paragraphXML(block.text, style: "Heading1", bold: true, size: 36)
                case .table:
                    body += tableXML(block.table) ?? paragraphXML(block.displayText, style: "Normal", bold: false, size: 24)
                case .figure, .barcode:
                    if let drawing = imageDrawingXML(
                        path: block.figureRelativePath,
                        media: &media,
                        imageRels: &imageRels,
                        nextImage: &nextImage,
                        nextDocPr: &nextDocPr
                    ) {
                        body += drawing
                    }
                    let caption = block.kind == .barcode
                        ? (block.barcodePayload ?? block.text)
                        : block.text
                    if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body += paragraphXML(caption, style: "Normal", bold: false, size: 20)
                    }
                case .artwork:
                    // 结构化档忽略 artwork 块（plan D9）：无独立裁图、无文本
                    // （乱码行已在解析层剔除），段落流里没有可表示的内容。
                    continue
                default:
                    // 流式档段落粒度（wps-parity-layout US4 / T018）：块内行按
                    // 阅读段边界切成多段发射（条目号 / 行首回撤 / 前句完结，
                    // `FlowParagraphSplitter`）；块粒度与块序不动（对话区
                    // 聚类钉 + 阅读序装配不变），无行几何的块恒等单段。
                    for paragraph in FlowParagraphSplitter.paragraphTexts(in: block) {
                        body += paragraphXML(paragraph, style: "Normal", bold: block.style.isBold, size: 24)
                    }
                }
            }
        }
        body += """
            <w:sectPr>
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/>
            </w:sectPr>

        """
        return body
    }

    // MARK: - 版面还原档（.restored，spec/layout-restore US4 / plan D7）

    /// 底座下采样上限（像素）—— 与 `LayoutCanvas.baseMaxPixelSize` 一致。
    private static let restoredBaseMaxPixelSize = 2200
    /// 净化底图 JPEG 质量：文字已被擦除，剩下的主要是版面底色/图片；0.92 在
    /// 视觉无损与 media 体积之间取平衡（栅格化后再压一次，不再叠加更高损失）。
    private static let restoredBaseJPEGQuality: CGFloat = 1.0
    /// 页尺寸退化输入（如老夹具 size == .zero）的 A4 兜底：11906×16838 twips。
    private static let a4PageSizeEMU = CGSize(width: 7_560_310, height: 10_692_130)
    private static let pictureGraphicURI = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    /// wps = Word 2010 wordprocessingShape（浮动 shape / 文本框）。
    private static let shapeGraphicURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"

    /// `.restored` 档正文：每页 = 一个承载段落（挂内联净化底图 / 浮动 shape / 文本框）
    /// + 原生浮动表格（body 级 `w:tbl`）+ 非末页分节段落；末页 sectPr 落 body 级。
    /// z 层（Word 渲染序，US5 起）：净化底图（内联，文本层）→ srcRect 保留区
    /// （behindDoc）→ 文本层（承载段落 + 原生浮动表格）→ 浮动文本框（最前）。
    /// 原生浮动表格在文本层渲染，覆盖对象若留在 behindDoc=0（最前）会整片盖住表格。
    private func restoredBodyXML(
        _ document: ReconstructDocument,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String {
        guard let lastPage = document.pages.last else { return "" }
        var body = ""
        var relativeHeight = 1
        for (index, page) in document.pages.enumerated() {
            let spaces = restoredPageSpaces(for: page)
            body += restoredPageXML(
                page,
                spaces: spaces,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage,
                nextDocPr: &nextDocPr,
                relativeHeight: &relativeHeight
            )
            if index < document.pages.count - 1 {
                body += sectionBreakXML(sectionPropertiesXML(emuSize: spaces.emu))
            }
        }
        body += sectionPropertiesXML(emuSize: restoredPageSpaces(for: lastPage).emu)
        return body
    }

    /// 页尺寸 → (源像素, EMU)。动态页与原图同比例 ⇒ 映射退化为纯线性缩放（offset = 0）。
    ///
    /// ## 已知缺陷（spec/word-fidelity G1'，下一轮处理）
    /// 本口径按 96 DPI 把像素换算成纸面：1633×2200 的页 → **41.5cm × 55.9cm**
    /// （比 A4 大一倍）。后果：① Word 里是一张怪大的纸；② 预览器按自己的画布
    /// 裁切 → 整页内容只露出左上角一块。
    ///
    /// 改成「A4 贴合」（`fittedPageEMU`，图片版已用该口径）会**改动 17 条既有
    /// 结构断言**（`DocxRestoredLayoutTests` 16 条 + `LineTypographyPerLineTests`
    /// 1 条，它们钉住了「页面 = 像素×96DPI」）——本轮**不翻**（铁律：既有断言零
    /// 修改），作为 G1' 随可编辑档迭代一起改，方案见
    /// `docs/17-editable-tier-fidelity-iteration.md`。
    private func restoredPageSpaces(for page: ReconstructPage) -> (source: CGSize, emu: CGSize) {
        if page.size.width > 0, page.size.height > 0 {
            return (source: page.size, emu: PageLayoutMapper.emuPageSize(for: page.size))
        }
        let emu = Self.a4PageSizeEMU
        return (
            source: CGSize(
                width: emu.width / PageLayoutMapper.emuPerPixel,
                height: emu.height / PageLayoutMapper.emuPerPixel
            ),
            emu: emu
        )
    }

    /// 单页 XML：承载段落挂内联净化底图 / 浮动 shape / 文本框；原生浮动表格是
    /// body 级块元素（`w:tbl` 不能作 run 内容），跟在承载段落之后、仍在该页 section 内。
    /// 有底图时行高钉成图高（内联图才不会被行盒裁成一条线，与图片版同一口径）；
    /// 无底图时行高压到最小（浮动对象不占行）。
    private func restoredPageXML(
        _ page: ReconstructPage,
        spaces: (source: CGSize, emu: CGSize),
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int,
        relativeHeight: inout Int
    ) -> String {
        // y 翻转收敛在映射里（与 LayoutCanvas 预览共用同一套换算）。
        let map = PageLayoutMapper.map(pageSize: spaces.source, targetSize: spaces.emu)
        // 版面还原档读布局后块集（spec/layout-engine plan D9 / FR-012 双档隔离）：
        // restoredBlocks = 区域布局引擎产物（跨栏拆分/碰撞位移）；nil = 旧产物退化
        // 恒等。保留区/净化底图/文本框/浮动表格四方同源同一份。
        let blocks = page.restoredBlocks ?? page.blocks
        var runs = ""
        var tables = ""
        var carriesBaseImage = false
        // 行级净化 mask 与文本框颜色同源：底图烘一次，文本 run 用同一份 fill
        // 判断深底白字/浅底黑字。无底图时保持空 mask（黑字）。
        var restoredMask = LayoutMask()

        // 1) 底图：**净化底图**（原文字区域已用环带 median 底色烘进像素）以
        //    内联图铺满动态页。内联而非锚定：QuickLook 等宿主渲染器只画内联图
        //    与文本层，锚定图/shape 不落图（docs/17 §2.2 实测 L0 空白、L1==L0）。
        //    每页恰好一张 media（srcRect 复用的前提）。
        if let path = page.baseImageRelativePath, !path.isEmpty,
           let base = registerBakedBaseImage(
               path: path,
               blocks: blocks,
               media: &media,
               imageRels: &imageRels,
               nextImage: &nextImage
           ) {
            carriesBaseImage = true
            restoredMask = base.mask
            let cx = max(Int64(spaces.emu.width.rounded()), 1)
            let cy = max(Int64(spaces.emu.height.rounded()), 1)
            nextDocPr += 1
            runs += inlinePictureXML(
                relID: base.relID,
                name: "BaseImage \(nextDocPr)",
                cx: cx,
                cy: cy,
                docPrID: nextDocPr
            )

            // 2) 保留区（figure/barcode/artwork）：srcRect 裁剪**同一张净化底图**
            //    （FR-005 单份表示 / FR-010 每页单图），不覆盖、不重排。behindDoc
            //    层内位于文本层之下 —— 与预览同构：净化底图在这些区域保持原像素。
            for block in blocks where isRestoredCrop(block.kind) {
                let clipped = block.bbox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !clipped.isEmpty else { continue }
                let rect = map.rect(clipped)
                let x = Int64(rect.minX.rounded())
                let y = Int64(rect.minY.rounded())
                let cx = max(Int64(rect.width.rounded()), 1)
                let cy = max(Int64(rect.height.rounded()), 1)
                runs += floatingAnchorXML(
                    behindDoc: true,
                    relativeHeight: &relativeHeight,
                    nextDocPr: &nextDocPr,
                    name: "Crop",
                    x: x,
                    y: y,
                    cx: cx,
                    cy: cy,
                    graphicURI: Self.pictureGraphicURI,
                    graphicInner: pictureXML(
                        relID: base.relID,
                        name: "crop",
                        cx: cx,
                        cy: cy,
                        srcRect: srcRect(of: clipped)
                    )
                )
            }
        }

        // 3) 浮动文本框（最前层）：干净重排（真实段落，Word 里可直接编辑，FR-007）。
        //    有行列的表格块不进文本框 —— 走 4) 的表格层。
        for block in blocks where isRestoredText(block.kind) {
            if block.kind == .table && block.table?.rows.isEmpty == false {
                continue
            }
            guard let content = restoredTextBoxContent(
                block,
                pageSizeEMU: spaces.emu,
                mask: restoredMask
            ) else {
                continue
            }
            let rect = map.rect(block.bbox)
            // 最小尺寸兜底（≈ 预览的 12×14pt）：零尺寸文本框会在 Word 里吞字。
            // 高度还要吸收 `w:before` 行距与末行超出 bbox 的部分，否则 WPS 按
            // shape 高度裁切，表头第二行“friends after school?”会整行消失。
            let contentExtra = restoredTextExtraBottom(block) * spaces.emu.height
            let width = max(rect.width, 12 * PageLayoutMapper.emuPerPixel)
            let height = max(
                rect.height + contentExtra + spaces.emu.height * 0.003,
                14 * PageLayoutMapper.emuPerPixel
            )
            // 单行段落行框常带一大截 leading；WPS 的 exact 行距把字形压在行盒
            // 底部，行框又跨出深色栏头时白字会落到纸面上（studying after
            // school?）。按“行盒高 - 1.2×字号”的一半上移，让字形回到行框中部。
            let lineLift = restoredSingleLineLift(
                block,
                pageWidthPT: Double(spaces.emu.width) / 12_700,
                pageHeightPT: Double(spaces.emu.height) / 12_700
            ) * spaces.emu.height
            let calibrationX = spaces.emu.width * CGFloat(LayoutTypography.restoredTextHorizontalOffsetRatio)
            let calibrationY = spaces.emu.height * CGFloat(LayoutTypography.restoredTextVerticalLiftRatio)
            let x = Int64((rect.minX + calibrationX).rounded())
            let y = Int64((rect.minY - lineLift - calibrationY).rounded())
            let cx = max(Int64(width.rounded()), 1)
            let cy = max(Int64(height.rounded()), 1)
            runs += floatingAnchorXML(
                behindDoc: false,
                relativeHeight: &relativeHeight,
                nextDocPr: &nextDocPr,
                name: "TextBox",
                x: x,
                y: y,
                cx: cx,
                cy: cy,
                graphicURI: Self.shapeGraphicURI,
                graphicInner: textBoxXML(cx: cx, cy: cy, content: content)
            )
        }

        // 4) 表格层：正文页上的表格与底图共用「内联底图 + 精确行高」承载段落时，
        //    body 级 `w:tbl` 会被 WPS 推到下一页（承载段落已占满整页高度）。因此
        //    **有正文的页面**把表格放进浮动文本框：表格仍带完整行列/列宽/行高，
        //    但定位交给文本框锚点，WPS/QuickLook 都保持单页。**纯表格页**继续用
        //    原生 body 级 `w:tblpPr` 浮动（不套文本框，US5/FR-008 的结构契约）。
        let hasRestoredTextBlocks = blocks.contains { block in
            block.kind != .table && isRestoredText(block.kind)
                && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for block in blocks where block.kind == .table {
            if hasRestoredTextBlocks {
                let table = restoredFloatingTableXML(
                    block,
                    map: map,
                    pageHeightEMU: spaces.emu.height,
                    positioned: false
                )
                guard !table.isEmpty else { continue }
                let rect = map.rect(block.bbox)
                let x = Int64(rect.minX.rounded())
                let y = Int64(rect.minY.rounded())
                let cx = max(Int64(rect.width.rounded()), 1)
                let cy = max(Int64(rect.height.rounded()), 1)
                runs += floatingAnchorXML(
                    behindDoc: false,
                    relativeHeight: &relativeHeight,
                    nextDocPr: &nextDocPr,
                    name: "TableBox",
                    x: x,
                    y: y,
                    cx: cx,
                    cy: cy,
                    graphicURI: Self.shapeGraphicURI,
                    graphicInner: textBoxXML(cx: cx, cy: cy, content: table)
                )
            } else {
                tables += restoredFloatingTableXML(
                    block,
                    map: map,
                    pageHeightEMU: spaces.emu.height
                )
            }
        }

        // 有内联底图 → 行高钉成图高（`lineRule="exact"`，与图片版同一口径：行盒
        // 不被段落标记字号压扁而把内联图裁成一条线）。无底图时保持最小行高。
        let lineTwips = carriesBaseImage
            ? max(1, Int((spaces.emu.height / 635).rounded()))
            : 10
        let paragraphRPr = carriesBaseImage
            ? ""
            : "<w:rPr><w:sz w:val=\"2\"/><w:szCs w:val=\"2\"/></w:rPr>"
        // WPS 对内联图所在段落的基线处理默认按 0.8×页高下移，导致整页下坠/第二页；
        // `w:textAlignment=center` 把基线对到页面中心（实测 posOffset 从 1267.2pt
        // 变为 1584pt = 整页高度），WPS 才按整页铺图。QuickLook 不受影响。
        let textAlignment = carriesBaseImage
            ? "<w:textAlignment w:val=\"center\"/>"
            : ""
        return "<w:p><w:pPr>"
            + "<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(lineTwips)\" w:lineRule=\"exact\"/>"
            + textAlignment
            + paragraphRPr
            + "</w:pPr>"
            + runs
            + "</w:p>"
            + tables
    }

    /// 原生浮动表格定位/尺寸（plan D7/D8）：bbox 经 `PageLayoutMapper` 映射后换算
    /// twips（EMU ÷ 635）；表宽/行高贴合 bbox（行高 exact 封顶 = 区域高 ÷ 行数）；
    /// 单元格基础字号 = 实测字号 × 0.8（页 pt），列宽/字号/升级策略在
    /// `floatingTableXML` 内按 D8 落地。无行列的退化表返回空串（退回文本框
    /// displayText 路径）。
    private func restoredFloatingTableXML(
        _ block: ReconstructBlock,
        map: PageLayoutMap,
        pageHeightEMU: CGFloat,
        positioned: Bool = true
    ) -> String {
        let clipped = block.bbox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isEmpty else { return "" }
        let rect = map.rect(clipped)
        let x = Int((rect.minX / 635).rounded())
        let y = Int((rect.minY / 635).rounded())
        let width = max(Int((rect.width / 635).rounded()), 200)
        let height = max(Int((rect.height / 635).rounded()), 60)
        let baseCellFontPT = Double(restoredFontSize(block, pageHeightEMU: pageHeightEMU)) / 2 * 0.8
        return tableXML(
            block.table,
            totalWidth: width,
            totalHeight: height,
            baseCellFontPT: baseCellFontPT,
            position: (x: x, y: y),
            blockID: block.id,
            positioned: positioned
        ) ?? ""
    }

    /// 动态 sectPr：页面宽高随原图（EMU ÷ 635 = twips），零边距 —— 版面还原档的
    /// 版面全靠浮动对象，页边距只会让底图缩水。
    private func sectionPropertiesXML(emuSize: CGSize) -> String {
        let width = Int((emuSize.width / 635).rounded())
        let height = Int((emuSize.height / 635).rounded())
        return "<w:sectPr><w:pgSz w:w=\"\(width)\" w:h=\"\(height)\"/>"
            + "<w:pgMar w:top=\"0\" w:right=\"0\" w:bottom=\"0\" w:left=\"0\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/>"
            + "</w:sectPr>"
    }

    /// 分节段落（非末页）：该页 sectPr 藏进 pPr，body 级 sectPr 只属于最后一页。
    private func sectionBreakXML(_ sectPr: String) -> String {
        "<w:p><w:pPr>"
            + "<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"10\" w:lineRule=\"exact\"/>"
            + "<w:rPr><w:sz w:val=\"2\"/><w:szCs w:val=\"2\"/></w:rPr>"
            + sectPr
            + "</w:pPr></w:p>"
    }

    /// 文本框内容：真实段落（可编辑）。有行列的表格块已被 `restoredPageXML` 引去
    /// 原生浮动表格（US5/T031），进到这里的 `.table` 只剩无行列退化块 —— 按
    /// `displayText` 兜底成段落。有 `lines` 的文本/标题块**每行一个 `<w:p>`**
    /// （plan D7 / FR-005：保实测行距与行首位置）；无 `lines` 块回退单段 `w:br`
    /// 路径，字号先经渲染期兜底预缩（T027，`preScaledFontSizeHalfPoints`）。
    private func restoredTextBoxContent(
        _ block: ReconstructBlock,
        pageSizeEMU: CGSize,
        mask: LayoutMask
    ) -> String? {
        let baseSize = restoredFontSize(block, pageHeightEMU: pageSizeEMU.height)
        switch block.kind {
        case .table:
            guard !block.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let size = preScaledFontSizeHalfPoints(
                block,
                text: block.displayText,
                pageSizeEMU: pageSizeEMU,
                baseSizeHalfPoints: baseSize
            )
            return paragraphXML(block.displayText, style: "Normal", bold: false, size: size)
        default:
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let isHeading = block.kind == .heading
            let style = isHeading ? "Heading1" : "Normal"
            let bold = isHeading || block.style.isBold
            if let lines = block.lines, !lines.isEmpty {
                // 行段不走渲染期预缩：有 lines 的块在解析期已过引擎溢出阶梯（T026
                // 挂载无条件；恒等页 restoredBlocks = nil 也意味着"装得下"），再缩
                // 会破坏 w:line exact 行距与字号的比例，与预览逐行渲染不再同构。
                // T007（spec/scan-fidelity US1）：w:sz 逐行经 `lineFontPT`（行实测高
                // × 1.05 钳制，每行一档；退化回退块级 baseSize 同式）——异构行高块
                // 不再整块一个字号（叠字根因）。w:line exact 维持实测行高不变。
                // T012（spec/scan-fidelity US2）：行段带 segments 时按分段多 run
                // 渲染，段间宽空隙下划线空格占位（FR-005）。
                let pageHeightPT = Double(pageSizeEMU.height) / 12_700
                let pageWidthPT = Double(pageSizeEMU.width) / 12_700
                let pageWidthTwips = Double(pageSizeEMU.width) / 635
                let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block.bbox)
                return lines.enumerated().map { index, line in
                    let frame = frames.indices.contains(index) ? frames[index] : block.bbox
                    // `gapToPrevious` 在预览里是行框顶到顶的真实节拍；Word/WPS
                    // 的段落只会首尾相接，必须用 `w:before` 把正间隙补回来，
                    // 否则表头第一行会高出深色栏头（WPS 实测 2026-10-24）。
                    let beforeTwips = index > 0
                        ? max(0, Int((line.gapToPrevious * pageHeightPT * 20).rounded()))
                        : 0
                    let tabsXML = (line.segments ?? []).dropFirst().map { segment in
                        "<w:tab w:val=\"left\" w:pos=\"\(max(0, Int((segment.offset * pageWidthTwips).rounded())))\"/>"
                    }.joined()
                    // 负 gapToPrevious 表示两行框重叠：Word 不支持负 before，
                    // 把重叠量从前一行的 exact 行高里扣掉，后续行才会向上收。
                    // 表头左栏两行原来因忽略 -13pt、正 before 16.7pt 而总高溢出
                    // 13pt，第二行压到深色栏头下缘。
                    let nextOverlap = index + 1 < lines.count
                        ? min(0, lines[index + 1].gapToPrevious)
                        : 0
                    let lineTwips = max(
                        1,
                        Int(((line.height + nextOverlap) * pageHeightPT * 20).rounded())
                    )
                    return lineParagraphXML(
                        line,
                        block: block,
                        lineFrame: frame,
                        mask: mask,
                        style: style,
                        bold: bold,
                        pageHeightPT: pageHeightPT,
                        pageWidthPT: pageWidthPT,
                        lineTwips: lineTwips,
                        indLeftTwips: max(0, Int((line.leadingOffset * pageWidthTwips).rounded())),
                        beforeTwips: beforeTwips,
                        tabsXML: tabsXML
                    )
                }.joined()
            }
            let size = preScaledFontSizeHalfPoints(
                block,
                text: block.text,
                pageSizeEMU: pageSizeEMU,
                baseSizeHalfPoints: baseSize
            )
            return paragraphXML(block.text, style: style, bold: bold, size: size)
        }
    }

    /// 文本块内容在竖直方向超出 bbox 的归一化高度：正 `gapToPrevious` 会被写成
    /// `w:before`，末行也可能因 OCR 行框重叠而落到 bbox 下方。两者都要计入
    /// 文本框高度，WPS 才不会按 shape 裁掉末行（真实 UI 底图表头复测）。
    private func restoredTextExtraBottom(_ block: ReconstructBlock) -> Double {
        guard let lines = block.lines, !lines.isEmpty else { return 0 }
        var top = block.bbox.maxY
        var bottom = block.bbox.minY
        var insertedGaps = 0.0
        for (index, line) in lines.enumerated() {
            if index > 0 {
                top -= line.gapToPrevious
                insertedGaps += max(0, line.gapToPrevious)
            }
            top -= max(0, line.height)
            bottom = min(bottom, top)
        }
        return max(0, block.bbox.minY - bottom) + insertedGaps
    }

    /// 单行段落竖直校正（归一化页高）：行盒明显高于 1.2×字号时，WPS 的 exact
    /// 行距会把字形贴到盒底。返回正数 = 需要上移的页高比例；多行/标题不动。
    private func restoredSingleLineLift(
        _ block: ReconstructBlock,
        pageWidthPT: Double,
        pageHeightPT: Double
    ) -> Double {
        guard block.kind == .paragraph,
              let lines = block.lines,
              lines.count == 1,
              let line = lines.first,
              pageHeightPT > 0, pageWidthPT > 0 else { return 0 }
        let fontPT = LayoutTypography.renderedLineFontPT(
            line: line,
            block: block,
            pageWidthPT: pageWidthPT,
            pageHeightPT: pageHeightPT
        )
        let lineHeightPT = line.height * pageHeightPT
        // exact 行距把基线压到盒底；除了半 leading，再补 1.5pt 让下缘
        // 不压到深色栏头的纸面边界（studying after school? 实测）。
        let liftPT = max(0, (lineHeightPT - fontPT) / 2 + 7)
        guard liftPT > 2 else { return 0 }
        return liftPT / pageHeightPT
    }

    /// 渲染期兜底预缩（T027 / plan D6 风险注记「二选一」之 B：**布局期预估缩放
    /// 直接写入 w:sz**，不采用 bodyPr `<a:normAutofit>`）。不选 normAutofit 的理由：
    /// 1. normAutofit 的缩放由消费端运行时决定——桌面 Word 会重算，但 iOS
    ///    QuickLook / Pages / WPS 等查看器普遍忽略 bodyPr 自动缩放，「只在桌面
    ///    Word 成立」的同构不满足 FR-004 双端恒等；
    /// 2. 行段用 `w:line` exact 钉死行距——normAutofit 只缩字号不缩 exact 行距，
    ///    缩放后行距/字号比例与预览（同步缩放）不再一致；
    /// 3. 预缩是纯函数可单测（normAutofit 行为只能真机实测，超出本任务环境，
    ///    真机清单见 spec/layout-engine/device-acceptance.md）。
    /// plan D6 风险注记已预授权该回退：「若 Word 不主动缩放，则回退为布局期把预估
    /// 缩放直接写入 w:sz（布局期估算已尽力精确，此为等价兜底），双端仍同构」。
    ///
    /// 作用域 = 无 `lines` 的回退段落（引擎溢出阶梯只处理有实测行的文字块，T026）：
    /// 按共享估算器 `estimatedRenderHeight` 估算换行高度（合成行 height=0 → 行距
    /// 走字号标称行高 × 1.2，与单段 `w:br` 段落的默认行距模型一致），超出区域则
    /// 比例缩字号（≤ 8 次逼近，换行分段数随缩放单调不增），下限 7pt 与共享钳制
    /// 一致。装得下 → 原字号原样（零扰动）。区域含文本框 12×14pt 最小尺寸下限
    /// （与调用点 `max(rect, 12×14)` 同参，防退化区域过度缩字）。
    private func preScaledFontSizeHalfPoints(
        _ block: ReconstructBlock,
        text: String,
        pageSizeEMU: CGSize,
        baseSizeHalfPoints: Int
    ) -> Int {
        let pageHeightPT = Double(pageSizeEMU.height) / 12_700
        let pageWidthPT = Double(pageSizeEMU.width) / 12_700
        guard pageHeightPT > 0, pageWidthPT > 0, block.bbox.width > 0 else {
            return baseSizeHalfPoints
        }
        // 有效区域 = bbox 与文本框最小尺寸（12×14pt）取大；blockWidth 归一化传入
        let regionPT = max(block.bbox.height * pageHeightPT, 14)
        let blockWidthNormalized = max(block.bbox.width, 12 / pageWidthPT)
        let baseFontPT = Double(baseSizeHalfPoints) / 2
        // 合成行：每个 \n 段一行，height=0 → 估算器行距回退「字号标称行高」
        let syntheticLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { segment in
            BlockLine(text: String(segment), height: 0, gapToPrevious: 0, leadingOffset: 0, width: 0)
        }
        func estimate(at fontPT: Double) -> Double {
            LayoutTypography.estimatedRenderHeight(
                lines: syntheticLines,
                blockWidth: blockWidthNormalized,
                pageWidthPT: pageWidthPT,
                pageHeightPT: pageHeightPT,
                baseFontPT: fontPT,
                fitFontToWidth: false
            )
        }
        let epsilon = 1e-6
        var estimated = estimate(at: baseFontPT)
        guard estimated > regionPT + epsilon else { return baseSizeHalfPoints }
        let floorScale = baseFontPT > LayoutTypography.minFontPT
            ? LayoutTypography.minFontPT / baseFontPT
            : 1
        var scale = 1.0
        for _ in 0..<8 where estimated > regionPT + epsilon {
            let next = max(floorScale, scale * regionPT / estimated)
            guard next < scale else { break } // 触 7pt 下限或已收敛——无进展即止
            scale = next
            estimated = estimate(at: baseFontPT * scale)
        }
        return Int((baseFontPT * scale * 2).rounded())
    }

    /// 深底白字/浅底黑字的 run 颜色。黑字走 Word 默认（不写 color），避免把
    /// 继承自样式的墨色硬编码成纯黑；白字必须显式写入，否则深色栏头上的
    /// 可编辑文字在 WPS/Word 里仍是黑字（视觉消失）。
    private func colorXML(_ color: (red: UInt8, green: UInt8, blue: UInt8)) -> String {
        guard color.red == 255, color.green == 255, color.blue == 255 else { return "" }
        return "<w:color w:val=\"FFFFFF\"/>"
    }

    /// 行段（plan D7 / US3）：`w:line` = 实测行高 × 20 twips（lineRule=exact）、
    /// `w:ind w:left` = 行首偏移换算 dxa，段前段后 0 —— 行距与行首位置保真，
    /// 且是可编辑普通段落（FR-005）；heading 样式（pStyle/bold）保留。
    /// T012（spec/scan-fidelity US2 / FR-005）：带 `segments` 的行按分段多 run
    /// 渲染——段间空隙 ≥ 0.6 字符宽时插入**下划线空格 run**（`w:u w:val="single"`
    /// + `gapPlaceholderSpaces` 个空格，`xml:space="preserve"`），填空空档在
    /// Word 里可见、可编辑、可打印；窄空隙用普通空格 run 连接（与既有 join 的
    /// 单空格语义一致）。单段行的多 run 产物与整行单 run 恒等；无 segments 的
    /// 旧行保持单 text run（行为字节不变）。
    private func lineParagraphXML(
        _ line: BlockLine,
        block: ReconstructBlock,
        lineFrame: CGRect,
        mask: LayoutMask,
        style: String,
        bold: Bool,
        pageHeightPT: Double,
        pageWidthPT: Double,
        lineTwips: Int,
        indLeftTwips: Int,
        beforeTwips: Int,
        tabsXML: String
    ) -> String {
        let boldXML = bold ? "<w:b/>" : ""
        // 实测行宽反推字号（2026-10-23 真实 UI 底图 WPS 复测）：OCR 的
        // `line.width` 是原稿上这一行真实的墨迹宽度；用它反推 w:sz，WPS/Word
        // 的换行位置才与原图一致。`fittedFontPT` 的 0.6 em 是换行估算的保守
        // 上界，直接拿来反推会把正文缩小约 20%（输出 15pt vs 原稿约 19pt）。
        let fontPT = LayoutTypography.renderedLineFontPT(
            line: line,
            block: block,
            pageWidthPT: pageWidthPT,
            pageHeightPT: pageHeightPT
        )
        let size = Int((fontPT * 2).rounded())
        let runs: String
        if let segments = line.segments, !segments.isEmpty {
            runs = segmentRunsXML(
                segments,
                block: block,
                lineFrame: lineFrame,
                mask: mask,
                boldXML: boldXML,
                size: size,
                fontPT: fontPT,
                pageWidthPT: pageWidthPT
            )
        } else {
            let color = mask.contrastingTextColor(at: lineFrame)
            runs = """
                <w:r>
                  <w:rPr>\(boldXML)\(colorXML(color))<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                  <w:t xml:space="preserve">\(escape(line.text))</w:t>
                </w:r>
            """
        }
        let tabs = tabsXML.isEmpty ? "" : "<w:tabs>\(tabsXML)</w:tabs>"
        return """
            <w:p>
              <w:pPr><w:pStyle w:val="\(style)"/>\(tabs)<w:spacing w:before="\(beforeTwips)" w:after="0" w:line="\(lineTwips)" w:lineRule="exact"/><w:ind w:left="\(indLeftTwips)"/></w:pPr>
              \(runs)
            </w:p>

        """
    }

    /// T012（spec/scan-fidelity US2 / FR-005）：分段文本 run 序列。段 run 之间：
    /// - 空隙 ≥ 0.6 字符宽（`gapPlaceholderSpaces` 非 nil）→ 下划线空格 run——
    ///   `w:u w:val="single"` 让 Word 在空格下画线（填空空档的视觉还原），
    ///   `xml:space="preserve"` 防止 Word 折叠前导空格；
    /// - 窄空隙 / 负空隙（分段重叠的 OCR 噪声）→ 普通单空格 run 连接。
    /// 空格 run 与文本 run 同字号同加粗——一行一档（T007）不被连接符稀释。
    private func segmentRunsXML(
        _ segments: [LineSegment],
        block: ReconstructBlock,
        lineFrame: CGRect,
        mask: LayoutMask,
        boldXML: String,
        size: Int,
        fontPT: Double,
        pageWidthPT: Double
    ) -> String {
        segments.indices.map { index in
            let segment = segments[index]
            let segmentRect = CGRect(
                x: block.bbox.minX + segment.offset,
                y: lineFrame.minY,
                width: segment.width,
                height: lineFrame.height
            )
            // 每个段按自己的局部底色决定黑白：深色栏头左格/右格可独立。
            let color = colorXML(mask.contrastingTextColor(at: segmentRect))
            let textRun = """
                  <w:r>
                    <w:rPr>\(boldXML)\(color)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                    <w:t xml:space="preserve">\(escape(segment.text))</w:t>
                  </w:r>
            """
            guard index < segments.count - 1 else { return textRun }
            let next = segments[index + 1]
            let gap = next.offset - (segment.offset + segment.width)
            let connector: String
            if gap >= 0.02 {
                // 大空隙是栏间/格间 gutter，不是填空横线：用绝对 tab 定位到下一段
                // 的实测 x。下划线空格在 WPS 里会因累计宽度超框而整行回绕，
                // 双栏表头因此只剩“do”一行可见。
                connector = """
                      <w:r>
                        <w:rPr>\(boldXML)\(color)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                        <w:tab/>
                      </w:r>
                """
            } else if let spaces = LayoutTypography.gapPlaceholderSpaces(
                gapWidthNormalized: gap,
                fontPT: fontPT,
                pageWidthPT: pageWidthPT
            ) {
                let blanks = String(repeating: " ", count: spaces)
                // rPr 子元素次序遵循 CT_RPr 模式序列：b → sz → szCs → u
                connector = """
                      <w:r>
                        <w:rPr>\(boldXML)\(color)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/><w:u w:val="single"/></w:rPr>
                        <w:t xml:space="preserve">\(blanks)</w:t>
                      </w:r>
                """
            } else {
                connector = """
                      <w:r>
                        <w:rPr>\(boldXML)\(color)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                        <w:t xml:space="preserve"> </w:t>
                      </w:r>
                """
            }
            return textRun + connector
        }.joined()
    }

    /// 字号走 LayoutTypography 共享推导（plan D4）：实测行高 → 文档页 pt 字号
    /// （钳制 [7, 28] 只在页 pt 空间发生一次），无实测数据走兜底公式（页高 1.8% ×
    /// relativeFontSize）。与 LayoutCanvas 预览同一入口——双端「字号 / 页高」比例
    /// 恒等（FR-004）；`w:sz` 单位 = 半磅。
    private func restoredFontSize(_ block: ReconstructBlock, pageHeightEMU: CGFloat) -> Int {
        let pageHeightPt = Double(pageHeightEMU) / 12_700
        let fontPt = LayoutTypography.fontPT(for: block, pageHeightPT: pageHeightPt)
        return Int((fontPt * 2).rounded())
    }

    /// srcRect（单位 1/1000 %，自整图四边裁）—— Vision 归一化（左下原点）→
    /// 图片空间（左上原点）：顶部裁掉 (1 − maxY)，底部裁掉 minY。
    private func srcRect(of clipped: CGRect) -> (l: Int, t: Int, r: Int, b: Int) {
        (
            l: Int((clipped.minX * 100_000).rounded()),
            t: Int(((1 - clipped.maxY) * 100_000).rounded()),
            r: Int(((1 - clipped.maxX) * 100_000).rounded()),
            b: Int((clipped.minY * 100_000).rounded())
        )
    }

    /// 版面还原档的「保留区」块：底座原像素 srcRect 透出（不覆盖、不重排）。
    private func isRestoredCrop(_ kind: ReconstructBlockKind) -> Bool {
        switch kind {
        case .figure, .barcode, .artwork:
            return true
        case .heading, .paragraph, .list, .table, .checkbox, .handwrittenBlank:
            return false
        }
    }

    /// 版面还原档的「重排」块：进净化底图 + 浮动文本框（保留区之外全部）。
    private func isRestoredText(_ kind: ReconstructBlockKind) -> Bool {
        !isRestoredCrop(kind)
    }

    /// 版面还原档的底图 = **净化底图**（spec/word-fidelity T021 / G3'）：把
    /// `LayoutMaskBuilder` 的净化矩形按环带 median 底色直接刷到像素上，再编码成
    /// JPEG 作为该页唯一 media。擦除因此**烘进像素**，不再依赖渲染器画
    /// `wps:wsp` 形状（QuickLook 等宿主渲染器不画形状 → 旧产物底图原字与浮动
    /// 文本框叠字）。环带采样与预览共用 `LayoutMaskBuilder`（同源底色）。
    ///
    /// 退化输入（读不出像素 / 编码失败）退回原文件字节：导出仍可用，只是擦除
    /// 由渲染器决定——不为了净化把整页弄丢。
    private func registerBakedBaseImage(
        path: String,
        blocks: [ReconstructBlock],
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int
    ) -> (relID: String, fileName: String, data: Data, mask: LayoutMask)? {
        guard let sourceData = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !sourceData.isEmpty,
              let baseImage = Self.downsampledCGImage(from: sourceData)
        else {
            return registerImageMedia(
                path: path,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage
            ).map { ($0.relID, $0.fileName, $0.data, LayoutMask()) }
        }
        let mask = LayoutMaskBuilder.build(
            blocks: blocks,
            baseImage: baseImage,
            granularity: .line
        )
        guard let baked = Self.bakedJPEGData(baseImage, mask: mask) else {
            return registerImageMedia(
                path: path,
                media: &media,
                imageRels: &imageRels,
                nextImage: &nextImage
            ).map { ($0.relID, $0.fileName, $0.data, LayoutMask()) }
        }
        let registered = registerImageMedia(
            data: baked,
            fileExtension: "jpg",
            media: &media,
            imageRels: &imageRels,
            nextImage: &nextImage
        )
        return registered.map { ($0.relID, $0.fileName, $0.data, mask) }
    }

    /// 图片落 media + rel（结构化档裁图 / 版面还原档底图共用）。
    /// 扩展名保持原样 —— jpg 底图不得强转 png，`[Content_Types].xml` 按实际扩展名声明。
    private func registerImageMedia(
        path: String,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int
    ) -> (relID: String, fileName: String, data: Data)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return nil
        }
        var ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
        return registerImageMedia(
            data: data,
            fileExtension: ext,
            media: &media,
            imageRels: &imageRels,
            nextImage: &nextImage
        )
    }

    /// 字节版 media 注册：净化底图用编码后的 JPEG 字节（不注册未使用的原图）。
    private func registerImageMedia(
        data: Data,
        fileExtension: String,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int
    ) -> (relID: String, fileName: String, data: Data)? {
        guard !data.isEmpty else { return nil }
        let index = nextImage
        nextImage += 1
        let ext = fileExtension.isEmpty ? "png" : fileExtension.lowercased()
        let fileName = "image\(index).\(ext)"
        media.append((name: "word/media/\(fileName)", data: data))
        let relID = "rId\(index + 1)"
        imageRels.append((id: relID, target: "media/\(fileName)"))
        return (relID, fileName, data)
    }

    /// 浮动对象锚点。posOffset / extent 全 **EMU**（误用 twips 会缩到 1/635 ——
    /// 旧 B 档事故，见 ExportSafetyTests 迁移注记）；`relativeHeight` 决定同页 z 序
    /// （发射顺序即层序，底图 behindDoc 拿最低值）。
    private func floatingAnchorXML(
        behindDoc: Bool,
        relativeHeight: inout Int,
        nextDocPr: inout Int,
        name: String,
        x: Int64,
        y: Int64,
        cx: Int64,
        cy: Int64,
        graphicURI: String,
        graphicInner: String
    ) -> String {
        let z = relativeHeight
        relativeHeight += 1
        let docPr = nextDocPr
        nextDocPr += 1
        return "<w:r><w:drawing>"
            + "<wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"\(z)\" behindDoc=\"\(behindDoc ? 1 : 0)\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\">"
            + "<wp:simplePos x=\"0\" y=\"0\"/>"
            + "<wp:positionH relativeFrom=\"page\"><wp:posOffset>\(x)</wp:posOffset></wp:positionH>"
            + "<wp:positionV relativeFrom=\"page\"><wp:posOffset>\(y)</wp:posOffset></wp:positionV>"
            + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:wrapNone/>"
            + "<wp:docPr id=\"\(docPr)\" name=\"\(name) \(docPr)\"/>"
            + "<wp:cNvGraphicFramePr/>"
            + "<a:graphic><a:graphicData uri=\"\(graphicURI)\">\(graphicInner)</a:graphicData></a:graphic>"
            + "</wp:anchor></w:drawing></w:r>"
    }

    /// 浮动图片（底图 / srcRect 保留区共用同一张图，FR-010）。
    private func pictureXML(
        relID: String,
        name: String,
        cx: Int64,
        cy: Int64,
        srcRect: (l: Int, t: Int, r: Int, b: Int)?
    ) -> String {
        let crop = srcRect.map { value in
            "<a:srcRect l=\"\(value.l)\" t=\"\(value.t)\" r=\"\(value.r)\" b=\"\(value.b)\"/>"
        } ?? ""
        return "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(relID)\"/>\(crop)<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
    }

    /// 浮动文本框：`wps:txbx` 内是**真实段落**（Word 里可直接编辑，FR-007）；
    /// 自身 noFill —— 它叠在净化底图之上，不得再糊一层底色。
    /// bodyPr **不加 `<a:normAutofit>`**（T027「二选一」之 B：布局期预估缩放直接
    /// 写入 w:sz，见 `preScaledFontSizeHalfPoints` 旁注——normAutofit 依赖消费端
    /// 运行时缩放，QuickLook/Pages 等查看器普遍忽略，FR-004 双端同构不成立）。
    private func textBoxXML(cx: Int64, cy: Int64, content: String) -> String {
        "<wps:wsp><wps:cNvSpPr txBox=\"1\"/><wps:spPr>"
            + "<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            + "<a:noFill/><a:ln><a:noFill/></a:ln>"
            + "</wps:spPr>"
            + "<wps:txbx><w:txbxContent>\(content)</w:txbxContent></wps:txbx>"
            + "<wps:bodyPr rot=\"0\" spcFirstLastPara=\"0\" vertOverflow=\"overflow\" horzOverflow=\"overflow\" vert=\"horz\" wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" numCol=\"1\" spcCol=\"0\" rtlCol=\"0\" fromWordArt=\"0\" anchor=\"t\" anchorCtr=\"0\" forceAA=\"0\" compatLnSpc=\"1\"/>"
            + "</wps:wsp>"
    }

    /// 底座下采样（ImageIO 缩略图，与 `LayoutCanvas.loadDownsampled` 同源同参）——
    /// 擦除烘焙与预览同源同坐标，也不把整页原图拉进内存。
    private static func downsampledCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: restoredBaseMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 把净化矩形直接刷进底图像素，编码为 JPEG（净化底图）。
    ///
    /// 坐标系：`LayoutMask.Fill.rect` 是 Vision 归一化坐标（**左下原点**）；
    /// `CGContext` 位图用户空间同为左下原点 → 直接 `minY × height`，不可再翻一次
    /// （翻两次会把擦除区镜像到页面上半部，原文字反而留着）。
    private static func bakedJPEGData(_ image: CGImage, mask: LayoutMask) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pageSize = CGSize(width: width, height: height)
        guard let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        for fill in mask.fills {
            let rect = CGRect(
                x: fill.rect.minX * pageSize.width,
                y: fill.rect.minY * pageSize.height,
                width: fill.rect.width * pageSize.width,
                height: fill.rect.height * pageSize.height
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            switch fill.mode {
            case .solid:
                context.setFillColor(
                    red: CGFloat(fill.red) / 255,
                    green: CGFloat(fill.green) / 255,
                    blue: CGFloat(fill.blue) / 255,
                    alpha: 1
                )
                context.fill(rect)
            case .textPixels:
                Self.eraseTextPixels(
                    in: rect,
                    red: fill.red,
                    green: fill.green,
                    blue: fill.blue,
                    width: width,
                    height: height,
                    bytesPerRow: context.bytesPerRow,
                    buffer: buffer
                )
            }
        }
        guard let baked = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: restoredBaseJPEGQuality
        ]
        CGImageDestinationAddImage(destination, baked, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 行级擦字（混合模式 H2）：只把矩形内**与底色差异足够大的连通笔画**刷成
    /// 底色，保留矩形内的深色栏头、边框、照片像素。
    ///
    /// 为什么不是整块填色：OCR 行框往往比字形高（含行距），标题/栏头行框会
    /// 跨到相邻深色装饰上；整块填色会在纸面上留下可见色带，或把深色栏头刷白。
    /// 连通域面积上限用于区分「文字笔画」和「大面积装饰/底色」：笔画面积小，
    /// 深色栏头/照片面积大，后者不擦。
    ///
    /// 像素坐标：`CGContext` 位图内存 row 0 = 图像顶行（已用 2×2 合成图验证），
    /// Vision 归一化 y-up → row = (1 − y) × height；不可再翻一次。
    private static func eraseTextPixels(
        in rect: CGRect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        buffer: UnsafeMutablePointer<UInt8>
    ) {
        let x0 = max(0, min(width, Int(rect.minX.rounded(.down))))
        let x1 = max(0, min(width, Int(rect.maxX.rounded(.up))))
        // `rect` 已是**像素坐标**（x/y 按页宽高缩放），不是归一化坐标；
        // 位图内存 row 0 = 顶部，y-up 的用户空间 → row = height − y。
        let top = max(0, min(height, Int((CGFloat(height) - rect.maxY).rounded(.down))))
        let bottom = max(0, min(height, Int((CGFloat(height) - rect.minY).rounded(.up))))
        let columns = x1 - x0
        let rows = bottom - top
        guard columns > 0, rows > 0 else { return }

        let total = columns * rows
        guard total > 0, total <= 4_000_000 else { return }
        let background = (Int(red), Int(green), Int(blue))
        // JPEG 噪声 < 20；抗锯齿边 > 60；45 只放过真正的笔画/彩色文字。
        // 不能降到 24：抗锯齿边会把相邻字母桥接成整词大连通域，超过面积上限
        // 后整块跳过擦除，原字+可编辑层双写（2026-10-24 WPS 复测）。边缘
        // 用连通域擦除后的 1px 邻域补边处理。
        let inkThreshold = 45
        var isInk = [Bool](repeating: false, count: total)
        for row in 0..<rows {
            let pixelRow = top + row
            for column in 0..<columns {
                let pixelColumn = x0 + column
                let index = pixelRow * bytesPerRow + pixelColumn * 4
                let dr = abs(Int(buffer[index]) - background.0)
                let dg = abs(Int(buffer[index + 1]) - background.1)
                let db = abs(Int(buffer[index + 2]) - background.2)
                if dr + dg + db > inkThreshold {
                    isInk[row * columns + column] = true
                }
            }
        }

        // 大面积深色栏头/照片不擦：只擦面积受限的连通域（文字笔画）。
        // 1 500 会漏掉粗体标题整词相连的“Writing”（白字在 JPEG 里被抗锯齿
        // 桥成一个大连通域），底图留白字、可编辑层再叠一遍。行框本身很窄，
        // 放宽到 4 000 / 1/3 仍不会碰到整块深色装饰。
        let maxComponentArea = max(4_000, total / 3)
        var visited = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        stack.reserveCapacity(256)
        for start in 0..<total where isInk[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var component: [Int] = []
            while let current = stack.popLast() {
                component.append(current)
                let row = current / columns
                let column = current % columns
                if row > 0 {
                    let next = current - columns
                    if isInk[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
                if row + 1 < rows {
                    let next = current + columns
                    if isInk[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
                if column > 0 {
                    let next = current - 1
                    if isInk[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
                if column + 1 < columns {
                    let next = current + 1
                    if isInk[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            guard component.count <= maxComponentArea else { continue }
            for localIndex in component {
                let row = localIndex / columns
                let column = localIndex % columns
                let index = (top + row) * bytesPerRow + (x0 + column) * 4
                buffer[index] = red
                buffer[index + 1] = green
                buffer[index + 2] = blue
                buffer[index + 3] = 255
                // 1px 抗锯齿补边：只补与底色有差异、但还没到整块深色装饰的像素，
                // 避免标题白字边缘留一圈亮 halo。深色栏头与底色一致，不会被补。
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nr = row + dy
                        let nc = column + dx
                        guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                        let nIndex = (top + nr) * bytesPerRow + (x0 + nc) * 4
                        let dr = abs(Int(buffer[nIndex]) - background.0)
                        let dg = abs(Int(buffer[nIndex + 1]) - background.1)
                        let db = abs(Int(buffer[nIndex + 2]) - background.2)
                        let distance = dr + dg + db
                        guard distance > 8, distance <= 240 else { continue }
                        buffer[nIndex] = red
                        buffer[nIndex + 1] = green
                        buffer[nIndex + 2] = blue
                        buffer[nIndex + 3] = 255
                    }
                }
            }
        }
    }

    // MARK: - 结构化档部件

    private func paragraphXML(_ text: String, style: String, bold: Bool, size: Int) -> String {
        let runs = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let boldXML = bold ? "<w:b/>" : ""
            return """
                  <w:r>
                    <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                    <w:t xml:space="preserve">\(escape(String(line)))</w:t>
                  </w:r>
            """
        }.joined(separator: "\n                  <w:r><w:br/></w:r>\n")
        return """
            <w:p>
              <w:pPr><w:pStyle w:val="\(style)"/></w:pPr>
        \(runs)
            </w:p>

        """
    }

    /// 表格 XML。`totalWidth/totalHeight/baseCellFontPT/position` 全提供 →
    /// 版面还原档的原生浮动表格（D8 表格几何）；缺省 → 结构化档旧模板
    /// （流式排版，字节不变 —— 结构化档回归网零波动）。
    private func tableXML(
        _ table: ReconstructTable?,
        totalWidth: Int? = nil,
        totalHeight: Int? = nil,
        baseCellFontPT: Double? = nil,
        position: (x: Int, y: Int)? = nil,
        blockID: UUID? = nil,
        positioned: Bool = true
    ) -> String? {
        guard let table, !table.rows.isEmpty else { return nil }
        let columns = max(table.columnCount, 1)
        if let totalWidth, let totalHeight, let baseCellFontPT, let position {
            return floatingTableXML(
                table,
                columns: columns,
                totalWidth: totalWidth,
                totalHeight: totalHeight,
                baseCellFontPT: baseCellFontPT,
                position: position,
                blockID: blockID,
                positioned: positioned
            )
        }
        let width = max(9000 / columns, 1200)
        let rows = table.rows.map { row in
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            let cells = padded.prefix(columns).map { cell in
                """
                      <w:tc>
                        <w:tcPr><w:tcW w:w="\(width)" w:type="dxa"/></w:tcPr>
                        <w:p><w:r><w:t xml:space="preserve">\(escape(cell))</w:t></w:r></w:p>
                      </w:tc>
                """
            }.joined()
            return "                    <w:tr>\n\(cells)\n                    </w:tr>"
        }.joined(separator: "\n")
        return """
            <w:tbl>
              <w:tblPr>
                <w:tblW w:w="0" w:type="auto"/>
                <w:tblBorders>
                  <w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:insideH w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:insideV w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                </w:tblBorders>
              </w:tblPr>
        \(rows)
            </w:tbl>

        """
    }

    /// 原生浮动表格主体（版面还原档，plan D8 表格几何）。tblPr 子元素序 =
    /// tblpPr → tblW → tblBorders → tblLayout（fixed，Word 才尊重 dxa 列宽）。
    /// - 列宽：`tblGrid` 按实测 `columnRatios` 分配总宽（缺失/列数不符 → 均分
    ///   兜底，与回退通路同一策略；尾列吸收取整漂移使总和 = 表宽）；
    /// - 行高：`w:trHeight` exact = 区域高 ÷ 行数（**封顶**，修复 Word 无界
    ///   增长下坠——诊断根因 5），下限 60 twips 防退化；
    /// - 字号：单元格按实测列宽自适应（`LayoutTypography.tableCellFontPT`，
    ///   下限 7pt），基础 = 实测字号 × 0.8；
    /// - 升级链：某行内容到 7pt 仍放不下 → **整表** hRule 转 atLeast（val 变
    ///   保底值，Word 增长到内容高度，文字不截断）+ `layoutTableGrowthUpgrade`
    ///   日志——预览 canvasTable 以同一对共享函数增长行高（FR-008 同构）。
    ///
    /// 定位单位 twips；`horzAnchor/vertAnchor=page` 显式锚定页面（与 posOffset
    /// 的 relativeFrom="page" 同语义，不依赖 pgMar=0 的边距巧合）。
    private func floatingTableXML(
        _ table: ReconstructTable,
        columns: Int,
        totalWidth: Int,
        totalHeight: Int,
        baseCellFontPT: Double,
        position: (x: Int, y: Int),
        blockID: UUID?,
        positioned: Bool = true
    ) -> String {
        let rowCount = max(table.rows.count, 1)
        // 列宽（dxa）：实测比例完整对应列数才生效（flatten 产出归一化和 = 1）
        var columnWidths: [Int]
        if let ratios = table.columnRatios, ratios.count == columns {
            columnWidths = ratios.map { max(Int((Double(totalWidth) * $0).rounded()), 1) }
            let drift = totalWidth - columnWidths.reduce(0, +)
            if drift != 0 {
                columnWidths[columns - 1] = max(columnWidths[columns - 1] + drift, 1)
            }
        } else {
            columnWidths = Array(repeating: max(totalWidth / columns, 120), count: columns)
        }
        // 行高（dxa → 页 pt）：区域高 ÷ 行数，exact 封顶
        let rowHeightTwips = max(totalHeight / rowCount, 60)
        let rowHeightPT = Double(rowHeightTwips) / 20
        // 表格基础字号再按行高封顶：真实 UI 底图表头被 OCR 估成 21pt（行高
        // 75pt），WPS 里左格表头明显大于原稿并挤成三行。0.21×行高 ≈ 15.8pt，
        // 与 14–16pt 的正文表格一致；表头/正文同基准再各自做宽度拟合。
        let effectiveBaseCellFontPT = min(baseCellFontPT, rowHeightPT * 0.21)

        // 单元格字号自适应 + atLeast 升级判定（与预览共享同一对度量函数）
        var sizeHalfPoints: [[Int]] = []
        var growthRow: Int?
        for (rowIndex, row) in table.rows.enumerated() {
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            var rowSizes: [Int] = []
            // 正文行再降一档：75pt 行高下 15.5pt 会把“1 You can go … and do”
            // 的第二行裁掉；0.16×行高 ≈ 12pt 与练习册正文一致，3 行也能装下。
            let rowBaseFontPT = rowIndex == 0
                ? effectiveBaseCellFontPT
                : min(effectiveBaseCellFontPT, rowHeightPT * 0.23)
            for (column, cell) in padded.prefix(columns).enumerated() {
                let columnWidthPT = Double(columnWidths[column]) / 20
                let fontPT = LayoutTypography.tableCellFontPT(
                    text: cell,
                    columnWidthPT: columnWidthPT,
                    rowHeightPT: rowHeightPT,
                    baseFontPT: rowBaseFontPT
                )
                rowSizes.append(max(14, Int((fontPT * 2).rounded())))
                let cellHeightPT = LayoutTypography.tableCellHeightPT(
                    text: cell,
                    columnWidthPT: columnWidthPT,
                    fontPT: fontPT
                )
                if cellHeightPT > rowHeightPT + 1e-6, growthRow == nil {
                    growthRow = rowIndex
                }
            }
            sizeHalfPoints.append(rowSizes)
        }
        if let growthRow, let blockID {
            ZhixiaLog.layoutTableGrowthUpgrade(blockID: blockID, triggeredByRow: growthRow)
        }
        let hRule = growthRow != nil ? "atLeast" : "exact"

        let headerFill = "2F334F"
        let rows = table.rows.enumerated().map { rowIndex, row -> String in
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            let isHeader = rowIndex == 0
            let cells = padded.prefix(columns).enumerated().map { column, cell -> String in
                let size = sizeHalfPoints[rowIndex][column]
                // 单元格内的换行在 Word 的 `w:t` 里不是换行；统一折成空格，避免
                // 单元格显示成一行截断。表头深底白字，正文无网格。
                let normalized = cell
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                let shading = isHeader
                    ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(headerFill)\"/>"
                    : "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"auto\"/>"
                let color = isHeader ? "<w:color w:val=\"FFFFFF\"/>" : ""
                return "<w:tc>"
                    + "<w:tcPr><w:tcW w:w=\"\(columnWidths[column])\" w:type=\"dxa\"/>\(shading)"
                    + "<w:vAlign w:val=\"center\"/></w:tcPr>"
                    + "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
                    + "<w:r><w:rPr>\(color)<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr>"
                    + "<w:t xml:space=\"preserve\">\(escape(normalized))</w:t></w:r></w:p>"
                    + "</w:tc>"
            }.joined()
            return "<w:tr><w:trPr><w:trHeight w:val=\"\(rowHeightTwips)\" w:hRule=\"\(hRule)\"/></w:trPr>"
                + cells
                + "</w:tr>"
        }.joined()
        let grid = columnWidths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        let positioningXML = positioned
            ? "<w:tblpPr w:leftFromText=\"0\" w:rightFromText=\"0\" w:horzAnchor=\"page\" w:vertAnchor=\"page\""
                + " w:tblpX=\"\(position.x)\" w:tblpY=\"\(position.y)\"/>"
            : ""
        return "<w:tbl><w:tblPr>"
            + positioningXML
            + "<w:tblW w:w=\"\(totalWidth)\" w:type=\"dxa\"/>"
            + "<w:tblBorders>"
            + "<w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/>"
            + "<w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/>"
            + "</w:tblBorders>"
            + "<w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"160\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"160\" w:type=\"dxa\"/></w:tblCellMar>"
            + "<w:tblLayout w:type=\"fixed\"/>"
            + "</w:tblPr>"
            + "<w:tblGrid>\(grid)</w:tblGrid>"
            + rows
            + "</w:tbl>"
    }

    private func imageDrawingXML(
        path: String?,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String? {
        guard let path,
              let registered = registerImageMedia(
                  path: path,
                  media: &media,
                  imageRels: &imageRels,
                  nextImage: &nextImage
              )
        else {
            return nil
        }
        let docPr = nextDocPr
        nextDocPr += 1
        let size = pixelSize(of: registered.data) ?? (width: 400, height: 300)
        let (cx, cy) = emus(width: size.width, height: size.height)
        return """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0">
                    <wp:extent cx="\(cx)" cy="\(cy)"/>
                    <wp:effectExtent l="0" t="0" r="0" b="0"/>
                    <wp:docPr id="\(docPr)" name="Picture \(docPr)"/>
                    <wp:cNvGraphicFramePr>
                      <a:graphicFrameLocks noChangeAspect="1"/>
                    </wp:cNvGraphicFramePr>
                    <a:graphic>
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic>
                          <pic:nvPicPr>
                            <pic:cNvPr id="0" name="\(registered.fileName)"/>
                            <pic:cNvPicPr/>
                          </pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="\(registered.relID)"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm>
                              <a:off x="0" y="0"/>
                              <a:ext cx="\(cx)" cy="\(cy)"/>
                            </a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:inline>
                </w:drawing>
              </w:r>
            </w:p>

        """
    }

    private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    /// 图片像素 → EMU（1 px @96dpi = 9525 EMU），并夹在 A4 可放下的范围内。
    /// `wp:extent` / `a:ext` 一律用这个单位；版面还原档的浮动定位统一走
    /// `PageLayoutMapper`（含 22in 动态页上限），不经过这里。
    private func emus(width: Int, height: Int) -> (Int64, Int64) {
        let maxWidth: Double = 5_486_400
        let maxHeight: Double = 7_315_200
        var w = Double(max(width, 1)) * 9525
        var h = Double(max(height, 1)) * 9525
        let scale = min(maxWidth / w, maxHeight / h, 1)
        w *= scale
        h *= scale
        return (Int64(w.rounded()), Int64(h.rounded()))
    }

    /// XML 转义。**先剔除 XML 1.0 非法字符再转义** —— OCR 输出里可能出现
    /// `0x00-0x08 / 0x0B / 0x0C / 0x0E-0x1F` 这类控制字符（Vision 对表格线、噪声的误识别），
    /// 它们没有任何可用实体形式，写进 `document.xml` 会让整个 docx 变成**损坏文件**（Word 拒开）。
    /// 只转义五个实体是不够的。两档（结构化 / 版面还原）共用这一份清洗。
    private func escape(_ text: String) -> String {
        // XML 1.0 §2.2 允许的字符集：Tab / LF / CR / #x20-#xD7FF / #xE000-#xFFFD / #x10000-#x10FFFF
        let sanitized = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { scalar in
                switch scalar.value {
                case 0x09, 0x0A, 0x0D: return true
                case 0x20...0xD7FF: return true
                case 0xE000...0xFFFD: return true
                case 0x10000...0x10FFFF: return true
                default: return false
                }
            }
        ))
        return sanitized
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// [Content_Types].xml 按实际用到的图片扩展名声明 Default —— 版面还原档的
    /// 底图保持原格式（jpg 底图不强转 png），结构化档裁图照旧 png。
    private func contentTypes(extensions: Set<String>) -> String {
        let imageTypes: [String: String] = [
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg"
        ]
        let defaults = extensions
            .filter { !$0.isEmpty }
            .sorted()
            .map { ext in
                let type = imageTypes[ext] ?? "application/octet-stream"
                return "\n      <Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>"
            }
            .joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>\(defaults)
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private func documentRels(_ imageRels: [(id: String, target: String)]) -> String {
        let extras = imageRels.map { rel in
            """
              <Relationship Id="\(rel.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(rel.target)"/>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \(extras)
        </Relationships>
        """
    }

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// 字体：`w:eastAsia` 必须显式声明，否则中文只能靠 Word 的字体回退 ——
    /// 在 Windows 上会落到「等线」、macOS/iOS 上落到别的默认脸，同一份 Word 在不同平台观感不一致，
    /// 也解释不了「中文像宋体又像黑体」的随机性。西文用 Calibri，中文用宋体。
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults>
        <w:rPrDefault>
          <w:rPr>
            <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>
            <w:sz w:val="24"/>
            <w:szCs w:val="24"/>
          </w:rPr>
        </w:rPrDefault>
      </w:docDefaults>
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/>
        <w:qFormat/>
        <w:rPr>
          <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>
          <w:sz w:val="24"/>
          <w:szCs w:val="24"/>
        </w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading1">
        <w:name w:val="heading 1"/>
        <w:basedOn w:val="Normal"/>
        <w:qFormat/>
        <w:pPr><w:outlineLvl w:val="0"/></w:pPr>
        <w:rPr>
          <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>
          <w:b/><w:sz w:val="36"/>
        </w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading2">
        <w:name w:val="heading 2"/>
        <w:basedOn w:val="Normal"/>
        <w:qFormat/>
        <w:pPr><w:outlineLvl w:val="1"/></w:pPr>
        <w:rPr>
          <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>
          <w:b/><w:sz w:val="28"/>
        </w:rPr>
      </w:style>
    </w:styles>
    """
}
