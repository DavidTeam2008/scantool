import CoreGraphics
import Foundation

/// 版面还原档的覆盖矩形构建（spec/layout-restore plan D3）。
///
/// 对每个**将被重排干净文本的块**（heading/paragraph/list/table/checkbox/handwrittenBlank）：
/// - 覆盖矩形 = 块 bbox **外扩 1~2%**（块级覆盖而非行级，避免字迹缝隙残留 ——
///   `ReconstructBlock` 已是行聚类后的块级 bbox）；
/// - 填充色 = bbox **环带**（四周条带）像素的**逐通道 median** RGB —— median 抗噪
///   （字迹像素不主导），逐通道 median 保留底色色相（彩色海报不退化成灰块）。
///
/// figure / barcode / artwork 是「底座原像素透出」的保留区域，**不进 mask**（FR-003）。
/// 读像素循 `InkFigureDetector` 先例：整图一次性缩略栅格化，无新 I/O 边界（Domain 无磁盘/网络）。
enum LayoutMaskBuilder {
    /// 外扩幅度（页宽/页高单位的每侧）：1.5%，落在 plan 约定的 1~2% 区间中点。
    static let expansion: CGFloat = 0.015
    /// 环带厚度（页宽/页高单位）：与外扩同宽，紧贴覆盖矩形取底色。
    static let ringThickness: CGFloat = 0.015
    /// 底色栅格宽度。240 列 ≈ 每列 0.4% 页宽，环带 1.5% ≈ 3~4 列采样，色相保真足够。
    static let gridWidth = 240
    /// 环带完全出页（整页块）时的退化填充：白（与无底座画布的底色一致）。
    static let fallbackFill = LayoutMask.Fill(rect: .zero, red: 255, green: 255, blue: 255)

    /// 构建一页的覆盖 mask。块的顺序保持输入顺序（fills 与 blocks 一一对应，便于调试定位）。
    static func build(blocks: [ReconstructBlock], baseImage: CGImage) -> LayoutMask {
        guard let raster = rasterize(baseImage) else {
            // 图都栅格化不出来（零尺寸等退化输入）：全部退化白填充，预览/导出仍可用。
            return LayoutMask(
                fills: blocks.filter(isMasked).map { block in
                    LayoutMask.Fill(
                        rect: expanded(block.bbox),
                        red: fallbackFill.red,
                        green: fallbackFill.green,
                        blue: fallbackFill.blue
                    )
                }
            )
        }
        return LayoutMask(
            fills: blocks.filter(isMasked).map { block in
                let rect = expanded(block.bbox)
                let color = ringMedian(rect, in: raster)
                return LayoutMask.Fill(rect: rect, red: color.0, green: color.1, blue: color.2)
            }
        )
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

        // CGContext 原点左下 → 栅格原点左上
        var red = [UInt8](repeating: 255, count: columns * rows)
        var green = [UInt8](repeating: 255, count: columns * rows)
        var blue = [UInt8](repeating: 255, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let source = ((rows - 1 - row) * columns + column) * 4
                let target = row * columns + column
                red[target] = pixels[source]
                green[target] = pixels[source + 1]
                blue[target] = pixels[source + 2]
            }
        }
        return Raster(columns: columns, rows: rows, red: red, green: green, blue: blue)
    }

    /// 覆盖矩形**环带**（rect 外圈 `ringThickness` 厚的条带，夹在页内）像素的逐通道 median。
    /// 环带出页（整页块）→ 退化白。
    private static func ringMedian(
        _ rect: CGRect,
        in raster: Raster
    ) -> (UInt8, UInt8, UInt8) {
        let outer = rect
            .insetBy(dx: -ringThickness, dy: -ringThickness)
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

        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []
        for row in edge.rowMin...edge.rowMax {
            for column in edge.columnMin...edge.columnMax {
                let inInner = column >= inner.columnMin && column <= inner.columnMax
                    && row >= inner.rowMin && row <= inner.rowMax
                guard !inInner else { continue }
                let index = row * raster.columns + column
                reds.append(raster.red[index])
                greens.append(raster.green[index])
                blues.append(raster.blue[index])
            }
        }
        guard !reds.isEmpty else {
            return (fallbackFill.red, fallbackFill.green, fallbackFill.blue)
        }
        return (median(reds), median(greens), median(blues))
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
}
