import CoreGraphics
import Foundation

/// 书页拆分（spec/scan-enhance FR-002）：在「摊开的整书」四边形内找书脊
/// （中缝暗谷），把整书拆成左右页——真机日志证明摊开书场景候选池里**只有
/// 整书一个候选**（右页不是独立矩形），所以「只拍右页」只能靠拍后拆分。
///
/// ## 判据（在**透视矫正后的矩形图**上做，spec/scan-enhance D2 修订）
/// 1. 矫正图（调用方用与渲染同源的 `CIPerspectiveCorrection` 生成）把四边形
///    映射成矩形，列方向即页面的 u 方向——书脊是一条**贯穿页高的竖暗带**；
/// 2. 逐列（160 列、含 0.6% 级步长）取 y∈[0.1,0.9] 的均值，找最暗列；
///    谷深 = 两侧基准 − 谷均值 ≥ 0.06；
/// 3. **贯穿性校验**：谷列上 ≥70% 的采样行明显暗于基准（≥0.10）——印刷线/
///    表格竖线只占局部高度，不具备贯穿性。
///
/// 不再要求宽高比：场景 2 里书脊可能偏左（左页只露出一条），摊开宽高比
/// 判据会把这类情况漏掉；贯穿性 + 谷深已足以区分「书脊」与「印刷线」。
enum SpreadSplitter {
    /// 书脊搜索结果：`u` = 分割线在页面归一化宽度的位置（0..1）。
    struct Spine: Equatable, Sendable {
        let u: Double
        /// 谷深（两侧基准 − 谷均值），越大越可信。
        let prominence: Double
        /// 谷列中明显暗于基准的采样行占比（贯穿性）。
        let continuity: Double
    }

    /// 谷深阈值：低于它视为「没有书脊」。
    static let prominenceThreshold: Double = 0.06
    /// 贯穿性阈值（谷列暗行占比）。
    static let continuityThreshold: Double = 0.70
    /// 搜索区间（避开最外侧页边/印刷边框线；场景 2 的书脊可能接近左缘）。
    static let searchRange: ClosedRange<Double> = 0.12...0.88
    /// 谷宽下限（页宽占比）：书脊阴影带较宽（≥1.5%），印刷竖线/表格线
    /// 只有 1–2 个栅格列（≈0.6%）——这是区分「书脊」与「印刷线」的关键。
    static let minimumWidth: Double = 0.015

    /// 诊断结果（spec/scan-enhance 遥测）：拒绝原因与原始度量，
    /// 下一次真机日志可直接读出卡在哪一道闸。
    struct Diagnosis: Sendable, Equatable {
        var rectifiedWidth = 0
        var rectifiedHeight = 0
        var reason = ""
        var bestU = -1.0
        var prominence = 0.0
        var continuity = 0.0
        var valleyWidth = 0.0
    }

    struct Analysis: Sendable {
        let spine: Spine?
        let diagnosis: Diagnosis
    }

    /// 在**透视矫正后的矩形图**上找书脊；找不到返回 nil。
    static func spine(inRectified image: CGImage) -> Spine? {
        analyzeSpine(inRectified: image).spine
    }

