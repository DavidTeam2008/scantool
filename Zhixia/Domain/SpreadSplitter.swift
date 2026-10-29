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
    /// 亮缝搜索范围：书脊/中缝在画面中部，排除每页内部的两栏间隙
    /// （视频 9：右页栏间距被误当成书脊，proposalU=0.759）。
    static let gutterSearchRange: ClosedRange<Double> = 0.30...0.70
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
        // 宽度上限：深色插图/照片可以很宽，书脊阴影带不会超过页宽的 20%。
        // 没有上限时，照片所在的宽暗区会被当成书脊（视频 9 的右页插图）。
        guard width <= 0.20 else {
            diagnosis.reason = "widthMax"
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

    /// 左侧**亮折页条**裁切：折页书左缘有时不是暗带，而是一条仍然很亮、
    /// 但印着漫画/插图的折起条（`IMG_7542`）。它与右页之间是一条窄白边，
    /// 亮度高于折条、暗像素比例接近 0。
    ///
    /// 判据（都在矫正图列均值/列暗像素比例上）：
    /// 1. 左条均亮 ≤ 页面内部中位数 − 0.04；
    /// 2. 右缘连续 4 个 0.5% 采样都接近纸面亮度；
    /// 3. 左条有足够暗像素（常规折条 ≥ 20% 采样列；真机窄折条放宽）；
    /// 4. 右缘亮列贯穿 ≥ 75% 采样行（排除局部亮块）；
    /// 5. 常规折条位置 [0.03, 0.20]、条宽 ≥ 3%；真机页级框残留的
    ///    0.5%~3% 窄折条单独走低阈值分支。
    ///
    /// 与 `leftFoldTrim`（暗折条）互补；只返回候选，调用方仍要过文字损失
    /// 与表格安全门。
    static func leftBrightFoldTrim(inRectified image: CGImage) -> FoldTrim? {
        guard image.width >= 200, image.height >= 200,
              let raster = Raster(image: image)
        else { return nil }
        let rows = 48
        func mean(_ u: Double) -> Double {
            var total = 0.0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            return total / Double(rows)
        }
        func darkFraction(_ u: Double, threshold: Double) -> Double {
            var dark = 0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                if raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v)) < threshold {
                    dark += 1
                }
            }
            return Double(dark) / Double(rows)
        }
        func brightFraction(_ u: Double, threshold: Double) -> Double {
            1 - darkFraction(u, threshold: threshold)
        }

        var interiorSamples: [Double] = []
        var u = 0.30
        while u <= 0.90 {
            interiorSamples.append(mean(u))
            u += 0.01
        }
        guard !interiorSamples.isEmpty else { return nil }
        let interior = interiorSamples.sorted()[interiorSamples.count / 2]
        let brightThreshold = interior - 0.05

        u = 0.005
        while u <= 0.20 {
            // 窄折条（真机边缘框已切掉大部分折页，只剩左缘 1%~2%）：
            // 从 0 起采样，并放宽“左条必须有墨”的要求，仍由调用方的
            // 文字损失门 + 表格安全门兜底。
            let narrow = u < 0.03
            let leftStart = narrow ? 0.0 : 0.02
            var leftTotal = 0.0
            var leftCount = 0
            var leftDark = 0
            var leftBright = 0
            var x = leftStart
            let leftEnd = max(leftStart, u - (narrow ? 0.002 : 0.01))
            while x <= leftEnd {
                let columnMean = mean(x)
                leftTotal += columnMean
                if columnMean >= 0.30 {
                    leftBright += 1
                }
                if darkFraction(x, threshold: interior - 0.18) >= 0.08 {
                    leftDark += 1
                }
                leftCount += 1
                x += 0.005
            }
            guard leftCount > 0 else { return nil }
            let leftMean = leftTotal / Double(leftCount)
            let leftInkColumns = Double(leftDark) / Double(leftCount)
            let leftBrightColumns = Double(leftBright) / Double(leftCount)
            // 切口左侧一列必须仍是折条，而不是已经进入亮页正文。
            let leftEdgeMean = mean(max(leftStart, u - (narrow ? 0.002 : 0.01)))

            // 右缘：连续采样必须都接近纸面亮度；单点亮块不算。
            // 窄折条场景页面内部中位数会被正文拉低，右缘要用更高的
            // “纸面亮”阈值，否则折条右缘那一列就会被误当成纸面。
            let rightThreshold = narrow ? min(interior + 0.01, 0.90) : brightThreshold
            let rightSamples = [u + 0.005, u + 0.010, u + 0.015, u + 0.025].map(mean)
            let rightMean = rightSamples.reduce(0, +) / Double(rightSamples.count)
            let rightContinuous = rightSamples.allSatisfy { $0 >= rightThreshold }
            let rightBright = brightFraction(u + 0.010, threshold: rightThreshold)


            if leftMean >= 0.30,
               leftBrightColumns >= 0.70,
               leftEdgeMean <= interior - (narrow ? 0.02 : 0.04),
               leftMean <= interior - 0.04,
               rightContinuous,
               rightMean >= leftMean + 0.05,
               narrow || leftInkColumns >= 0.20,
               rightBright >= 0.75,
               u >= 0.005,
               u - leftStart >= (narrow ? 0.005 : 0.03) {
                return FoldTrim(
                    u: u,
                    stripDepth: rightMean - leftMean,
                    interior: interior
                )
            }
            u += 0.005
        }
        return nil
    }

    /// 亮缝（gutter）分割结果：两个内容块之间的**亮空白带**中心。
    ///
    /// 与 `Spine`（暗谷）互补：真实摊开书的中缝不一定是阴影暗带——白色
    /// 内边距更常见，此时中缝在亮度上是**比两侧更亮的空白带**，`analyzeSpine`
    /// 的谷深判据会直接落空（视频 8 的左页场景：prominence≈0.02）。
    struct Gutter: Equatable, Sendable {
        /// 空白带中心（归一化 u，0 = 左缘，1 = 右缘）——作为书脊分割线。
        let u: Double
        /// 空白带半高宽（页宽占比）。
        let width: Double
        /// 亮缝左侧参考列（±6% 邻域）的平均亮度。
        let leftLuma: Double
        /// 亮缝右侧参考列（±6% 邻域）的平均亮度。
        let rightLuma: Double
        /// 亮缝对比度（带内亮度 − 两侧较亮者），越大越可信。
        let contrast: Double
        /// 置信度（0~1）：带宽 + 对比度 + 居中程度。
        let confidence: Double
    }

    /// 在**透视矫正后的矩形图**上找「亮缝」：页宽中部一条贯穿页高、
    /// 比左右内容块更亮的空白带。
    ///
    /// 为什么不用墨量（暗像素比例）：暗谷/墨量都要在**原始分辨率**上数细
    /// 文字，而 `Raster` 固定 160 列降采样会把细字与纸面平均掉；列**亮度
    /// 均值**在降采样下保持稳定，白纸内边距的特征也最直接。
    ///
    /// 判据：
    /// 1. 逐列取 y∈[0.12, 0.88] 的亮度均值；
    /// 2. 在 u∈[0.30, 0.70]（`gutterSearchRange`）内找「比左右各 6% 邻域
    ///    都亮」的局部峰；峰高（对比度）≥0.02；
    /// 3. 以半高宽估空白带宽度，要求 ≥2%（避免印刷竖线/反光细线）；
    /// 4. 置信度 = 0.40×带宽 + 0.45×对比度 + 0.15×居中；低于 0.5 的
    ///    结果仍返回，调用方按「提示/预选」处理。
    ///
    /// 只返回候选，不写 quad；左右页目标由调用方 `split(_:at:)` 生成。
    /// 单页两栏的栏间距也会形成亮缝——调用方必须用「拍的是包络还是目标页」
    /// 的角色（`PageDraft.quadRole`）把这条路径限制在包络/整摊上。
    static func analyzeGutter(inRectified image: CGImage) -> Gutter? {
        guard image.width >= 200, image.height >= 200,
              let raster = Raster(image: image)
        else { return nil }
        let columns = raster.columns
        let rows = 48
        func columnMean(_ column: Int) -> Double {
            let u = (Double(column) + 0.5) / Double(columns)
            var total = 0.0
            for row in 0..<rows {
                let v = 0.12 + 0.76 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            return total / Double(rows)
        }
        var means = [Double](repeating: 0, count: columns)
        for column in 0..<columns { means[column] = columnMean(column) }
        // 3 列平滑：单像素反光/噪点不应成为「局部峰」。
        var smooth = means
        for column in 0..<columns {
            let left = means[max(0, column - 1)]
            let right = means[min(columns - 1, column + 1)]
            smooth[column] = (left + means[column] + right) / 3
        }

        let searchStart = max(1, Int(gutterSearchRange.lowerBound * Double(columns)))
        let searchEnd = min(columns - 2, Int(gutterSearchRange.upperBound * Double(columns)))
        var bestColumn = searchStart
        var bestContrast = -Double.infinity
        for column in searchStart...searchEnd {
            let left = smooth[max(0, column - 10)]
            let right = smooth[min(columns - 1, column + 10)]
            let contrast = smooth[column] - max(left, right)
            if contrast > bestContrast {
                bestContrast = contrast
                bestColumn = column
            }
        }
        guard bestContrast >= 0.02 else { return nil }

        let left = smooth[max(0, bestColumn - 10)]
        let right = smooth[min(columns - 1, bestColumn + 10)]
        let halfHeight = (smooth[bestColumn] + max(left, right)) / 2
        var start = bestColumn
        var end = bestColumn
        while start > 0, smooth[start - 1] >= halfHeight { start -= 1 }
        while end < columns - 1, smooth[end + 1] >= halfHeight { end += 1 }
        let width = Double(end - start + 1) / Double(columns)
        guard width >= 0.02, width <= 0.25 else { return nil }

        let u = (Double(bestColumn) + 0.5) / Double(columns)
        let widthScore = min(1, max(0, (width - 0.02) / 0.05))
        let contrastScore = min(1, max(0, bestContrast / 0.08))
        let positionScore = min(1, max(0, 1 - abs(u - 0.5) / 0.30))
        let confidence = 0.40 * widthScore + 0.45 * contrastScore + 0.15 * positionScore
        return Gutter(
            u: u,
            width: width,
            leftLuma: left,
            rightLuma: right,
            contrast: bestContrast,
            confidence: confidence
        )
    }

    /// 右页纸面右缘（归一化 u）：从右往左找第一段「足够亮且暗像素少」的
    /// 连续纸面列。用于内容框右侧收边，避免把木桌/页边阴影带进 Word。
    static func rightPaperEdge(inRectified image: CGImage) -> Double? {
        guard image.width >= 200, image.height >= 200,
              let raster = Raster(image: image)
        else { return nil }
        let rows = 48
        func mean(_ u: Double) -> Double {
            var total = 0.0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                total += raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v))
            }
            return total / Double(rows)
        }
        func darkFraction(_ u: Double, threshold: Double) -> Double {
            var dark = 0
            for row in 0..<rows {
                let v = 0.10 + 0.80 * (Double(row) + 0.5) / Double(rows)
                if raster.luminanceBilinear(atNormalized: CGPoint(x: u, y: v)) < threshold {
                    dark += 1
                }
            }
            return Double(dark) / Double(rows)
        }
        var interiorSamples: [Double] = []
        var sampleU = 0.30
        while sampleU <= 0.90 {
            interiorSamples.append(mean(sampleU))
            sampleU += 0.01
        }
        guard !interiorSamples.isEmpty else { return nil }
        let interior = interiorSamples.sorted()[interiorSamples.count / 2]
        let threshold = interior - 0.12
        var u = 0.995
        while u >= 0.70 {
            let bright = mean(u) >= threshold && darkFraction(u, threshold: threshold) <= 0.20
            let next = mean(max(0.70, u - 0.005)) >= threshold
            if bright, next {
                return u
            }
            u -= 0.005
        }
        return nil
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
