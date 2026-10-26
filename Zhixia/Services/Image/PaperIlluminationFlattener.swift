import CoreImage
import Foundation

/// 页面预处理配方（与用户可选的 `EnhancementRecipe` 隔离）。
///
/// P0 的边界/裁切在 `renderPage` 里已经发生；本配方只负责 P1 的纸面光照
/// 压平。`ImagePipeline.apply(imageData:enhancement:)` 不经过这里，旧增强
/// 档和 Word 验收夹具的行为保持不变。
///
/// P1 默认开启；`renderPage` 必须拿到可靠表格保护信息才执行：
/// P0 表格安全门表框，或未裁切页的通用结构识别 guard（`.enhance` 预览 +
/// `VisionDocumentStructureRecognizer`）。guard 识别失败/空页时跳过并写
/// `table_guard_unavailable`，避免表格结构识别回归。
struct PagePreprocessRecipe: Sendable, Equatable {
    var flattensPaperIllumination: Bool
    var illuminationOptions: PaperIlluminationFlattener.Options

    init(
        flattensPaperIllumination: Bool = true,
        illuminationOptions: PaperIlluminationFlattener.Options = .init()
    ) {
        self.flattensPaperIllumination = flattensPaperIllumination
        self.illuminationOptions = illuminationOptions
    }

    static let paper = PagePreprocessRecipe()
    static let disabled = PagePreprocessRecipe(flattensPaperIllumination: false)
}

/// P1：估计纸面的大半径亮度背景场，把折痕/光照压平。
///
/// 设计约束：
/// - 只在页内**浅色低饱和纸面**上做增益；彩色/深色像素、照片/插图区域
///   的 mask=0，不做强增益。
/// - 背景场由低分辨率 tile 的 85 分位亮度估计，文字不会把背景拉黑；
///   tile 场再做约 10% 页宽的平滑，对应 plan D3 的 8%~12%。
/// - 只提亮不压暗（gain >= 1），避免把白纸压灰；最大增益有硬上限。
/// - 任何一步不可用（没有纸面、增益太小、降方差不足）都返回原图，并在
///   metrics 里写回退原因。
///
/// 这是确定性像素算法，不生成/改写文档内容；输出仍可逐像素与输入对齐。
struct PaperIlluminationFlattener: Sendable {
    struct Options: Codable, Equatable, Sendable {
        /// 分析图最长边；320 对折痕/光照已经足够，且 CPU 成本固定。
        var analysisMaxDimension = 320
        /// tile 宽度占页宽比例；配合 tile 平滑约等于 8%~12% 背景半径。
        var tileWidthRatio = 0.04
        /// 背景场平滑半径（tile 数）；1 表示约 ±4% 页宽。
        var tileSmoothingRadius = 1
        /// 纸面亮度增益硬上限，防止把深阴影/页外暗角拉爆。
        var maxGain = 1.50
        /// 小于该纸面覆盖率的图不处理（可能是整页照片/插图）。
        var minPaperCoverage = 0.25
        /// 折痕区亮度方差至少下降该比例；否则视为“没有可压平的光照”。
        var minVarianceReduction = 0.20
        /// 纸面像素判定：tile 的 85 分位亮度下限。
        var minPaperLuminance = 0.52
        /// 纸面像素判定：tile 的中位饱和度上限。
        var maxPaperSaturation = 0.22
        /// 目标纸白：取有效 tile 背景场的该分位，再夹到下方范围。
        var targetPercentile = 0.90
        var minTargetLuminance = 0.86
        var maxTargetLuminance = 0.95
        /// 绝对暗部保护上限；低于该亮度的墨迹/表格底色不参与增益。
        var darkProtectionEnd = 0.25
    }

    struct Metrics: Codable, Equatable, Sendable {
        var applied: Bool
        var fallbackReason: String?
        var paperCoverage: Double
        var targetLuminance: Double
        var gainP50: Double
        var gainMax: Double
        var varianceBefore: Double
        var varianceAfter: Double
        var elapsedMilliseconds: Int
    }

    struct Output {
        var image: CIImage
        var metrics: Metrics
    }

