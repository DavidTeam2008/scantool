import CoreGraphics
import Foundation

/// P0.1 出口边缘清理：页面框/表格安全门回退后，右上角偶尔仍会留下
/// 一条楔形页外背景（真机 round1-3 在右侧白边内侧，越靠上越宽）。
///
/// 这里一次性在缩略栅格上求右侧逐行边界、顶部逐列边界和右上角红色
/// 木纹区，再只对原图做一次位图遍历，把纸面边界外刷白。不裁切、
/// 不缩放，避免为了最后一条背景再次触发表格结构回归。
enum PageEdgeCleaner {
    /// 从右侧最多检查 6% 宽度；超过这个范围视为页面内容。
    static let maxRightStripRatio = 0.06
    /// 从顶部最多检查 12% 高度；超过这个范围视为页面内容。
    static let maxTopStripRatio = 0.12
    /// 白底画布的列亮度/饱和度下限。
    static let whiteFrameLumaThreshold = 0.965
    static let whiteFrameSaturationThreshold = 0.05
    /// 纸面（含浅色页边/浅蓝纸）的亮度/饱和度范围。
    static let pagePaperLumaThreshold = 0.80
    static let pagePaperSaturationThreshold = 0.28

    /// 返回清理后的图片；没有可清理的右侧/顶部背景时返回 nil。
    static func cleanedBackground(in image: CGImage) -> CGImage? {
        guard image.width >= 50, image.height >= 50,
              let analysis = Raster.downsample(image, longEdge: 360)
        else { return nil }

        let rightBoundaries = rightWhiteningBoundaries(in: analysis)
        let topBoundaries = topWhiteningBoundaries(in: analysis)
        guard rightBoundaries.contains(where: { $0 != nil })
                || topBoundaries.contains(where: { $0 != nil })
        else { return nil }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var changed = false

        // 顶部：逐列把纸面顶边以上刷白。
        for x in 0..<width {
            let analysisX = min(
                analysis.width - 1,
                Int(Double(x) / Double(width) * Double(analysis.width))
            )
            guard let boundary = topBoundaries[analysisX] else { continue }
            let fullY = min(
                height,
                max(0, Int(Double(boundary) * Double(height) / Double(analysis.height)))
            )
            guard fullY > 0 else { continue }
            changed = true
            for y in 0..<fullY {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
            }
        }

        // 右侧：逐行把纸面右边界外侧刷白。
        for y in 0..<height {
            let analysisY = min(
                analysis.height - 1,
                Int(Double(y) / Double(height) * Double(analysis.height))
            )
            guard let boundary = rightBoundaries[analysisY] else { continue }
            let fullX = min(
                width,
                max(0, Int(Double(boundary) * Double(width) / Double(analysis.width)))
            )
            guard fullX < width else { continue }
            changed = true
            for x in fullX..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
            }
        }

        // 右上角：书桌红色木纹/灰色页边可能在纸面边界之外，再做一次
        // 受限的颜色清理。红色文字/图片在页面内侧，黑色页码是低饱和
        // 黑色，不会命中红色条件。
        let rightStart = Int(Double(width) * 0.94)
        let topEnd = Int(Double(height) * 0.07)
        let topRightX = width - max(2, Int(Double(width) * 0.012))
        let topRightEnd = Int(Double(height) * 0.15)
        for y in 0..<height {
            let isTopEdge = y < topEnd
            let isTopRight = y < topRightEnd
            for x in 0..<width {
                guard isTopEdge || x >= rightStart else { continue }
                let offset = y * bytesPerRow + x * 4
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
                let luma = 0.299 * red + 0.587 * green + 0.114 * blue
                let redBackground = red > 0.18 && saturation > 0.20
                    && red > green + 0.06 && red > blue + 0.03
                let grayTopRight = isTopRight && x >= topRightX
                    && luma < 0.94 && saturation < 0.12
                guard redBackground || grayTopRight else { continue }
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
                changed = true
            }
        }

        guard changed, let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// 每行返回第一个应刷白的 x；nil 表示这一行不做处理。
    private static func rightWhiteningBoundaries(in raster: Raster) -> [Int?] {
        let width = raster.width
        let maxScan = max(4, Int(Double(width) * maxRightStripRatio))
        let minPageX = Int(Double(width) * 0.90)
        var result = [Int?](repeating: nil, count: raster.height)

        for y in 0..<raster.height {
            var x = width - 1
            var whiteFrame = 0
            while x >= width - maxScan {
                let pixel = raster.pixel(x: x, y: y)
                guard pixel.luminance >= whiteFrameLumaThreshold,
                      pixel.saturation <= whiteFrameSaturationThreshold
                else { break }
                whiteFrame += 1
                x -= 1
            }
            // 只处理带白底画布的出口；至少要有 1 列白边，否则不冒险
            // 清页面内容。顶部白边在缩略图上可能只占 1 列。
            guard whiteFrame >= 1 else { continue }

            var run = 0
            var pageRight: Int?
            while x >= width - maxScan {
                let pixel = raster.pixel(x: x, y: y)
                if pixel.luminance >= pagePaperLumaThreshold,
                   pixel.saturation <= pagePaperSaturationThreshold {
                    run += 1
                    if run >= 2 {
                        pageRight = x + 1
                        break
                    }
                } else {
                    run = 0
                }
                x -= 1
            }
            guard let pageRight, pageRight >= minPageX else { continue }
            let firstWhiten = pageRight + 1
            guard firstWhiten < width else { continue }
            result[y] = firstWhiten
        }
        return result
    }

    /// 每列返回第一个应刷白的 y（纸面顶边）；nil 表示这一列不处理。
    private static func topWhiteningBoundaries(in raster: Raster) -> [Int?] {
        let height = raster.height
        let maxScan = max(4, Int(Double(height) * maxTopStripRatio))
        var result = [Int?](repeating: nil, count: raster.width)
        for x in 0..<raster.width {
            var y = 0
            var whiteFrame = 0
            while y < maxScan {
                let pixel = raster.pixel(x: x, y: y)
                guard pixel.luminance >= whiteFrameLumaThreshold,
                      pixel.saturation <= whiteFrameSaturationThreshold
                else { break }
                whiteFrame += 1
                y += 1
            }
            guard whiteFrame >= 1 else { continue }

            var run = 0
            var pageTop: Int?
            var sawInk = false
            while y < maxScan {
                let pixel = raster.pixel(x: x, y: y)
                if pixel.luminance < 0.55, pixel.saturation < 0.30 {
                    // 顶部页码/文字是黑色中性像素；说明这一列已经进入
                    // 页面内容，不能把内容上方的纸面误当页外背景清掉。
                    sawInk = true
                    break
                }
                if pixel.luminance >= pagePaperLumaThreshold,
                   pixel.saturation <= pagePaperSaturationThreshold {
                    run += 1
                    if run >= 2 {
                        pageTop = y - 1
                        break
                    }
                } else {
                    run = 0
                }
                y += 1
            }
            guard !sawInk, let pageTop, pageTop > 0 else { continue }
            result[x] = pageTop
        }
        return result
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

        func pixel(x: Int, y: Int) -> Pixel {
            let offset = (y * width + x) * 4
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
    }
}
