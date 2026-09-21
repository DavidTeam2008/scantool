import ImageIO
import SwiftUI
import UIKit

/// 版面还原档预览画布（spec/layout-restore plan D6，三层渲染）。
///
/// ZStack 三层：
/// 1. **底座**：整页 rendered 原图 aspect-fit（**下采样**加载，目标 ≈ 屏幕点数 × scale，
///    ImageIO 缩略图，不整图进内存）；缺失时退化纸色底。
/// 2. **覆盖层**：`LayoutMask` 的净化矩形（`LayoutMaskBuilder` 环带 median 填充色），
///    盖掉原字迹 —— 替代旧版「文字下垫半透明纸底」的 hack。
/// 3. **元素层**：文本/表格按 bbox 原位渲染干净内容（字号走 `LayoutTypography`
///    实测行高推导，spec/layout-engine plan D4；无实测才回退 relativeFontSize
///    兜底公式）；有 `lines` 的块逐行帧渲染（plan D7）；表格按实测列宽/行高
///    封顶绘制（plan D8）；
///    **figure / barcode / artwork 不绘制** —— 底座原像素透出即视觉呈现（FR-003）。
///
/// 坐标全部经 `PageLayoutMapper`（Vision 归一化 → 画布空间，y 翻转集中于此）。
/// 对外接口与旧版一致：`LayoutCanvas(page:backgroundImageURL:)`。
struct LayoutCanvas: View {
    let page: ReconstructPage
    /// 版面还原档传入页面 rendered 原图（底座）；缺失时退化纸色底、无覆盖层。
    let backgroundImageURL: URL?

    /// 底座下采样上限（像素）：屏幕宽度 ≈ 400pt × 3x scale ≈ 1200px，2048 留足余量。
    private static let baseMaxPixelSize = 2048