    /// gain map 的 R 通道存 `(gain - 1) / (maxGain - 1)`，用自定义 kernel
    /// 还原增益；RGBA8 无法直接存 >1 的 gain。
    private static let flattenKernel = CIColorKernel(source: """
    kernel vec4 zhixiaPaperFlatten(__sample pixel, __sample gainMap, float extraGain) {
        float gain = 1.0 + gainMap.r * extraGain;
        return vec4(clamp(pixel.rgb * gain, 0.0, 1.0), pixel.a);
    }
    """)

    func flatten(
        _ image: CIImage,
        context: CIContext,
        options: Options = .init(),
        protectedRects: [CGRect] = []
    ) -> Output? {
        let started = Date()
        let extent = image.extent.integral
        guard extent.width >= 16, extent.height >= 16 else { return nil }
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        guard let analysis = analyze(cgImage, options: options) else {
            return fallback(
                image: image,
                reason: "no_paper",
                options: options,
                started: started
            )
        }

        let target = min(
            options.maxTargetLuminance,
            max(
                options.minTargetLuminance,
                analysis.backgroundPercentile(options.targetPercentile)
            )
        )
        let tileGain = analysis.background.map { background in
            min(options.maxGain, max(1, target / max(background, 0.05)))
        }
        let gains = analysis.effectiveGains(tileGain: tileGain)
        let gainP50 = analysis.paperPercentile(of: gains, 0.50)
        let gainMax = analysis.paperMax(of: gains)
        let varianceBefore = analysis.backgroundVarianceBefore
        let varianceAfter = analysis.backgroundVariance(after: tileGain)
        let reduction = varianceBefore > 1e-6
            ? max(0, 1 - varianceAfter / varianceBefore)
            : 0

        func metrics(applied: Bool, reason: String?) -> Metrics {
            Metrics(
                applied: applied,
                fallbackReason: reason,
                paperCoverage: analysis.paperCoverage,
                targetLuminance: target,
                gainP50: gainP50,
                gainMax: gainMax,
                varianceBefore: varianceBefore,
                varianceAfter: varianceAfter,
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        }

        guard analysis.paperCoverage >= options.minPaperCoverage else {
            return Output(image: image, metrics: metrics(applied: false, reason: "no_paper"))
        }
        guard gainP50 > 1.01 else {
            return Output(image: image, metrics: metrics(applied: false, reason: "low_gain"))
        }
        guard varianceBefore <= 1e-6 || reduction >= options.minVarianceReduction else {
            return Output(
                image: image,
                metrics: metrics(applied: false, reason: "low_variance_reduction")
            )
        }
        guard let gainMap = gainMapImage(
            gains: gains,
            width: analysis.width,
            height: analysis.height,
            maxGain: options.maxGain
        ), let kernel = Self.flattenKernel else {
            return Output(image: image, metrics: metrics(applied: false, reason: "kernel_unavailable"))
        }

        let scaleX = extent.width / CGFloat(analysis.width)
        let scaleY = extent.height / CGFloat(analysis.height)
        var gainCIImage = CIImage(cgImage: gainMap)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)
        if !protectedRects.isEmpty {
            gainCIImage = protect(
                gainMap: gainCIImage,
                extent: extent,
                normalizedRects: protectedRects
            )
        }
        guard let flattened = kernel.apply(
            extent: extent,
            arguments: [
                image,
                gainCIImage,
                NSNumber(value: options.maxGain - 1),
            ]
        ) else {
            return Output(image: image, metrics: metrics(applied: false, reason: "kernel_failed"))
        }

        return Output(
            image: flattened.cropped(to: extent),
            metrics: metrics(applied: true, reason: nil)
        )
    }

