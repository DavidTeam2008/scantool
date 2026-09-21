import CoreGraphics
import Foundation
import ImageIO

/// DOCX 导出（双档，spec/layout-restore plan D7/D9）：
/// - `.structured`：流式段落重排（A4 固定页）；
/// - `.restored`：与 LayoutCanvas 预览同构的版面还原（FR-009）—— 每页独立动态
///   sectPr + 底图 behindDoc 衬底 + LayoutMask 覆盖 shape + 浮动文本框（可编辑，
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

    // MARK: - 结构化档（.structured，流式重排）

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
                    body += paragraphXML(block.text, style: "Normal", bold: block.style.isBold, size: 24)
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
    private static let restoredBaseMaxPixelSize = 2048
    /// 页尺寸退化输入（如老夹具 size == .zero）的 A4 兜底：11906×16838 twips。
    private static let a4PageSizeEMU = CGSize(width: 7_560_310, height: 10_692_130)
    private static let pictureGraphicURI = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    /// wps = Word 2010 wordprocessingShape（浮动 shape / 文本框）。
    private static let shapeGraphicURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"

    /// `.restored` 档正文：每页 = 一个承载段落（挂浮动 shape / 文本框）+ 原生浮动
    /// 表格（body 级 `w:tbl`）+ 非末页分节段落；末页 sectPr 落 body 级。
    /// z 层（Word 渲染序，US5 起）：底图 → srcRect 保留区 → 覆盖 shape（均
    /// behindDoc；mask 外扩可盖保留区边缘 = 预览同构）→ 文本层（承载段落 + 原生
    /// 浮动表格）→ 浮动文本框（最前）。原生浮动表格在文本层渲染，覆盖 shape 若
    /// 留在 behindDoc=0（最前）会整片盖住表格。
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
    private func restoredPageSpaces(for page: ReconstructPage) -> (source: CGSize, emu: CGSize) {
        if page.size.width > 0, page.size.height > 0 {
            return (page.size, PageLayoutMapper.emuPageSize(for: page.size))
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

    /// 单页 XML：承载段落挂浮动 shape / 文本框；原生浮动表格是 body 级块元素
    /// （`w:tbl` 不能作 run 内容），跟在承载段落之后、仍在该页 section 内。
    /// 行高压到最小（浮动对象不占行），多页时承载段落 + 分节段落合计仅 ~20 twips，
    /// 不会把后续页顶出空白页。
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
        // 恒等。保留区/mask/文本框/浮动表格四方同源同一份。
        let blocks = page.restoredBlocks ?? page.blocks
        var runs = ""
        var tables = ""

        // 1) 底图：behindDoc 衬底铺满动态页；每页恰好一张 media（srcRect 复用的前提）。
        if let path = page.baseImageRelativePath, !path.isEmpty,
           let base = registerImageMedia(
               path: path,
               media: &media,
               imageRels: &imageRels,
               nextImage: &nextImage
           ) {
            let cx = max(Int64(spaces.emu.width.rounded()), 1)
            let cy = max(Int64(spaces.emu.height.rounded()), 1)
            runs += floatingAnchorXML(
                behindDoc: true,
                relativeHeight: &relativeHeight,
                nextDocPr: &nextDocPr,
                name: "BaseImage",
                x: 0,
                y: 0,
                cx: cx,
                cy: cy,
                graphicURI: Self.pictureGraphicURI,
                graphicInner: pictureXML(relID: base.relID, name: base.fileName, cx: cx, cy: cy, srcRect: nil)
            )

            // 2) 保留区（figure/barcode/artwork）：srcRect 裁剪**同一张底图**
            //    （FR-005 单份表示 / FR-010 每页单图），不覆盖、不重排。behindDoc
            //    层内位于覆盖 shape 之下 —— 预览同构：预览的 mask 外扩同样会盖住
            //    保留区边缘，Word 不比预览多修一块。
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

            // 3) 覆盖 shape：LayoutMask 环带 median 底色盖掉原字迹 —— 只在有底座时
            //    构建（与 LayoutCanvas 一致：无底座退化白底无需净化）。必须进
            //    behindDoc 层：原生浮动表格（US5）在文本层渲染，shape 留在
            //    behindDoc=0（最前）会整片盖住表格。
            if let cgImage = Self.downsampledCGImage(from: base.data) {
                let mask = LayoutMaskBuilder.build(blocks: blocks, baseImage: cgImage)
                for fill in mask.fills {
                    let rect = map.rect(fill.rect)
                    let x = Int64(rect.minX.rounded())
                    let y = Int64(rect.minY.rounded())
                    let cx = max(Int64(rect.width.rounded()), 1)
                    let cy = max(Int64(rect.height.rounded()), 1)
                    let hex = String(format: "%02X%02X%02X", Int(fill.red), Int(fill.green), Int(fill.blue))
                    runs += floatingAnchorXML(
                        behindDoc: true,
                        relativeHeight: &relativeHeight,
                        nextDocPr: &nextDocPr,
                        name: "Mask",
                        x: x,
                        y: y,
                        cx: cx,
                        cy: cy,
                        graphicURI: Self.shapeGraphicURI,
                        graphicInner: maskShapeXML(cx: cx, cy: cy, fillHex: hex)
                    )
                }
            }
        }

        // 4) 浮动文本框（最前层）：干净重排（真实段落，Word 里可直接编辑，FR-007）。
        //    有行列的表格块不进文本框 —— 走 5) 的原生浮动表格（US5/FR-008）。
        for block in blocks where isRestoredText(block.kind) {
            if block.kind == .table && block.table?.rows.isEmpty == false {
                continue
            }
            guard let content = restoredTextBoxContent(block, pageSizeEMU: spaces.emu) else {
                continue
            }
            let rect = map.rect(block.bbox)
            // 最小尺寸兜底（≈ 预览的 12×14pt）：零尺寸文本框会在 Word 里吞字。
            let width = max(rect.width, 12 * PageLayoutMapper.emuPerPixel)
            let height = max(rect.height, 14 * PageLayoutMapper.emuPerPixel)
            let x = Int64(rect.minX.rounded())
            let y = Int64(rect.minY.rounded())
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

        // 5) 原生浮动表格（US5/FR-008）：w:tblpPr 原位浮动，不套文本框。表格是
        //    body 级块元素，跟在承载段落之后（仍在该页 section 内）。
        for block in blocks where block.kind == .table {
            tables += restoredFloatingTableXML(block, map: map, pageHeightEMU: spaces.emu.height)
        }

        return "<w:p><w:pPr>"
            + "<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"10\" w:lineRule=\"exact\"/>"
            + "<w:rPr><w:sz w:val=\"2\"/><w:szCs w:val=\"2\"/></w:rPr></w:pPr>"
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
        pageHeightEMU: CGFloat
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
            blockID: block.id
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
    private func restoredTextBoxContent(_ block: ReconstructBlock, pageSizeEMU: CGSize) -> String? {
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
                return lines.map { line in
                    lineParagraphXML(
                        line,
                        block: block,
                        style: style,
                        bold: bold,
                        pageHeightPT: pageHeightPT,
                        pageWidthPT: pageWidthPT,
                        lineTwips: max(1, Int((line.height * pageHeightPT * 20).rounded())),
                        indLeftTwips: max(0, Int((line.leadingOffset * pageWidthTwips).rounded()))
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
                baseFontPT: fontPT
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
        style: String,
        bold: Bool,
        pageHeightPT: Double,
        pageWidthPT: Double,
        lineTwips: Int,
        indLeftTwips: Int
    ) -> String {
        let boldXML = bold ? "<w:b/>" : ""
        let fontPT = LayoutTypography.lineFontPT(line: line, block: block, pageHeightPT: pageHeightPT)
        let size = Int((fontPT * 2).rounded())
        let runs: String
        if let segments = line.segments, !segments.isEmpty {
            runs = segmentRunsXML(
                segments,
                boldXML: boldXML,
                size: size,
                fontPT: fontPT,
                pageWidthPT: pageWidthPT
            )
        } else {
            runs = """
                <w:r>
                  <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                  <w:t xml:space="preserve">\(escape(line.text))</w:t>
                </w:r>
            """
        }
        return """
            <w:p>
              <w:pPr><w:pStyle w:val="\(style)"/><w:spacing w:before="0" w:after="0" w:line="\(lineTwips)" w:lineRule="exact"/><w:ind w:left="\(indLeftTwips)"/></w:pPr>
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
        boldXML: String,
        size: Int,
        fontPT: Double,
        pageWidthPT: Double
    ) -> String {
        segments.indices.map { index in
            let segment = segments[index]
            let textRun = """
                  <w:r>
                    <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                    <w:t xml:space="preserve">\(escape(segment.text))</w:t>
                  </w:r>
            """
            guard index < segments.count - 1 else { return textRun }
            let next = segments[index + 1]
            let gap = next.offset - (segment.offset + segment.width)
            let connector: String
            if let spaces = LayoutTypography.gapPlaceholderSpaces(
                gapWidthNormalized: gap,
                fontPT: fontPT,
                pageWidthPT: pageWidthPT
            ) {
                let blanks = String(repeating: " ", count: spaces)
                // rPr 子元素次序遵循 CT_RPr 模式序列：b → sz → szCs → u
                connector = """
                      <w:r>
                        <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/><w:u w:val="single"/></w:rPr>
                        <w:t xml:space="preserve">\(blanks)</w:t>
                      </w:r>
                """
            } else {
                connector = """
                      <w:r>
                        <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
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

    /// 版面还原档的「重排」块：进覆盖 mask + 浮动文本框（保留区之外全部）。
    private func isRestoredText(_ kind: ReconstructBlockKind) -> Bool {
        !isRestoredCrop(kind)
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
        let index = nextImage
        nextImage += 1
        var ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
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

    /// 覆盖矩形 shape：LayoutMask 的净化矩形（环带 median 底色），无边框。
    private func maskShapeXML(cx: Int64, cy: Int64, fillHex: String) -> String {
        "<wps:wsp><wps:cNvSpPr/><wps:spPr>"
            + "<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            + "<a:solidFill><a:srgbClr val=\"\(fillHex)\"/></a:solidFill>"
            + "<a:ln><a:noFill/></a:ln>"
            + "</wps:spPr><wps:bodyPr/></wps:wsp>"
    }

    /// 浮动文本框：`wps:txbx` 内是**真实段落**（Word 里可直接编辑，FR-007）；
    /// 自身 noFill —— 它叠在覆盖 shape 之上，不得再糊一层底色。
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
    /// mask 环带采样与预览一致，也不把整页原图拉进内存。
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
        blockID: UUID? = nil
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
                blockID: blockID
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
        blockID: UUID?
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

        // 单元格字号自适应 + atLeast 升级判定（与预览共享同一对度量函数）
        var sizeHalfPoints: [[Int]] = []
        var growthRow: Int?
        for (rowIndex, row) in table.rows.enumerated() {
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            var rowSizes: [Int] = []
            for (column, cell) in padded.prefix(columns).enumerated() {
                let columnWidthPT = Double(columnWidths[column]) / 20
                let fontPT = LayoutTypography.tableCellFontPT(
                    text: cell,
                    columnWidthPT: columnWidthPT,
                    rowHeightPT: rowHeightPT,
                    baseFontPT: baseCellFontPT
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

        let rows = table.rows.enumerated().map { rowIndex, row -> String in
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            let cells = padded.prefix(columns).enumerated().map { column, cell -> String in
                let size = sizeHalfPoints[rowIndex][column]
                return "<w:tc>"
                    + "<w:tcPr><w:tcW w:w=\"\(columnWidths[column])\" w:type=\"dxa\"/></w:tcPr>"
                    + "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
                    + "<w:r><w:rPr><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr>"
                    + "<w:t xml:space=\"preserve\">\(escape(cell))</w:t></w:r></w:p>"
                    + "</w:tc>"
            }.joined()
            return "<w:tr><w:trPr><w:trHeight w:val=\"\(rowHeightTwips)\" w:hRule=\"\(hRule)\"/></w:trPr>"
                + cells
                + "</w:tr>"
        }.joined()
        let grid = columnWidths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        return "<w:tbl><w:tblPr>"
            + "<w:tblpPr w:leftFromText=\"0\" w:rightFromText=\"0\" w:horzAnchor=\"page\" w:vertAnchor=\"page\""
            + " w:tblpX=\"\(position.x)\" w:tblpY=\"\(position.y)\"/>"
            + "<w:tblW w:w=\"\(totalWidth)\" w:type=\"dxa\"/>"
            + "<w:tblBorders>"
            + "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>"
            + "</w:tblBorders>"
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
