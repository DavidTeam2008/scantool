import CoreGraphics
import Foundation

/// 纸张 mask：按“浅色 + 低饱和”分割纸面，取最大连通域的外接框。
///
/// 用于 `IMG_7542` 这类木桌/折页背景：Vision 矩形容易被整幅照片吸走，
/// 文档分割又会落到文字/表格子框；纸张 mask 提供第三个、与语义无关的
/// 页面范围证据。只做候选，不直接决定裁切。
enum PaperMaskDetector {
    struct Result: Equatable, Sendable {
        /// Vision 归一化（原点左下）。
        var rect: CGRect
        var coverage: Double
    }

    static func detect(in image: CGImage, maxDimension: CGFloat = 320) -> Result? {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let count = width * height
        var mask = [Bool](repeating: false, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255
                let g = Double(pixels[i + 1]) / 255
                let b = Double(pixels[i + 2]) / 255
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                // 木桌暗/高饱和；纸面浅灰低饱和。折页漫画可能有白色，但连通域
                // 会与纸面相连，最终由文字包围盒/表格安全门裁剪。
                mask[y * width + x] = luminance > 0.55 && saturation < 0.35
            }
        }

        var visited = [Bool](repeating: false, count: count)
        var bestCells = 0
        var bestBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for start in 0..<count where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var cells = 0
            var minX = width, minY = height, maxX = 0, maxY = 0
            while let current = stack.popLast() {
                let x = current % width
                let y = current / width
                cells += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if mask[next], !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            if cells > bestCells {
                bestCells = cells
                bestBox = (minX, minY, maxX, maxY)
            }
        }
        guard let bestBox else { return nil }
        let coverage = Double(bestCells) / Double(count)
        guard coverage >= 0.10 else { return nil }
        let rect = CGRect(
            x: CGFloat(bestBox.minX) / CGFloat(width),
            y: 1 - CGFloat(bestBox.maxY + 1) / CGFloat(height),
            width: CGFloat(bestBox.maxX - bestBox.minX + 1) / CGFloat(width),
            height: CGFloat(bestBox.maxY - bestBox.minY + 1) / CGFloat(height)
        )
        return Result(rect: rect, coverage: coverage)
    }
}