    /// 带诊断的完整分析（遥测与本地排查共用）。
    static func analyzeSpine(inRectified image: CGImage) -> Analysis {
        var diagnosis = Diagnosis(rectifiedWidth: image.width, rectifiedHeight: image.height)
        // 分辨率闸：矫正图过小时（如低分辨率导入图/小裁剪区），一条 1px
        // 印刷线会被放大成「宽谷」——书脊判定不可靠，宁可不拆。
        guard image.width >= 200, image.height >= 200 else {
            diagnosis.reason = "resolution"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }
        guard let raster = Raster(image: image) else {
            diagnosis.reason = "raster"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }

        let rows = 32
        func columnMean(u: Double) -> Double {
            var total = 0.0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            return total / Double(rows)
        }
        func columnDarkFraction(u: Double, baseline: Double) -> Double {
            var dark = 0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                if raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v)) < baseline - 0.10 {
                    dark += 1
                }
            }
            return Double(dark) / Double(rows)
        }

        // 局部凹陷评分（spec/scan-enhance 真机修订）：书脊是「两侧亮、
        // 中间凹」的**局部**特征——全局最暗列会被页面里的深色插图带偏
        // （真机日志：全局最暗落在 u=0.72 的深色照片上，真实书脊被淹没）。
        // 每个候选列只看左右各 4% 邻域，取局部凹陷最深者。
        let columns = Int((searchRange.upperBound - searchRange.lowerBound) * 160)
        var bestU = searchRange.lowerBound
        var bestMean = 0.0
        var bestProminence = -Double.infinity
        for column in 0..<columns {
            let u = searchRange.lowerBound
                + (searchRange.upperBound - searchRange.lowerBound)
                * (Double(column) + 0.5) / Double(columns)
            let mean = columnMean(u: u)
            let left = columnMean(u: max(u - 0.04, 0.01))
            let right = columnMean(u: min(u + 0.04, 0.99))
            let localProminence = min(left, right) - mean
            if localProminence > bestProminence {
                bestProminence = localProminence
                bestU = u
                bestMean = mean
            }
        }
        let leftMean = columnMean(u: max(bestU - 0.04, 0.01))
        let rightMean = columnMean(u: min(bestU + 0.04, 0.99))
        let baseline = (leftMean + rightMean) / 2
        let prominence = bestProminence
        diagnosis.bestU = bestU
        diagnosis.prominence = prominence
        guard prominence >= prominenceThreshold else {
            diagnosis.reason = "prominence"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }
        // V 形校验（局部凹陷评分已隐含两侧更亮；保留显式检查以覆盖边界列）。
        let bothSidesBrighter = min(leftMean, rightMean) - bestMean >= prominenceThreshold
        guard bothSidesBrighter else {
            diagnosis.reason = "vShape"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }
        let continuity = columnDarkFraction(u: bestU, baseline: baseline)
        diagnosis.continuity = continuity
        guard continuity >= continuityThreshold else {
            diagnosis.reason = "continuity"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }
        // 宽度校验：谷的连续暗列宽度必须 ≥ minimumWidth（印刷细线只有
        // 1–2 个栅格列，书脊阴影带更宽）。
        let halfDepth = baseline - 0.5 * prominence
        let step = 0.006
        var width = step
        var u = bestU - step
        while u > 0.01, columnMean(u: u) < halfDepth {
            width += step
            u -= step
        }
        u = bestU + step
        while u < 0.99, columnMean(u: u) < halfDepth {
            width += step
            u += step
        }
        diagnosis.valleyWidth = width
        guard width >= minimumWidth else {
            diagnosis.reason = "width"
            return Analysis(spine: nil, diagnosis: diagnosis)
        }
        return Analysis(
            spine: Spine(u: bestU, prominence: prominence, continuity: continuity),
            diagnosis: diagnosis
        )
    }

    /// 左侧折痕暗条裁切结果（spec/scan-enhance FR-002 场景 2）：
    /// `u` = 右页左缘（从左侧第一个持续明亮列）；`stripDepth` = 暗条暗度。
    struct FoldTrim: Equatable, Sendable {
        let u: Double
        let stripDepth: Double
        let interior: Double
    }

    /// 裁掉左侧折起暗条：折页书的折起部分在画面左侧是一条**暗带**
    /// （背面/阴影），右页是持续明亮区——从左侧找第一个持续明亮的列作为
    /// 右页左缘。与暗谷（书脊）模型互补：亮左页的摊开书走暗谷，暗折条走本模型。
    static func leftFoldTrim(inRectified image: CGImage) -> FoldTrim? {
        guard image.width >= 200, image.height >= 200,
              let raster = Raster(image: image)
        else { return nil }
        let rows = 32
        func mean(_ u: Double) -> Double {
            var total = 0.0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            return total / Double(rows)
        }
        // 页面内部亮度：中位数（对页面内的深色插图鲁棒）。
        var interiorSamples: [Double] = []
        var u = 0.30
        while u <= 0.90 {
            interiorSamples.append(mean(u))
            u += 0.01
        }
        guard !interiorSamples.isEmpty else { return nil }
        let interior = interiorSamples.sorted()[interiorSamples.count / 2]
        let brightThreshold = interior - 0.12
        // 第一个「持续明亮」的列（连续 4 个 1% 采样都亮）。
        var cut: Double?
        u = 0.02
        while u <= 0.40 {
            if mean(u) >= brightThreshold,
               mean(u + 0.01) >= brightThreshold,
               mean(u + 0.02) >= brightThreshold,
               mean(u + 0.03) >= brightThreshold {
                cut = u
                break
            }
            u += 0.005
        }
        guard let cut, cut >= 0.03, cut <= 0.35 else { return nil }
        // 暗条宽度与暗度：太窄（只是裁切边的背景余量）不算折痕。
        let stripWidth = cut - 0.02
        guard stripWidth >= 0.04 else { return nil }
        var stripTotal = 0.0
        var stripCount = 0
        u = 0.02
        while u <= cut - 0.01 {
            stripTotal += mean(u)
            stripCount += 1
            u += 0.005
        }
        guard stripCount > 0 else { return nil }
        let stripMean = stripTotal / Double(stripCount)
        let depth = interior - stripMean
        guard depth >= 0.15 else { return nil }
        return FoldTrim(u: cut, stripDepth: depth, interior: interior)
    }

    /// 列亮度剖面（诊断用）：u ∈ [from, to] 的逐列均值，供本地排查真实照片。
    static func columnProfile(
        inRectified image: CGImage, from: Double = 0.02, to: Double = 0.98, step: Double = 0.02
    ) -> [(u: Double, mean: Double)] {
        guard let raster = Raster(image: image) else { return [] }
        var profile: [(Double, Double)] = []
        var u = from
        while u <= to {
            var total = 0.0
            let rows = 32
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            profile.append((u, total / Double(rows)))
            u += step
        }
        return profile.map { (u: $0.0, mean: $0.1) }
    }

    /// 按书脊位置拆分四边形：左页 = TL→顶分割点→底分割点→BL；
    /// 右页 = 顶分割点→TR→BR→底分割点。
    static func split(_ quad: Quad, at u: Double) -> (left: Quad, right: Quad) {
        let t = min(max(u, 0), 1)
        let top = lerp(quad.topLeft, quad.topRight, t)
        let bottom = lerp(quad.bottomLeft, quad.bottomRight, t)
        let left = Quad(
            topLeft: quad.topLeft,
            topRight: top,
            bottomRight: bottom,
            bottomLeft: quad.bottomLeft
        )
        let right = Quad(
            topLeft: top,
            topRight: quad.topRight,
            bottomRight: quad.bottomRight,
            bottomLeft: bottom
        )
        return (left, right)
    }

    /// 四边形像素宽高比（宽/高，均值边）——诊断用（真机回填）。
    static func pixelAspect(of quad: Quad, imageSize: CGSize) -> Double {
        let widthPx = (distance(quad.topLeft, quad.topRight)
            + distance(quad.bottomLeft, quad.bottomRight)) / 2 * Double(imageSize.width)
        let heightPx = (distance(quad.topLeft, quad.bottomLeft)
            + distance(quad.topRight, quad.bottomRight)) / 2 * Double(imageSize.height)
        guard heightPx > 0 else { return 0 }
        return widthPx / heightPx
    }

    // MARK: - Helpers

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    /// 亮度栅格（160 列、y 翻转、双线性采样）。
    private struct Raster {
        let columns: Int
        let rows: Int
        let luminance: [Double]

        init?(image: CGImage) {
            let columns = 160
            let rows = max(2, Int((CGFloat(columns) * CGFloat(image.height) / CGFloat(image.width)).rounded()))
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
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
                return true
            }
            guard ok else { return nil }
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
            self.columns = columns
            self.rows = rows
            self.luminance = luminance
        }

        func luminanceBilinear(atNormalized point: CGPoint) -> Double {
            let fx = min(max(point.x * CGFloat(columns) - 0.5, 0), CGFloat(columns - 1))
            let fy = min(max(point.y * CGFloat(rows) - 0.5, 0), CGFloat(rows - 1))
            let x0 = Int(fx.rounded(.down))
            let y0 = Int(fy.rounded(.down))
            let x1 = min(x0 + 1, columns - 1)
            let y1 = min(y0 + 1, rows - 1)
            let tx = Double(fx - CGFloat(x0))
            let ty = Double(fy - CGFloat(y0))
            let top = luminance[y0 * columns + x0] * (1 - tx) + luminance[y0 * columns + x1] * tx
            let bottom = luminance[y1 * columns + x0] * (1 - tx) + luminance[y1 * columns + x1] * tx
            return top * (1 - ty) + bottom * ty
        }
    }
}