    private var aspect: CGFloat {
        guard page.size.width > 0, page.size.height > 0 else { return 3.0 / 4.0 }
        return page.size.width / page.size.height
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width / aspect
            let baseImage = backgroundImageURL.flatMap(Self.loadDownsampled)
            // 版面还原档读布局后块集（spec/layout-engine plan D9 / FR-012 双档隔离）：
            // restoredBlocks = 区域布局引擎产物（跨栏拆分/碰撞位移）；nil = 旧产物
            // 退化恒等。mask 与元素层同源同一份。
            let blocks = page.restoredBlocks ?? page.blocks
            // 覆盖矩形只在有底座时构建（采样底色）；无底座退化白底时无需净化。
            let mask = (baseImage?.cgImage).map { cgImage in
                LayoutMaskBuilder.build(blocks: blocks, baseImage: cgImage)
            } ?? LayoutMask(fills: [])
            // 画布与页面同比例 → 纯线性缩放（offset = 0），y 翻转集中在映射里。
            let map = PageLayoutMapper.map(
                pageSize: page.size,
                targetSize: CGSize(width: width, height: height)
            )

            ZStack(alignment: .topLeading) {
                // 1. 底座：下采样整页图（缺失退化纸色）
                if let baseImage {
                    Image(uiImage: baseImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    Tokens.paper
                }
                // 2. 覆盖层：净化矩形（环带 median 底色），盖掉原字迹
                ForEach(Array(mask.fills.enumerated()), id: \.offset) { _, fill in
                    let rect = map.rect(fill.rect)
                    Rectangle()
                        .fill(Color(
                            red: Double(fill.red) / 255,
                            green: Double(fill.green) / 255,
                            blue: Double(fill.blue) / 255
                        ))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                // 3. 元素层：文本/表格原位重排；figure/barcode/artwork 不绘制（底座透出）
                ForEach(blocks) { block in
                    canvasElement(block, map: map)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tokens.line, lineWidth: 0.5)
        )
    }

    // MARK: - 元素层

    @ViewBuilder
    private func canvasElement(_ block: ReconstructBlock, map: PageLayoutMap) -> some View {
        switch block.kind {
        case .figure, .barcode, .artwork:
            // 底座原像素透出：不绘制、不覆盖（FR-003/FR-005）。
            EmptyView()
        default:
            let font = fontSize(for: block, map: map)
            // 有 lines 的文本/标题块逐行定位渲染（plan D7）：行帧 = 实测行高自块顶
            // 累积 + 行首偏移（resolvedLineFrames，块内不越界），每行独立 Text，
            // 字号走共享函数；块仍是单元素（mask 矩形 / txbx 语义不变）。表格块
            // （含无行列退化表）不走逐行——网格 / displayText 兜底路径保持原样。
            // 逐行 Text **不加** minimumScaleFactor（T027 刻意）：字号 = 实测行高 ×
            // 1.05，SwiftUI 单行固有高 ≈ 1.2 × 字号 ≈ 1.26 × 行帧高——加了会系统性
            // 全量缩 ~20%，破坏与 Word `w:line` exact 行段（不缩字号）的同构；
            // 这些块的溢出已在解析期由引擎溢出阶梯兜底（T026），行帧紧箍无妨。
            if let lines = block.lines, !lines.isEmpty, block.kind != .table {
                let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block.bbox)
                let weight: Font.Weight = block.kind == .heading ? .bold : .regular
                // T008（spec/scan-fidelity US1）：字号行级化 —— `lineFontPT`（行实测高
                // 推导，与 DOCX 逐行 w:sz 同源）→ `canvasFontPT`（画布换算），每行一档。
                // 异构行高块与 Word 行段双端「字号 / 页高」比例恒等（FR-004）。
                let pageHeightPT = Double(map.pageSize.height) * LayoutTypography.ptPerPixel
                // T013（spec/scan-fidelity US2 / FR-005）：空隙下划线判定与 DOCX
                // （T012）共用 `gapPlaceholderSpaces` 阈值——双端同一空档同画/同不画。
                let pageWidthPT = Double(map.pageSize.width) * LayoutTypography.ptPerPixel
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    let lineRect = map.rect(frames[index])
                    let lineFontPTValue = LayoutTypography.lineFontPT(
                        line: line,
                        block: block,
                        pageHeightPT: pageHeightPT
                    )
                    let lineFont = CGFloat(
                        LayoutTypography.canvasFontPT(
                            fontPT: lineFontPTValue,
                            pageHeightPT: pageHeightPT,
                            map: map
                        )
                    )
                    if let segments = line.segments, !segments.isEmpty {
                        // T013：分段定位渲染——段帧 = 行帧的 y 带 + 段水平区间
                        // （`offset` 与 `leadingOffset` 同基准，块相对 minX）。
                        // 段 Text `fixedSize`：宁可溢出不可折行（折行 = 溢进行距
                        // 与相邻行叠字，溢出只是轻微超宽）。单段行的段帧与整行帧
                        // 几何恒等（offset == leadingOffset、width == 行宽）。
                        ForEach(segments.indices, id: \.self) { segIndex in
                            let segment = segments[segIndex]
                            let segRect = map.rect(
                                CGRect(
                                    x: block.bbox.minX + segment.offset,
                                    y: frames[index].minY,
                                    width: segment.width,
                                    height: frames[index].height
                                )
                            )
                            Text(segment.text)
                                .font(.system(size: lineFont, weight: weight))
                                .foregroundStyle(Tokens.ink)
                                .fixedSize()
                                .frame(
                                    width: max(segRect.width, 12),
                                    height: max(segRect.height, 14),
                                    alignment: .topLeading
                                )
                                .position(x: segRect.midX, y: segRect.midY)
                        }
                        // 段间空隙 ≥ 0.6 字符宽（与 T012 同一判定）→ 基线下划线
                        // 矩形：行框底部 10% 带，宽 = 空隙，色 = 正文墨色——填空
                        // 空档在预览与 Word 里同为可见的下划线占位。
                        ForEach(segments.indices, id: \.self) { segIndex in
                            if segIndex < segments.count - 1 {
                                let gap = segments[segIndex + 1].offset
                                    - (segments[segIndex].offset + segments[segIndex].width)
                                if gap > 0, LayoutTypography.gapPlaceholderSpaces(
                                    gapWidthNormalized: gap,
                                    fontPT: lineFontPTValue,
                                    pageWidthPT: pageWidthPT
                                ) != nil {
                                    let underlineRect = map.rect(
                                        CGRect(
                                            x: block.bbox.minX + segments[segIndex].offset
                                                + segments[segIndex].width,
                                            y: frames[index].minY,
                                            width: gap,
                                            height: frames[index].height * 0.10
                                        )
                                    )
                                    Rectangle()
                                        .fill(Tokens.ink)
                                        .frame(
                                            width: max(underlineRect.width, 2),
                                            height: max(underlineRect.height, 1)
                                        )
                                        .position(x: underlineRect.midX, y: underlineRect.midY)
                                }
                            }
                        }
                    } else {
                        // 无 segments 的旧行（旧持久化档）：整行文本路径，行为不变。
                        Text(line.text)
                            .font(.system(size: lineFont, weight: weight))
                            .foregroundStyle(Tokens.ink)
                            .frame(
                                width: max(lineRect.width, 12),
                                height: max(lineRect.height, 14),
                                alignment: .topLeading
                            )
                            .position(x: lineRect.midX, y: lineRect.midY)
                    }
                }
            } else {
                let rect = map.rect(block.bbox)
                let boxWidth = max(rect.width, 12)
                let boxHeight = max(rect.height, 14)
                Group {
                    switch block.kind {
                    case .table:
                        if let table = block.table, !table.rows.isEmpty {
                            // 与 Word 同一量化链（restoredFontSize 同式）：fontPT →
                            // 整半磅 → ×0.8 —— 双端基础字号必须逐位相等
                            let pageHeightPT = Double(map.pageSize.height) * LayoutTypography.ptPerPixel
                            let blockFontPT = LayoutTypography.fontPT(for: block, pageHeightPT: pageHeightPT)
                            let baseCellFontPT = Double(Int((blockFontPT * 2).rounded())) / 2 * 0.8
                            canvasTable(
                                table,
                                baseCellFontPT: baseCellFontPT,
                                boxWidth: boxWidth,
                                boxHeight: boxHeight,
                                pageHeightPT: pageHeightPT,
                                map: map
                            )
                        } else {
                            // 渲染期兜底（T027 / plan D6）：无 lines 块不经引擎溢出
                            // 阶梯，文本超出块框时 SwiftUI 原生「缩到放得下」——
                            // 与 Word 侧布局期预缩 w:sz 语义同构（缩到放得下、不裁剪）。
                            Text(block.displayText)
                                .font(.system(size: font))
                                .foregroundStyle(Tokens.ink)
                                .minimumScaleFactor(0.5)
                        }
                    case .heading:
                        Text(block.text)
                            .font(.system(size: font, weight: .bold))
                            .foregroundStyle(Tokens.ink)
                            .minimumScaleFactor(0.5)
                    default:
                        Text(block.text)
                            .font(.system(size: font))
                            .foregroundStyle(Tokens.ink)
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(width: boxWidth, height: boxHeight, alignment: .topLeading)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// 字号走 LayoutTypography 共享推导（plan D4）：实测行高 → 文档页 pt 字号
    /// （钳制 [7, 28] 只在页 pt 空间发生一次）→ `canvasFontPT` 按画布映射比例换算
    /// （预览空间 = 页 pt ÷ 画布缩放）；无实测数据的块走兜底公式（页高 1.8% ×
    /// relativeFontSize）。预览与 DOCX 同一入口——双端「字号 / 页高」比例恒等
    /// （FR-004，钳制不再一端触发另一端不触发）。
    private func fontSize(for block: ReconstructBlock, map: PageLayoutMap) -> CGFloat {
        let pageHeightPT = Double(map.pageSize.height) * LayoutTypography.ptPerPixel
        let fontPT = LayoutTypography.fontPT(for: block, pageHeightPT: pageHeightPT)
        return CGFloat(
            LayoutTypography.canvasFontPT(fontPT: fontPT, pageHeightPT: pageHeightPT, map: map)
        )
    }

    /// 表格网格（US5/FR-008，与 DOCX 原生浮动表格同构——plan D8）：列宽按实测
    /// `columnRatios`（nil/列数不符 → 均分兜底，与 Word tblGrid 同一契约）；行高
    /// = 区域高 ÷ 行数（对应 Word trHeight exact）；单元格字号与「放不下」判定
    /// 共用 `LayoutTypography` 的页 pt 度量——Word 同一函数 → 同判同缩（FR-008）。
    /// 放不下 → 行高按同一估算增长到内容高（对应 Word atLeast 升级），文字不
    /// 截断；`.clipped()` 仅在字号已到 7pt 下限的格子兜底（D8：正常路径内容经
    /// 布局期估算已放得下）。
    private func canvasTable(
        _ table: ReconstructTable,
        baseCellFontPT: Double,
        boxWidth: CGFloat,
        boxHeight: CGFloat,
        pageHeightPT: Double,
        map: PageLayoutMap
    ) -> some View {
        let columns = max(table.columnCount, 1)
        let rowCount = max(table.rows.count, 1)
        let canvasPageHeight = Double(map.pageSize.height) * Double(map.scale)
        // 退化映射（页高/画布 ≤ 0）按 1:1 透传（`canvasFontPT` 同语义），不产生 NaN
        let toPagePT = (pageHeightPT > 0 && canvasPageHeight > 0)
            ? pageHeightPT / canvasPageHeight
            : 1 // 画布 pt → 页 pt
        let toCanvasPT = 1 / toPagePT

        // 列宽（画布 pt）：与 Word tblGrid 同一比例契约（列数相符才生效）
        let columnWidthsCanvas: [CGFloat]
        if let ratios = table.columnRatios, ratios.count == columns {
            columnWidthsCanvas = ratios.map { max(CGFloat($0) * boxWidth, 4) }
        } else {
            columnWidthsCanvas = Array(repeating: boxWidth / CGFloat(columns), count: columns)
        }

        // 行高（页 pt 判定）：区域高 ÷ 行数（对应 Word exact val）
        let baseRowHeightCanvas = max(boxHeight / CGFloat(rowCount), 8)
        let baseRowHeightPT = Double(baseRowHeightCanvas) * toPagePT

        // 每格字号（页 pt 自适应 → 画布 pt）+ 行高增长需求（与 Word atLeast 同判）
        var cellFontsCanvas: [[CGFloat]] = []
        var rowHeightsCanvas: [CGFloat] = []
        for row in table.rows {
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            var fonts: [CGFloat] = []
            var neededHeightPT = 0.0
            for (column, cell) in padded.prefix(columns).enumerated() {
                let columnWidthPT = Double(columnWidthsCanvas[column]) * toPagePT
                let fontPT = LayoutTypography.tableCellFontPT(
                    text: cell,
                    columnWidthPT: columnWidthPT,
                    rowHeightPT: baseRowHeightPT,
                    baseFontPT: baseCellFontPT
                )
                fonts.append(CGFloat(fontPT) * CGFloat(toCanvasPT))
                neededHeightPT = max(
                    neededHeightPT,
                    LayoutTypography.tableCellHeightPT(text: cell, columnWidthPT: columnWidthPT, fontPT: fontPT)
                )
            }
            cellFontsCanvas.append(fonts)
            // 增长策略（Word atLeast 同构）：放不下 → 行高长到估算内容高，文字不截断
            rowHeightsCanvas.append(max(baseRowHeightCanvas, CGFloat(neededHeightPT) * CGFloat(toCanvasPT)))
        }

        // 7pt 下限的画布当量（.clipped() 兜底判定）
        let floorFontCanvas = CGFloat(LayoutTypography.minFontPT) * CGFloat(toCanvasPT)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                let padded = row + Array(repeating: "", count: max(0, columns - row.count))
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let cellFont = cellFontsCanvas[rowIndex][column]
                        let cell = Text(padded[column])
                            .font(.system(size: cellFont))
                            .foregroundStyle(Tokens.ink)
                            .frame(
                                width: columnWidthsCanvas[column],
                                height: rowHeightsCanvas[rowIndex],
                                alignment: .topLeading
                            )
                            .padding(2)
                            .border(Tokens.line, width: 0.5)
                        // .clipped() 仅在字号已到 7pt 下限后兜底（D8）：
                        // 正常/增长路径内容经布局期估算已放得下，不裁剪
                        if cellFont <= floorFontCanvas * 1.0001 {
                            cell.clipped()
                        } else {
                            cell
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底座下采样（ImageIO 缩略图，不整图进内存）

    private static func loadDownsampled(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: baseMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
