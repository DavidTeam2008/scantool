import CoreGraphics
import Foundation

/// 用**像素**找配图。
///
/// ## 为什么必须读像素
/// 原来的配图检测全是几何的：把 OCR 文字盒当墙，在网格上找「空白连通域」。
/// 真机反馈（2026-09-12）暴露出这条路的结构性盲区 —— **它区分不了「照片」和「白纸」**。
/// 实测一页教材：整页空白连成了**一整块**（bbox 覆盖 94%×96%，fill 只有 0.27），
/// 插图的空白和页边距、行间距全部连通，于是那张照片从来没有作为独立连通域出现过。
///
/// 像素给出了几何拿不到的判据，但真正管用的**不是**密度 —— 实测同一页：
///
/// | 区域 | fill（墨迹占外接框） | detail | 被文字盒覆盖 |
/// |---|---|---|---|
/// | 照片 | **0.31**（车内有大量亮部，很疏） | 0.32 | 几乎 0 |
/// | 右栏文字块 | **0.60**（比照片还密） | 0.58 | 高 |
///
/// 也就是说「照片比文字密」这个直觉是**错的** —— 密度和局部对比度在这个页面上
/// 都与预期反相关。真正把两者分开的是**「这块区域是不是已经被 OCR 文字盒覆盖了」**：
/// 文字块的 bbox 里塞满了已知的文字行，照片区域里一行字都没有。
/// 所以 `maxTextCoverage` 是主判据，密度只留一个很低的兜底下限。
///
/// 这是补齐 docs/06 §3.2 里承诺过、但一直没做的那一步
/// ——「显著性/边缘等图像信号留给 M3 的配图模块」。
enum InkFigureDetector {

    /// 栅格宽度。120 列在 A4 上约每列 0.8% 页宽，够把照片和文字行分开。
    static let gridWidth = 120
    /// 判「墨」的亮度阈值。纸面（含轻微阴影）通常在 0.75 以上。
    static let inkThreshold: Double = 0.72
    /// 局部对比度阈值：相邻格的亮度差。照片/插图有明显高频，纯阴影是平滑的。
    static let detailThreshold: Double = 0.10

    static let minArea: CGFloat = 0.015
    static let maxArea: CGFloat = 0.45
    /// 很低的兜底下限 —— 只挡「几乎全空」的墨块。实测照片本身只有 0.31。
    static let minFill: CGFloat = 0.20
    static let minHeight: CGFloat = 0.05
    static let minAspect: CGFloat = 0.30
    static let maxAspect: CGFloat = 3.50
    /// **主判据**：墨块外接框被已知文字盒覆盖的比例上限。超过就是文字块，不是图。
    static let maxTextCoverage: CGFloat = 0.35
    /// 墨块里「有细节」的格子占比下限 —— 挡掉大片**平滑**阴影（那种区域相邻格亮度几乎相同）。
    static let minDetailRatio: CGFloat = 0.15

    struct Input {
        var image: CGImage
        /// 已知文字盒（Vision 归一化）。用来挡掉文字块。
        var textBoxes: [CGRect]
        /// 已占用的区域（表格 / 条码），不重复出图。
        var occupied: [CGRect] = []
    }