    private func fallback(
        image: CIImage,
        reason: String,
        options _: Options,
        started: Date
    ) -> Output {
        Output(
            image: image,
            metrics: Metrics(
                applied: false,
                fallbackReason: reason,
                paperCoverage: 0,
                targetLuminance: 0,
                gainP50: 1,
                gainMax: 1,
                varianceBefore: 0,
                varianceAfter: 0,
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        )
    }

    /// 表格等结构区域禁止增益。`normalizedRects` 使用 Vision 归一化坐标
    /// （原点左下），与 CIImage extent 同系；外扩 1.5% 页宽/页高覆盖表格边框。
    /// 只改 gain map，不碰原像素；保护区最终等于输入（再走增强档）。
    private func protect(
        gainMap: CIImage,
        extent: CGRect,
        normalizedRects: [CGRect]
    ) -> CIImage {
        let marginX = extent.width * 0.015
        let marginY = extent.height * 0.015
        var mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        for normalized in normalizedRects {
            let rect = CGRect(
                x: extent.minX + normalized.minX * extent.width,
                y: extent.minY + normalized.minY * extent.height,
                width: normalized.width * extent.width,
                height: normalized.height * extent.height
            )
            .insetBy(dx: -marginX, dy: -marginY)
            .intersection(extent)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
            mask = black.composited(over: mask)
        }
        return gainMap
            .applyingFilter(
                "CIMultiplyCompositing",
                parameters: [kCIInputBackgroundImageKey: mask]
            )
            .cropped(to: extent)
    }

    private func gainMapImage(
        gains: [Double],
        width: Int,
        height: Int,
        maxGain: Double
    ) -> CGImage? {
        guard maxGain > 1, width > 0, height > 0 else { return nil }
        let scale = maxGain - 1
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let encoded = min(1, max(0, (gains[index] - 1) / scale))
            let value = UInt8((encoded * 255).rounded())
            let offset = index * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
            bytes[offset + 3] = 255
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - 低分辨率分析

    private struct Analysis {
        var width: Int
        var height: Int
        var paperCoverage: Double
        var background: [Double]
        var gainWeights: [Double]
        var luma: [Double]
        var tile: Int
        var validTiles: [Bool]

        var backgroundVarianceBefore: Double {
            variance(
                background.indices.compactMap { validTiles[$0] ? background[$0] : nil }
            )
        }

        func backgroundVariance(after gains: [Double]) -> Double {
            var values: [Double] = []
            values.reserveCapacity(validTiles.count)
            for index in background.indices where validTiles[index] {
                values.append(min(1, background[index] * gains[index]))
            }
            return variance(values)
        }

        private var validBackground: [Double] {
            zip(background, validTiles).compactMap { $1 ? $0 : nil }
        }

        func paperPercentile(of gains: [Double], _ fraction: Double) -> Double {
            percentile(paperIndices().map { gains[$0] }, fraction)
        }

        func paperMax(of gains: [Double]) -> Double {
            paperIndices().map { gains[$0] }.max() ?? 1
        }

        private func paperIndices() -> [Int] {
            var indices: [Int] = []
            indices.reserveCapacity(luma.count / 2)
            for index in luma.indices where gainWeights[index] > 0.5 && luma[index] > 0.20 {
                indices.append(index)
            }
            return indices
        }

        func backgroundPercentile(_ p: Double) -> Double {
            percentile(validBackground, p)
        }

        func effectiveGains(tileGain: [Double]) -> [Double] {
            var result = [Double](repeating: 1, count: width * height)
            let columns = (width + tile - 1) / tile
            let rows = (height + tile - 1) / tile
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let base = PaperIlluminationFlattener.bilinear(
                        tileGain,
                        columns: columns,
                        rows: rows,
                        x: x,
                        y: y,
                        tile: tile
                    )
                    result[index] = 1 + (base - 1) * gainWeights[index]
                }
            }
            return result
        }
    }

