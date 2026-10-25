import CoreGraphics
import Foundation

/// 版面还原档的覆盖矩形构建（spec/layout-restore plan D3）。
///
/// 对每个**将被重排干净文本的块**（heading/paragraph/list/table/checkbox/handwrittenBlank）：
/// - 覆盖矩形 = 块 bbox **外扩 1~2%**（块级覆盖而非行级，避免字迹缝隙残留 ——
///   `ReconstructBlock` 已是行聚类后的块级 bbox）；
/// - 填充色 = **块内部 median** 与 **环带主色 mode** 中更亮的一个 —— 真实教材页
///   两类失败都要防：
///   ① 环带下方紧贴深色表头/照片时，median 会被拉成深灰，整块盖成灰板
///      （2026-10-22 真机 WPS/QuickLook 0.72 的根因）；
///   ② 块上下两侧都是深色（Articles 白框夹在深色栏头与深色表头之间）时，环带
///      mode 也会是深色，仍会把白框盖灰（2026-10-23 真实 UI 底图复测）。
///   内部 median 对「白底 + 少量文字」给白底，对「整块深色文字区」给深色；
///   与环带主色取更亮者，既保住白框又不把整块深色区域刷白。
///
/// figure / barcode / artwork 是「底座原像素透出」的保留区域，**不进 mask**（FR-003）。
/// 读像素循 `InkFigureDetector` 先例：整图一次性缩略栅格化，无新 I/O 边界（Domain 无磁盘/网络）。
enum LayoutMaskBuilder {
    /// 覆盖粒度（2026-10-23 混合模式 H2）：
    /// - `.block`：整块外扩覆盖。旧行为，表格/无行几何块仍走这里；
    /// - `.line`：逐行/逐段覆盖。正文按 OCR 行框擦字，保留行间边框、深色栏头、
    ///   照片和装饰块；导出的可编辑文字再按同一份行框叠回去。
    enum Granularity: Sendable {
        case block
        case line
    }

    /// 外扩幅度（页宽/页高单位的每侧）：1.5%，落在 plan 约定的 1~2% 区间中点。
    static let expansion: CGFloat = 0.015
    /// 行级外扩：只够盖住抗锯齿边缘，避免把行间边框/深色栏头/照片一起刷掉。
    /// 0.004 页高 ≈ 真实 UI 底图 8.8px（2200px 高），足以覆盖 1~2px 的抗锯齿边。
    static let lineExpansion: CGFloat = 0.004
    /// 行级取色环带：紧贴行框外沿。不能复用块级的 1.5%——行框比块框小得多，
    /// 1.5% 会把相邻行/白边带进来；0.003 页高 ≈ 6.6px，只取文字周围的底色。
    static let lineRingThickness: CGFloat = 0.003
    /// 环带厚度（页宽/页高单位）：与外扩同宽，紧贴覆盖矩形取底色。
    static let ringThickness: CGFloat = 0.015
    /// 底色栅格宽度。240 列 ≈ 每列 0.4% 页宽，环带 1.5% ≈ 3~4 列采样，色相保真足够。
    static let gridWidth = 240
    /// 环带完全出页（整页块）时的退化填充：白（与无底座画布的底色一致）。
    static let fallbackFill = LayoutMask.Fill(rect: .zero, red: 255, green: 255, blue: 255)

    /// 构建一页的覆盖 mask。默认 `.block` 保持旧契约；混合模式显式传 `.line`。
    static func build(
        blocks: [ReconstructBlock],
        baseImage: CGImage,
        granularity: Granularity = .block
    ) -> LayoutMask {
        guard let raster = rasterize(baseImage) else {
            // 图都栅格化不出来（零尺寸等退化输入）：全部退化白填充，预览/导出仍可用。
            return LayoutMask(
                fills: blocks.filter(isMasked).flatMap { block in
                    fallbackFills(for: block, granularity: granularity)
                }
            )
        }
        return LayoutMask(
            fills: blocks.filter(isMasked).flatMap { block in
                switch granularity {
                case .block:
                    return [blockFill(block, in: raster)]
                case .line:
                    return lineFills(for: block, in: raster)
                }
            }
        )
    }