    static func boxes(_ input: Input) -> [CGRect] {
        guard let grid = rasterize(input.image) else { return [] }
        let columns = grid.columns
        let rows = grid.rows

        // 墨迹格 + 细节格
        var isInk = [Bool](repeating: false, count: columns * rows)
        var isDetailed = [Bool](repeating: false, count: columns * rows)
        for index in 0..<(columns * rows) {
            isInk[index] = grid.darkFraction[index] >= 0.25
            isDetailed[index] = grid.localDetail[index] >= detailThreshold
        }

        var visited = [Bool](repeating: false, count: columns * rows)
        var results: [CGRect] = []

        for start in 0..<(columns * rows) where isInk[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var cells = 0
            var detailed = 0
            var minColumn = columns, maxColumn = 0, minRow = rows, maxRow = 0

            while let current = stack.popLast() {
                let column = current % columns
                let row = current / columns
                cells += 1
                if isDetailed[current] { detailed += 1 }
                minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = column + dc
                    let nr = row + dr
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let next = nr * columns + nc
                    if isInk[next], !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }

            let boxWidth = CGFloat(maxColumn - minColumn + 1) / CGFloat(columns)
            let boxHeight = CGFloat(maxRow - minRow + 1) / CGFloat(rows)
            let area = boxWidth * boxHeight
            guard area >= minArea, area <= maxArea else { continue }
            guard boxHeight >= minHeight else { continue }
            let aspect = boxWidth / boxHeight
            guard aspect >= minAspect, aspect <= maxAspect else { continue }

            let fill = CGFloat(cells) / CGFloat((maxColumn - minColumn + 1) * (maxRow - minRow + 1))
            guard fill >= minFill else { continue }

            let detailRatio = CGFloat(detailed) / CGFloat(cells)
            guard detailRatio >= minDetailRatio else { continue }

            // 网格坐标（原点左上）→ Vision 归一化（原点左下）
            let box = CGRect(
                x: CGFloat(minColumn) / CGFloat(columns),
                y: 1 - CGFloat(maxRow + 1) / CGFloat(rows),
                width: boxWidth,
                height: boxHeight
            )
            guard textCoverage(of: box, textBoxes: input.textBoxes) <= maxTextCoverage else { continue }
            guard !input.occupied.contains(where: { $0.intersects(box) }) else { continue }

            results.append(box)
        }

        return merge(results)
    }

    // MARK: - 栅格化

    private struct Grid {
        var columns: Int
        var rows: Int
        /// 每格里「暗于阈值」的像素占比。
        var darkFraction: [Double]
        /// 每格与右邻格的亮度差（局部高频），取不到右邻时用下邻。
        var localDetail: [Double]
    }

    private static func rasterize(_ image: CGImage) -> Grid? {
        let columns = gridWidth
        guard image.width > 0, image.height > 0 else { return nil }
        let rows = max(1, Int((CGFloat(columns) * CGFloat(image.height) / CGFloat(image.width)).rounded()))
        guard rows > 1 else { return nil }

        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
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

        // CGContext 的 y 轴原点在左下；本文件的栅格一律用「原点左上」，
        // 统一在最后一步转回 Vision 坐标。
        var luminance = [Double](repeating: 1, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let source = ((rows - 1 - row) * columns + column) * 4
                let value = (0.2126 * Double(pixels[source])
                    + 0.7152 * Double(pixels[source + 1])
                    + 0.0722 * Double(pixels[source + 2])) / 255
                luminance[row * columns + column] = value
            }
        }
        // 每格只有一个采样点（栅格已经是缩略图），所以「暗占比」退化为 0/1。
        let darkFraction = luminance.map { $0 < inkThreshold ? 1.0 : 0.0 }
        var localDetail = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let right = column + 1 < columns ? luminance[index + 1] : luminance[index]
                let down = row + 1 < rows ? luminance[index + columns] : luminance[index]
                localDetail[index] = max(abs(luminance[index] - right), abs(luminance[index] - down))
            }
        }
        return Grid(columns: columns, rows: rows, darkFraction: darkFraction, localDetail: localDetail)
    }

    // MARK: - 过滤辅助

    private static func textCoverage(of box: CGRect, textBoxes: [CGRect]) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 0 }
        // 用细网格近似「文字盒并集占 box 的比例」
        let steps = 24
        var covered = 0
        var total = 0
        for row in 0..<steps {
            for column in 0..<steps {
                let point = CGPoint(
                    x: box.minX + (CGFloat(column) + 0.5) / CGFloat(steps) * box.width,
                    y: box.minY + (CGFloat(row) + 0.5) / CGFloat(steps) * box.height
                )
                total += 1
                if textBoxes.contains(where: { $0.contains(point) }) { covered += 1 }
            }
        }
        return total == 0 ? 0 : CGFloat(covered) / CGFloat(total)
    }

    /// 相邻墨块合并：照片常被一条亮带切成两块（实测教材页被切成 0.056 + 0.034 两块）。
    private static func merge(_ boxes: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for box in boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            if let index = merged.firstIndex(where: { $0.insetBy(dx: -0.02, dy: -0.02).intersects(box) }) {
                merged[index] = merged[index].union(box)
            } else {
                merged.append(box)
            }
        }
        return merged
    }
}