    private func analyze(_ cgImage: CGImage, options: Options) -> Analysis? {
        let maxDimension = max(16, options.analysisMaxDimension)
        let scale = min(
            1,
            Double(maxDimension) / Double(max(cgImage.width, cgImage.height))
        )
        let width = max(8, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(8, Int((Double(cgImage.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var saturation = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            luma[index] = 0.299 * r + 0.587 * g + 0.114 * b
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            saturation[index] = maxC > 0 ? (maxC - minC) / maxC : 0
        }

        let tile = max(4, Int((Double(width) * options.tileWidthRatio).rounded()))
        let columns = (width + tile - 1) / tile
        let rows = (height + tile - 1) / tile
        guard columns > 0, rows > 0 else { return nil }

        var tileLuma = [Double](repeating: 0, count: columns * rows)
        var tileSaturation = [Double](repeating: 0, count: columns * rows)
        var valid = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * tile
                let y0 = row * tile
                let x1 = min(width, x0 + tile)
                let y1 = min(height, y0 + tile)
                var lumas: [Double] = []
                var sats: [Double] = []
                lumas.reserveCapacity((x1 - x0) * (y1 - y0))
                sats.reserveCapacity(lumas.capacity)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let index = y * width + x
                        lumas.append(luma[index])
                        sats.append(saturation[index])
                    }
                }
                let index = row * columns + column
                tileLuma[index] = percentile(lumas, 0.85)
                tileSaturation[index] = median(sats)
                valid[index] = tileLuma[index] >= options.minPaperLuminance
                    && tileSaturation[index] <= options.maxPaperSaturation
            }
        }

        let validCount = valid.filter { $0 }.count
        guard validCount > 0 else { return nil }

        // 背景场只在有效纸面 tile 上平滑；无效 tile 先填全局中位数，避免照片
        // 区域把邻近纸面的亮度拉低。
        let globalBackground = percentile(
            zip(tileLuma, valid).compactMap { $1 ? $0 : nil },
            0.50
        )
        let background = smooth(
            values: tileLuma,
            valid: valid,
            columns: columns,
            rows: rows,
            radius: min(options.tileSmoothingRadius, 2),
            fallback: globalBackground
        )
        let tileMask = smooth(
            values: valid.map { $0 ? 1 : 0 },
            valid: valid,
            columns: columns,
            rows: rows,
            radius: min(options.tileSmoothingRadius, 2),
            fallback: 0
        )

        var gainWeights = [Double](repeating: 0, count: width * height)
        var covered = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let mask = Self.bilinear(tileMask, columns: columns, rows: rows, x: x, y: y, tile: tile)
                let saturationMask = 1 - smoothstep(0.12, 0.30, saturation[index])
                let darkProtection = smoothstep(0.08, options.darkProtectionEnd, luma[index])
                let weight = min(1, max(0, mask * saturationMask * darkProtection))
                gainWeights[index] = weight
                if weight > 0.5 { covered += 1 }
            }
        }
        let coverage = Double(covered) / Double(width * height)
        return Analysis(
            width: width,
            height: height,
            paperCoverage: coverage,
            background: background,
            gainWeights: gainWeights,
            luma: luma,
            tile: tile,
            validTiles: valid
        )
    }

    private func smooth(
        values: [Double],
        valid: [Bool],
        columns: Int,
        rows: Int,
        radius: Int,
        fallback: Double
    ) -> [Double] {
        var result = [Double](repeating: fallback, count: columns * rows)
        let sigma = Double(max(1, radius))
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0.0
                var weight = 0.0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let x = column + dx
                        let y = row + dy
                        guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                        let index = y * columns + x
                        guard valid[index] else { continue }
                        let spatial = exp(-Double(dx * dx + dy * dy) / (2 * sigma * sigma))
                        sum += values[index] * spatial
                        weight += spatial
                    }
                }
                if weight > 0 {
                    result[row * columns + column] = sum / weight
                }
            }
        }
        return result
    }

    private static func bilinear(
        _ values: [Double],
        columns: Int,
        rows: Int,
        x: Int,
        y: Int,
        tile: Int
    ) -> Double {
        let fx = (Double(x) + 0.5) / Double(tile) - 0.5
        let fy = (Double(y) + 0.5) / Double(tile) - 0.5
        let x0 = min(columns - 1, max(0, Int(floor(fx))))
        let y0 = min(rows - 1, max(0, Int(floor(fy))))
        let x1 = min(columns - 1, x0 + 1)
        let y1 = min(rows - 1, y0 + 1)
        let tx = min(1, max(0, fx - Double(x0)))
        let ty = min(1, max(0, fy - Double(y0)))
        let top = values[y0 * columns + x0] * (1 - tx) + values[y0 * columns + x1] * tx
        let bottom = values[y1 * columns + x0] * (1 - tx) + values[y1 * columns + x1] * tx
        return top * (1 - ty) + bottom * ty
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = min(1, max(0, fraction))
    let index = Int((Double(sorted.count - 1) * clamped).rounded())
    return sorted[index]
}

private func median(_ values: [Double]) -> Double {
    percentile(values, 0.5)
}

private func variance(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
}

private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
    let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

private func elapsedMilliseconds(since start: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(start) * 1000))
}
