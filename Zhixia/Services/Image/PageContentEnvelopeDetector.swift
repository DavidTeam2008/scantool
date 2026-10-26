import CoreGraphics
import Foundation

/// P0.1 纸张/内容包络检测（page-preprocess P0.1 / PP-T051）。
///
/// 只做**几何候选**，不改像素、不跑 OCR/结构识别；调用方仍要过文字/表格
/// 安全门。目标是在单次链路里回答两个问题：
///
/// 1. 画面四边有没有明显的页外背景（纸面投影/桌面/书脊）？
/// 2. 页内真正有内容的包围盒在哪里（文字/表格/照片/页码/装饰）？
///
/// 复用的判据（都在缩略栅格上，避免全分辨率扫描）：
/// - 纸张底：取页面中心区域的中位亮度，低饱和、接近纸面的像素为纸；
/// - 页边：逐行/列统计纸面像素占比，从四边向内找连续纸面起点；
/// - 内容：纸面范围内明显偏暗或高饱和的像素，取行列内容占比的包络；
/// - 背景残留：候选框外侧仍被判为纸面的比例，用于决定是否需要 refine。
///
/// 这是**保守候选**：没有清晰页边时返回 nil，调用方保留原提议框。
enum PageContentEnvelopeDetector {
    struct Candidate: Equatable, Sendable {
        /// 纸面边界（归一化，左上原点）。
        var paperRect: CGRect
        /// 纸内强内容包络；可能为 nil（空白页/几乎无墨）。
        var contentRect: CGRect?
        /// 最终候选：内容包络外扩安全边；无内容时退回纸面边界。
        var rect: CGRect
        /// 候选框外侧仍像纸面的像素比例（0..1）。
        var backgroundResidual: Double
        /// 纸面中心中位亮度，供报告/调参。
        var paperLuminance: Double
        /// 纸面边界是否真的从画面边缘向内收缩。
        var trimmedPaperEdges: Set<Edge>
    }

    enum Edge: String, Sendable, CaseIterable {
        case top, left, bottom, right
    }

    /// 缩略图长边。320~480 足够看页边，耗时远低于全图。
    static let analysisLongEdge = 360
    /// 内容/纸面边界的占比阈值。
    static let paperColumnThreshold = 0.45
    static let contentColumnThreshold = 0.002
    /// 内容包络外扩（归一化）。
    static let contentMargin = 0.004
    /// 纸面边界外扩（归一化），避免把页边空白当内容裁掉。
    static let paperMargin = 0.002