    /// 单个块级覆盖（旧行为）：整块 bbox 外扩 + 环带/内部取更亮底色。
    private static func blockFill(_ block: ReconstructBlock, in raster: Raster) -> LayoutMask.Fill {
        let rect = expanded(block.bbox)
        let color = backgroundFillColor(block.bbox, ringRect: rect, in: raster)
        return LayoutMask.Fill(rect: rect, red: color.0, green: color.1, blue: color.2)
    }

    /// 表格块的整块擦除：原表有深色表头/文字，内部 median 会被拉成灰板；表格
    /// 外围仍是纸面，取环带主色作为表格衬底，再由原生表格 XML 重建表头底色/
    /// 白字与无网格正文。无行几何的普通文本块仍走 `blockFill`。
    private static func tableFillIfNeeded(
        _ block: ReconstructBlock,
        in raster: Raster
    ) -> LayoutMask.Fill {
        guard block.kind == .table else { return blockFill(block, in: raster) }
        let rect = expanded(block.bbox)
        let color = ringDominantColor(block.bbox, thickness: 0.012, in: raster)
        return LayoutMask.Fill(rect: rect, red: color.0, green: color.1, blue: color.2)
    }

    /// 行/段级覆盖：表格与无行几何块仍按块覆盖；文本块逐行（有 segments 时逐段）
    /// 擦除，行间/段间留给底座原像素 —— 这是「保留装饰、只擦文字」的关键。
    private static func lineFills(for block: ReconstructBlock, in raster: Raster) -> [LayoutMask.Fill] {
        guard block.kind != .table,
              let lines = block.lines,
              !lines.isEmpty
        else {
            return [tableFillIfNeeded(block, in: raster)]
        }
        let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block.bbox)
        var fills: [LayoutMask.Fill] = []
        fills.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() where index < frames.count {
            let frame = frames[index]
            // 一行一个底色：同一行的左右两栏/段共享行框背景。逐段取色会让
            // 粗体白字紧框（“Writing”“wanted!”）把白字簇当底色，白字擦不掉；
            // 左右深色栏头本来也是同一深底，行级取色足够。
            let lineRectForColor = lineRect(x: frame.minX, width: frame.width, frame: frame)
            guard !lineRectForColor.isEmpty else { continue }
            let color = lineBackgroundFillColor(lineRectForColor, in: raster)
            if let segments = line.segments, !segments.isEmpty {
                for segment in segments {
                    let rect = lineRect(
                        x: block.bbox.minX + segment.offset,
                        width: segment.width,
                        frame: frame
                    )
                    guard !rect.isEmpty else { continue }
                    fills.append(LayoutMask.Fill(
                        rect: expandedLine(rect),
                        red: color.0,
                        green: color.1,
                        blue: color.2,
                        mode: .textPixels
                    ))
                }
            } else {
                fills.append(LayoutMask.Fill(
                    rect: expandedLine(lineRectForColor),
                    red: color.0,
                    green: color.1,
                    blue: color.2,
                    mode: .textPixels
                ))
            }
        }
        // 行几何退化（lines 非空但 frames 为空）：至少保留块级擦除，避免原字残留。
        return fills.isEmpty ? [blockFill(block, in: raster)] : fills
    }

    private static func lineRect(x: CGFloat, width: CGFloat, frame: CGRect) -> CGRect {
        CGRect(x: x, y: frame.minY, width: width, height: frame.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 行级底色：取**行框内部的主色（众数）**，不用 median，也不取外圈。
    ///
    /// 行框是 OCR 墨迹框，背景通常占多数（即使粗体字也少有 >50% 覆盖）；
    /// 逐通道 median 会被少量高对比笔画拉灰（标题蓝条 39,40,55 → 67,69,82），
    /// 外圈又会被标题条上下白边污染（白 219,227,254）。量化主色只认出现最多
    /// 的背景桶，白字/黑字笔画分散到多个桶，不会成为主色。深色栏头里的白字行
    /// 因此保留深色底，白底正文仍是纸色。
    private static func lineBackgroundFillColor(
        _ rect: CGRect,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8) {
        // 行框内部主色（经过 WPS 实测，粗体行也不会把白字簇当底色）。
        let mode = interiorDominantColor(rect, in: raster)
        let modeLuma = luminance(mode)
        guard modeLuma >= 150 else { return mode }

        // 行框跨在深色栏头下缘时（studying after school?），均匀纸面会在
        // 单桶众数里赢过带纹理的深色栏头。看**行框边界带**的深色占比：
        // 文字墨迹在中心，不会把边界带刷黑；深色栏头会。边界深色过半则
        // 取深色像素均色作为底色，白字才不会留在底图上。
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let columnMin = max(0, min(raster.columns - 1, Int(clipped.minX * CGFloat(raster.columns))))
        let columnMax = max(0, min(raster.columns - 1, Int(clipped.maxX * CGFloat(raster.columns))))
        let rowMin = max(0, min(raster.rows - 1, Int((1 - clipped.maxY) * CGFloat(raster.rows))))
        let rowMax = max(0, min(raster.rows - 1, Int((1 - clipped.minY) * CGFloat(raster.rows))))
        guard columnMax >= columnMin, rowMax >= rowMin else { return mode }
        let width = columnMax - columnMin + 1
        let height = rowMax - rowMin + 1
        let bandX = max(1, Int(Double(width) * 0.2))
        let bandY = max(1, Int(Double(height) * 0.2))
        var darkCount = 0
        var darkRed = 0
        var darkGreen = 0
        var darkBlue = 0
        var bandCount = 0
        for row in rowMin...rowMax {
            for column in columnMin...columnMax {
                let inBand = column < columnMin + bandX || column > columnMax - bandX
                    || row < rowMin + bandY || row > rowMax - bandY
                guard inBand else { continue }
                let index = row * raster.columns + column
                let red = Int(raster.red[index])
                let green = Int(raster.green[index])
                let blue = Int(raster.blue[index])
                bandCount += 1
                guard (red * 299 + green * 587 + blue * 114) / 1000 < 110 else { continue }
                darkCount += 1
                darkRed += red
                darkGreen += green
                darkBlue += blue
            }
        }
        guard bandCount > 0, darkCount * 100 >= bandCount * 45 else { return mode }
        return (
            UInt8(max(0, min(255, darkRed / darkCount))),
            UInt8(max(0, min(255, darkGreen / darkCount))),
            UInt8(max(0, min(255, darkBlue / darkCount)))
        )
    }

    private static func fallbackFills(
        for block: ReconstructBlock,
        granularity: Granularity
    ) -> [LayoutMask.Fill] {
        switch granularity {
        case .block:
            return [LayoutMask.Fill(
                rect: expanded(block.bbox),
                red: fallbackFill.red,
                green: fallbackFill.green,
                blue: fallbackFill.blue
            )]
        case .line:
            guard block.kind != .table,
                  let lines = block.lines,
                  !lines.isEmpty
            else {
                return [LayoutMask.Fill(
                    rect: expanded(block.bbox),
                    red: fallbackFill.red,
                    green: fallbackFill.green,
                    blue: fallbackFill.blue
                )]
            }
            let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block.bbox)
            var fills: [LayoutMask.Fill] = []
            for (index, line) in lines.enumerated() where index < frames.count {
                let frame = frames[index]
                if let segments = line.segments, !segments.isEmpty {
                    for segment in segments {
                        let rect = lineRect(
                            x: block.bbox.minX + segment.offset,
                            width: segment.width,
                            frame: frame
                        )
                        guard !rect.isEmpty else { continue }
                        fills.append(LayoutMask.Fill(
                            rect: expandedLine(rect),
                            red: fallbackFill.red,
                            green: fallbackFill.green,
                            blue: fallbackFill.blue,
                            mode: .textPixels
                        ))
                    }
                } else {
                    let rect = lineRect(x: frame.minX, width: frame.width, frame: frame)
                    guard !rect.isEmpty else { continue }
                    fills.append(LayoutMask.Fill(
                        rect: expandedLine(rect),
                        red: fallbackFill.red,
                        green: fallbackFill.green,
                        blue: fallbackFill.blue,
                        mode: .textPixels
                    ))
                }
            }
            return fills.isEmpty ? [LayoutMask.Fill(
                rect: expanded(block.bbox),
                red: fallbackFill.red,
                green: fallbackFill.green,
                blue: fallbackFill.blue
            )] : fills
        }
    }

    /// 被覆盖（重排干净文本）的块种类；figure/barcode/artwork 靠底座原像素透出，不覆盖。
    private static func isMasked(_ block: ReconstructBlock) -> Bool {
        switch block.kind {
        case .figure, .barcode, .artwork:
            return false
        case .heading, .paragraph, .list, .table, .checkbox, .handwrittenBlank:
            return !block.bbox.isEmpty
        }
    }

    /// bbox 四周外扩 `expansion`（页宽/页高单位），并夹在页界 [0,1] 内。
    private static func expanded(_ bbox: CGRect) -> CGRect {
        bbox
            .insetBy(dx: -expansion, dy: -expansion)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 行框四周外扩 `lineExpansion`（页宽/页高单位），并夹在页界 [0,1] 内。
    private static func expandedLine(_ rect: CGRect) -> CGRect {
        rect
            .insetBy(dx: -lineExpansion, dy: -lineExpansion)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - 底色栅格（循 InkFigureDetector 先例）

    private struct Raster {
        var columns: Int
        var rows: Int
        var red: [UInt8]
        var green: [UInt8]
        var blue: [UInt8]
    }

    /// 整图一次性缩略栅格化（原点左上，与 InkFigureDetector 相同的翻转约定）。
    private static func rasterize(_ image: CGImage) -> Raster? {
        let columns = gridWidth
        guard image.width > 0, image.height > 0 else { return nil }
        let rows = max(1, Int((CGFloat(columns) * CGFloat(image.height) / CGFloat(image.width)).rounded()))
        guard rows > 1 else { return nil }

        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard ok else { return nil }

        // CGContext 位图内存首行=图像顶行（实测：这里再翻转一次会把上半页的
        // 标题块采成下半页底色，见 2026-10-23 真实 UI 底图 title 填充
        // (184,190,220) vs 原蓝条 (39,41,56)）。`bakedJPEGData` 的写入坐标
        // 已由 CGContext 自身处理，读栅格不能再翻。
        var red = [UInt8](repeating: 255, count: columns * rows)
        var green = [UInt8](repeating: 255, count: columns * rows)
        var blue = [UInt8](repeating: 255, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let source = (row * columns + column) * 4
                let target = row * columns + column
                red[target] = pixels[source]
                green[target] = pixels[source + 1]
                blue[target] = pixels[source + 2]
            }
        }
        return Raster(columns: columns, rows: rows, red: red, green: green, blue: blue)
    }


    /// 底色选择：内部 median 与环带主色取更亮者（见文件头 2026-10-23 注记）。
    /// 内部采样用**原始块 bbox**（不含外扩），避免外扩边带把周围底色带进来；
    /// 环带用**外扩后的矩形**，与最终覆盖区域同源。
    private static func backgroundFillColor(
        _ bbox: CGRect,
        ringRect: CGRect,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8) {
        let interior = interiorMedianColor(bbox, in: raster)
        let ring = ringDominantColor(ringRect, in: raster)
        guard let interior else { return ring }
        let interiorLuma = luminance(interior)
        let ringLuma = luminance(ring)
        // 浅底：内部就是背景，直接用内部 median（Articles 白框夹在两条深色栏之间
        // 的案例，环带 mode 会取到深色）。
        if interiorLuma >= ringLuma { return interior }
        // 深色**彩色**底：标题蓝条这类块内部确实是深色品牌色，环带却落在页面
        // 浅底上；不能因为环带更亮就把蓝条刷白。饱和度（max−min）≥ 12 视为
        // 有意的彩色底，保留内部色。
        let saturation = Int(max(interior.0, interior.1, interior.2))
            - Int(min(interior.0, interior.1, interior.2))
        if saturation >= 12 { return interior }
        // 深色**中性**内部 + 浅色环带：这是「整块被文字/深色填充」的擦除场景
        // （合成测试的深色文字区、真实页的表头黑块），用环带浅色擦净。
        return ring
    }

    /// 原始 bbox 内部像素的逐通道 median。文字块内部仍以背景为主（文字覆盖
    /// 通常 < 50%），median 对笔画抗噪；整块深色文字区则如实返回深色。
    private static func interiorMedianColor(
        _ rect: CGRect,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8)? {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clipped.width > 0, clipped.height > 0 else { return nil }
        let columnMin = max(0, min(raster.columns - 1, Int(clipped.minX * CGFloat(raster.columns))))
        let columnMax = max(0, min(raster.columns - 1, Int(clipped.maxX * CGFloat(raster.columns))))
        let rowMin = max(0, min(raster.rows - 1, Int((1 - clipped.maxY) * CGFloat(raster.rows))))
        let rowMax = max(0, min(raster.rows - 1, Int((1 - clipped.minY) * CGFloat(raster.rows))))
        guard columnMax >= columnMin, rowMax >= rowMin else { return nil }

        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []
        for row in rowMin...rowMax {
            for column in columnMin...columnMax {
                let index = row * raster.columns + column
                reds.append(raster.red[index])
                greens.append(raster.green[index])
                blues.append(raster.blue[index])
            }
        }
        guard !reds.isEmpty else { return nil }
        return (median(reds), median(greens), median(blues))
    }

    /// 行框内部按 4bit/通道量化的主色。与 `ringDominantColor` 同一投票逻辑，
    /// 但只统计内部：行级擦除时内部主色就是底色，既能保住深色栏头，也不会把
    /// 标题条上下方的白边带进来。
    private static func interiorDominantColor(
        _ rect: CGRect,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8) {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clipped.width > 0, clipped.height > 0 else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        let columnMin = max(0, min(raster.columns - 1, Int(clipped.minX * CGFloat(raster.columns))))
        let columnMax = max(0, min(raster.columns - 1, Int(clipped.maxX * CGFloat(raster.columns))))
        let rowMin = max(0, min(raster.rows - 1, Int((1 - clipped.maxY) * CGFloat(raster.rows))))
        let rowMax = max(0, min(raster.rows - 1, Int((1 - clipped.minY) * CGFloat(raster.rows))))
        guard columnMax >= columnMin, rowMax >= rowMin else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }

        struct Bucket {
            var redSum = 0
            var greenSum = 0
            var blueSum = 0
            var count = 0
        }
        var buckets: [Int: Bucket] = [:]
        for row in rowMin...rowMax {
            for column in columnMin...columnMax {
                let index = row * raster.columns + column
                let red = Int(raster.red[index])
                let green = Int(raster.green[index])
                let blue = Int(raster.blue[index])
                let key = (red / 16) << 8 | (green / 16) << 4 | (blue / 16)
                var bucket = buckets[key] ?? Bucket()
                bucket.redSum += red
                bucket.greenSum += green
                bucket.blueSum += blue
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        guard var best = buckets.values.first else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        for bucket in buckets.values {
            if bucket.count > best.count {
                best = bucket
            } else if bucket.count == best.count {
                let current = best.redSum + best.greenSum + best.blueSum
                let candidate = bucket.redSum + bucket.greenSum + bucket.blueSum
                if candidate > current { best = bucket }
            }
        }
        guard best.count > 0 else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        return (
            UInt8(max(0, min(255, best.redSum / best.count))),
            UInt8(max(0, min(255, best.greenSum / best.count))),
            UInt8(max(0, min(255, best.blueSum / best.count)))
        )
    }

    private static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        let average = (Int(sorted[middle - 1]) + Int(sorted[middle])) / 2
        return UInt8(max(0, min(255, average)))
    }

    private static func luminance(_ color: (UInt8, UInt8, UInt8)) -> Int {
        (Int(color.0) * 299 + Int(color.1) * 587 + Int(color.2) * 114) / 1000
    }

    /// 覆盖矩形**环带**（rect 外圈 `ringThickness` 厚的条带，夹在页内）像素的
    /// **主色**。逐通道量化到 16 级后取出现次数最多的桶，再对桶内真实像素求均值
    /// —— 比 median 抗「环带一侧紧贴深色表头/照片」的污染，同时保留底色色相。
    /// 环带出页（整页块）→ 退化白。
    private static func ringDominantColor(
        _ rect: CGRect,
        thickness: CGFloat = ringThickness,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8) {
        let outer = rect
            .insetBy(dx: -thickness, dy: -thickness)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard outer.width > 0, outer.height > 0 else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }

        // Vision 归一化（左下原点）→ 栅格行列（左上原点）
        func cellRange(_ unit: CGRect) -> (columnMin: Int, columnMax: Int, rowMin: Int, rowMax: Int) {
            let columnMin = max(0, min(raster.columns - 1, Int(unit.minX * CGFloat(raster.columns))))
            let columnMax = max(0, min(raster.columns - 1, Int(unit.maxX * CGFloat(raster.columns))))
            let rowMin = max(0, min(raster.rows - 1, Int((1 - unit.maxY) * CGFloat(raster.rows))))
            let rowMax = max(0, min(raster.rows - 1, Int((1 - unit.minY) * CGFloat(raster.rows))))
            return (columnMin, columnMax, rowMin, rowMax)
        }
        let inner = cellRange(rect)
        let edge = cellRange(outer)

        struct Bucket {
            var redSum = 0
            var greenSum = 0
            var blueSum = 0
            var count = 0
        }
        var buckets: [Int: Bucket] = [:]
        for row in edge.rowMin...edge.rowMax {
            for column in edge.columnMin...edge.columnMax {
                let inInner = column >= inner.columnMin && column <= inner.columnMax
                    && row >= inner.rowMin && row <= inner.rowMax
                guard !inInner else { continue }
                let index = row * raster.columns + column
                let red = Int(raster.red[index])
                let green = Int(raster.green[index])
                let blue = Int(raster.blue[index])
                // 每通道 4 bit（16 级）；亮度用于同票数时优先浅色背景。
                let key = (red / 16) << 8 | (green / 16) << 4 | (blue / 16)
                var bucket = buckets[key] ?? Bucket()
                bucket.redSum += red
                bucket.greenSum += green
                bucket.blueSum += blue
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        guard var best = buckets.values.first else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        for bucket in buckets.values {
            if bucket.count > best.count {
                best = bucket
            } else if bucket.count == best.count {
                // 票数相同取更亮的主色：浅色纸面/白底的概率远高于整块深色底。
                let current = best.redSum + best.greenSum + best.blueSum
                let candidate = bucket.redSum + bucket.greenSum + bucket.blueSum
                if candidate > current { best = bucket }
            }
        }
        guard best.count > 0 else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        return (
            UInt8(max(0, min(255, best.redSum / best.count))),
            UInt8(max(0, min(255, best.greenSum / best.count))),
            UInt8(max(0, min(255, best.blueSum / best.count)))
        )
    }
}