    static func detect(in image: CGImage) -> Candidate? {
        guard image.width >= 80, image.height >= 80 else { return nil }
        guard let raster = Raster.downsample(image, longEdge: analysisLongEdge) else {
            return nil
        }
        // 已经带均匀白底画布的输入（例如本管线自己上一次的输出）不再裁切，
        // 否则白边会被当成纸面重新包络，导致每次保存尺寸继续漂移。
        if raster.hasUniformWhiteFrame() {
            return nil
        }

        let paperLuminance = raster.centralMedianLuminance()
        // 中心区域可能被深色表格/照片占据；用较低下限兜底，避免整页被判纸。
        let paperThreshold = max(0.30, paperLuminance - 0.26)
        let paperSaturation = 0.42

        var paper = [Bool](repeating: false, count: raster.width * raster.height)
        for index in 0..<(raster.width * raster.height) {
            let pixel = raster.pixel(at: index)
            paper[index] = pixel.luminance >= paperThreshold
                && pixel.saturation <= paperSaturation
        }

        let rowPaper: [Double] = (0..<raster.height).map { y in
            Double((0..<raster.width).reduce(0) { $0 + (paper[y * raster.width + $1] ? 1 : 0) })
                / Double(max(1, raster.width))
        }
        let columnPaper: [Double] = (0..<raster.width).map { x in
            Double((0..<raster.height).reduce(0) { $0 + (paper[$1 * raster.width + x] ? 1 : 0) })
                / Double(max(1, raster.height))
        }

        guard let top = firstRun(rowPaper, threshold: paperColumnThreshold, fromStart: true),
              let bottom = firstRun(rowPaper, threshold: paperColumnThreshold, fromStart: false),
              let left = firstRun(columnPaper, threshold: paperColumnThreshold, fromStart: true),
              let right = firstRun(columnPaper, threshold: paperColumnThreshold, fromStart: false),
              bottom > top, right > left
        else {
            return nil
        }

        let paperRect = CGRect(
            x: CGFloat(left) / CGFloat(raster.width),
            y: CGFloat(top) / CGFloat(raster.height),
            width: CGFloat(right - left + 1) / CGFloat(raster.width),
            height: CGFloat(bottom - top + 1) / CGFloat(raster.height)
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard paperRect.width >= 0.45, paperRect.height >= 0.45,
              paperRect.width * paperRect.height >= 0.30
        else { return nil }

        // 强内容：暗于纸面中位亮度一定幅度，或明显高饱和。只用于包络，
        // 不用于“擦除”；show-through/浅灰底不会被当成强内容。
        let darkThreshold = paperLuminance - 0.17
        var contentMinX = Int.max
        var contentMinY = Int.max
        var contentMaxX = -1
        var contentMaxY = -1
        for y in top...bottom {
            for x in left...right {
                let index = y * raster.width + x
                let pixel = raster.pixel(at: index)
                guard pixel.luminance < darkThreshold || pixel.saturation > 0.52 else {
                    continue
                }
                contentMinX = min(contentMinX, x)
                contentMaxX = max(contentMaxX, x)
                contentMinY = min(contentMinY, y)
                contentMaxY = max(contentMaxY, y)
            }
        }

        let contentRect: CGRect? = {
            guard contentMaxX >= contentMinX, contentMaxY >= contentMinY else { return nil }
            let rect = CGRect(
                x: CGFloat(contentMinX) / CGFloat(raster.width),
                y: CGFloat(contentMinY) / CGFloat(raster.height),
                width: CGFloat(contentMaxX - contentMinX + 1) / CGFloat(raster.width),
                height: CGFloat(contentMaxY - contentMinY + 1) / CGFloat(raster.height)
            )
            // 只有内容包络确实比纸面小、且不至于小到只剩一小块时才采用；
            // 单行页码/单个黑白图块不足以代表整页。
            guard rect.width >= 0.30, rect.height >= 0.30,
                  rect.width * rect.height >= 0.12,
                  paperRect.insetBy(dx: -0.002, dy: -0.002).contains(rect)
            else { return nil }
            return rect
        }()

        let base = contentRect ?? paperRect
        let margin: CGFloat = contentRect == nil ? paperMargin : contentMargin
        let candidate = base.insetBy(dx: -margin, dy: -margin)
            .intersection(paperRect.insetBy(dx: -paperMargin, dy: -paperMargin))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard candidate.width >= 0.30, candidate.height >= 0.30,
              candidate.width * candidate.height >= 0.12
        else { return nil }

        // 背景残留：候选外侧、仍落在纸面矩形内的纸面像素比例。
        let residual = backgroundResidual(
            outside: candidate,
            paper: paper,
            paperRect: paperRect,
            width: raster.width,
            height: raster.height
        )

        let trimmed: Set<Edge> = {
            var result: Set<Edge> = []
            if paperRect.minY > 0.01 { result.insert(.top) }
            if paperRect.minX > 0.01 { result.insert(.left) }
            if paperRect.maxY < 0.99 { result.insert(.bottom) }
            if paperRect.maxX < 0.99 { result.insert(.right) }
            return result
        }()

        return Candidate(
            paperRect: paperRect,
            contentRect: contentRect,
            rect: candidate,
            backgroundResidual: residual,
            paperLuminance: paperLuminance,
            trimmedPaperEdges: trimmed
        )
    }

    /// 从数组一端找连续 `run` 个样本 ≥ 阈值的第一段；返回该段起点。
    /// 只搜索外侧 35%，避免页面内部的大片纸面被误当页边。
    private static func firstRun(
        _ values: [Double],
        threshold: Double,
        fromStart: Bool
    ) -> Int? {
        guard !values.isEmpty else { return nil }
        let limit = max(3, Int(Double(values.count) * 0.35))
        let indices = fromStart
            ? Array(0..<min(values.count, limit))
            : Array(stride(from: values.count - 1, through: max(0, values.count - limit), by: -1))
        var run = 0
        for index in indices {
            if values[index] >= threshold {
                run += 1
                if run >= 3 {
                    let first = fromStart ? index - 2 : index + 2
                    return min(max(first, 0), values.count - 1)
                }
            } else {
                run = 0
            }
        }
        return nil
    }

    private static func backgroundResidual(
        outside rect: CGRect,
        paper: [Bool],
        paperRect: CGRect,
        width: Int,
        height: Int
    ) -> Double {
        var total = 0
        var pageLike = 0
        for y in 0..<height {
            let v = (CGFloat(y) + 0.5) / CGFloat(height)
            for x in 0..<width {
                let u = (CGFloat(x) + 0.5) / CGFloat(width)
                guard paperRect.contains(CGPoint(x: u, y: v)),
                      !rect.contains(CGPoint(x: u, y: v))
                else { continue }
                total += 1
                if paper[y * width + x] { pageLike += 1 }
            }
        }
        guard total > 0 else { return 0 }
        return Double(pageLike) / Double(total)
    }

    private struct Pixel {
        var luminance: Double
        var saturation: Double
    }

    private struct Raster {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        static func downsample(_ image: CGImage, longEdge: Int) -> Raster? {
            let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            return Raster(width: width, height: height, bytes: bytes)
        }

        func pixel(at index: Int) -> Pixel {
            let offset = index * 4
            let red = Double(bytes[offset]) / 255
            let green = Double(bytes[offset + 1]) / 255
            let blue = Double(bytes[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            return Pixel(
                luminance: 0.299 * red + 0.587 * green + 0.114 * blue,
                saturation: maximum > 0 ? (maximum - minimum) / maximum : 0
            )
        }

        /// 四边是否都是近白/低饱和的均匀画布。用于幂等：带白边的输出再次
        /// 进入 renderPage 时不再重复裁切/加白边。
        func hasUniformWhiteFrame() -> Bool {
            let inset = max(1, min(width, height) / 100)
            func isWhite(_ x: Int, _ y: Int) -> Bool {
                let pixel = pixel(at: y * width + x)
                return pixel.luminance > 0.965 && pixel.saturation < 0.05
            }
            func rowIsWhite(_ y: Int) -> Bool {
                var white = 0
                for x in 0..<width where isWhite(x, y) { white += 1 }
                return Double(white) / Double(width) >= 0.95
            }
            func columnIsWhite(_ x: Int) -> Bool {
                var white = 0
                for y in 0..<height where isWhite(x, y) { white += 1 }
                return Double(white) / Double(height) >= 0.95
            }
            let top = (0..<inset).allSatisfy(rowIsWhite)
            let bottom = ((height - inset)..<height).allSatisfy(rowIsWhite)
            let left = (0..<inset).allSatisfy(columnIsWhite)
            let right = ((width - inset)..<width).allSatisfy(columnIsWhite)
            return top && bottom && left && right
        }

        func centralMedianLuminance() -> Double {
            let x0 = max(0, Int(Double(width) * 0.30))
            let x1 = min(width, Int(Double(width) * 0.70))
            let y0 = max(0, Int(Double(height) * 0.30))
            let y1 = min(height, Int(Double(height) * 0.70))
            var values: [Double] = []
            values.reserveCapacity(max(1, (x1 - x0) * (y1 - y0)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    values.append(pixel(at: y * width + x).luminance)
                }
            }
            guard !values.isEmpty else { return 0.78 }
            values.sort()
            return values[values.count / 2]
        }
    }
}
