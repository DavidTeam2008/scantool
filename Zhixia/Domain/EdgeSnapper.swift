import CoreGraphics
import Foundation

/// still 检出框的贴边吸附（plan D7，FR-014）——纯函数、无外部状态，
/// 读像素循 `InkFigureDetector` 先例（CGContext 栅格化 + 亮度采样）。
///
/// ## 为什么需要吸附
/// Vision 的文档检出框普遍**内缩 1~3%**：圆角被当成边界的一部分、低对比度
/// 边缘让置信度提前收敛，成片四边各裁掉一圈（spec US6 核心痛点）。
///
/// ## 做法
/// 对四边各沿**外法线**以小步长采样亮度剖面，找到「亮 → 暗」梯度最强的位置，
/// 把该边外推到那里（文档亮、桌面暗的真实边缘）；四个顶点 = 两条相邻边的
/// 外推位移之和。任何一项校验失败都**原样返回**输入 quad——宁可不修，不可错修。
///
/// ## 最近峰策略（spec/frame-stability；取代「双向两阶段」的相序）
/// 逐边独立：先测 s=0 的对称梯度 G0——检出边已压在真实边缘上则不动；否则
/// 向外、向内各找**第一处**过阈值的「亮→暗」边并取该边的峰位，两相中
/// **离检出位置最近**者胜出。
/// - 折页书左缘：从页内向外的第一个边是**折痕**（折脊轮廓在更外侧且往往
///   更强）——「全窗最强梯度」会跳过折痕、把折起来的部分留在框里；「第一个
///   边」稳定命中折痕。三条外缘不受影响（第一个峰就是纸边）。
/// - 内缩检出：向外第一个边 = 真实页边；越界检出：向内第一个边 = 真实页边。
/// 内向相仍比外向保守：限幅减半（0.5×maxShift）、阈值 1.5×——内拉收缩裁切
/// 范围，误吸文字笔画的代价是直接裁掉内容；沿边 5 点均值模糊孤立笔画。
enum EdgeSnapper {
    /// 单边吸附诊断（spec/frame-truth FR-008）——纯数据出参，由调用方决定是否
    /// 落日志（Domain 保持无 Services 依赖）。
    struct EdgeDiagnostic: Sendable, Equatable {
        /// 边序号：0=上 1=右 2=下 3=左。
        let edge: Int
        /// 边当前位置（s=0）的对称梯度（双线性采样）。
        let g0: Double
        /// 外向相最强正梯度（无峰 = 0）。
        let outward: Double
        /// 内向相最强正梯度（无峰 = 0）。
        let inward: Double
        /// 实际位移（归一化距离；外向为正、内向为负、不动为 0）。
        let shift: Double
    }

    // MARK: - 不可变配置

    /// 栅格列数：约 0.5% 级采样分辨率，足以把 1~3% 的内缩恢复到误差 ≤ 短边 2%。
    static let gridWidth = 160
    /// 触发吸附的最小梯度（亮度下降幅度，0~1）：低于它视为「没有真实边缘」。
    static let gradientThreshold = 0.08
    /// 面积变化上限（相对原 quad）：挡住小框吸到背景上大块伪边缘的病态外扩。
    static let maxAreaChange = 0.20
    /// 每条边上的采样点数（均匀分布，避开角点）。
    static let edgeSampleCount = 5
    /// 外法线搜索步数（步长 = maxShift / 步数）。
    static let shiftStepCount = 12
    /// 内向相触发阈值（FR-006）：1.5× gradientThreshold——内拉收缩裁切
    /// 范围，误吸文字笔画 = 直接裁掉内容，必须比外推更保守。
    static let inwardGradientThreshold = 0.12
    /// 内向相搜索限幅（相对 maxShift）：0.5× ≈ 短边 2.5%（maxShiftRatio
    /// 5% 时），页边距普遍远大于此——限幅内跨不过文字行。
    static let inwardShiftRatio = 0.5

    // MARK: - 单一入口

    /// 把 still 检出 `quad` 沿四边外法线吸附到 `image` 的真实亮度边缘。
    ///
    /// - `maxShiftRatio`：单边最大位移 = 比例 × quad 短边（任务带 3~5%）。
    /// - 四项校验（凸性 / 图像边界 / 最大位移 / 面积变化）任一失败 → 原样返回。
    /// - `image` 必须与 `quad` 同方向（直立）；调用方负责 EXIF 校正。
    /// - `diagnostics`：逐边诊断出参（默认 nil = 不采集；调用方接线日志）。
    static func snap(
        quad: Quad,
        image: CGImage,
        maxShiftRatio: Double,
        diagnostics: ((EdgeDiagnostic) -> Void)? = nil
    ) -> Quad {
        guard maxShiftRatio.isFinite, maxShiftRatio > 0,
              !quad.isDegenerate,
              isConvex(quad),
              image.width > 0, image.height > 0
        else { return quad }
        guard let raster = Raster(image: image) else { return quad }

        let bbox = quad.boundingRect
        let shortSide = min(bbox.width, bbox.height)
        let maxShift = maxShiftRatio * Double(shortSide)
        guard maxShift.isFinite, maxShift > 0 else { return quad }

        let centroid = CGPoint(
            x: (quad.topLeft.x + quad.topRight.x + quad.bottomRight.x + quad.bottomLeft.x) / 4,
            y: (quad.topLeft.y + quad.topRight.y + quad.bottomRight.y + quad.bottomLeft.y) / 4
        )
        // 边序：0=上(TL→TR) 1=右(TR→BR) 2=下(BR→BL) 3=左(BL→TL)。
        let edges = [
            (quad.topLeft, quad.topRight),
            (quad.topRight, quad.bottomRight),
            (quad.bottomRight, quad.bottomLeft),
            (quad.bottomLeft, quad.topLeft)
        ]
        let shifts = edges.enumerated().map { index, edge in
            edgeShift(
                from: edge.0,
                to: edge.1,
                centroid: centroid,
                maxShift: maxShift,
                edgeIndex: index,
                raster: raster,
                diagnostics: diagnostics
            )
        }

        // 顶点 = 两条相邻边的外推位移之和。
        let snapped = Quad(
            topLeft: shifted(quad.topLeft, by: shifts[3], shifts[0]),
            topRight: shifted(quad.topRight, by: shifts[0], shifts[1]),
            bottomRight: shifted(quad.bottomRight, by: shifts[1], shifts[2]),
            bottomLeft: shifted(quad.bottomLeft, by: shifts[2], shifts[3])
        )

        // 四项校验（plan D7）：任一失败原样返回。
        guard isConvex(snapped) else { return quad }
        guard isInBounds(snapped) else { return quad }
        let maxDisplacement = 1.5 * maxShift // 顶点最多承接两条边位移的矢量和（斜向 √2）
        let moved = max(
            distance(quad.topLeft, snapped.topLeft),
            max(
                distance(quad.topRight, snapped.topRight),
                max(
                    distance(quad.bottomRight, snapped.bottomRight),
                    distance(quad.bottomLeft, snapped.bottomLeft)
                )
            )
        )
        guard moved <= maxDisplacement else { return quad }
        let areaChange = abs(snapped.area - quad.area) / quad.area
        guard areaChange <= maxAreaChange else { return quad }
        return snapped
    }

    // MARK: - 边级搜索

    /// 单条边的吸附位移向量：外法线方向 × 最强梯度距离（外向相为正、内向相
    /// 为负 = 沿内法线拉回）；两相均无有效梯度 → 零向量。
    private static func edgeShift(
        from start: CGPoint,
        to end: CGPoint,
        centroid: CGPoint,
        maxShift: Double,
        edgeIndex: Int,
        raster: Raster,
        diagnostics: ((EdgeDiagnostic) -> Void)?
    ) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1e-9 else { return .zero }

        // 外法线：边的垂直方向中，背离质心的那一个。
        var nx = dy / length
        var ny = -dx / length
        let midX = (start.x + end.x) / 2
        let midY = (start.y + end.y) / 2
        if nx * (midX - centroid.x) + ny * (midY - centroid.y) < 0 {
            nx = -nx
            ny = -ny
        }


        // 沿边 5 点均值（双线性采样，spec/frame-truth FR-004）——±δ 仅约
        // 0.37 栅格列，最近邻取整会把两个采样点采成同一像素（梯度被量化
        // 成 0）；实时帧 405×720 / 栅格 160 列下这是外向相也失效的主因，
        // 故三处梯度（G0/外向/内向）统一用双线性。
        func meanLuminanceBilinear(atDistance distance: Double) -> Double {
            var total = 0.0
            for index in 0..<edgeSampleCount {
                let t = (Double(index) + 0.5) / Double(edgeSampleCount)
                let point = CGPoint(
                    x: start.x + dx * t + nx * distance,
                    y: start.y + dy * t + ny * distance
                )
                total += raster.luminanceBilinear(atNormalized: point)
            }
            return total / Double(edgeSampleCount)
        }

        // 剖面梯度 G(s) = L(s−δ) − L(s+δ)：s−δ 比 s 更靠页内——页内亮、
        // 页外暗的真实边缘无论落在 s 正侧还是负侧，G 都在边缘处取正峰。
        let delta = maxShift / Double(shiftStepCount)
        // s=0 对称梯度（spec/frame-truth FR-004）：检出边当前位置是否已压在
        // 真实边缘上——是则不动（外推/内拉都会被折脊/阴影带偏）。
        let g0 = meanLuminanceBilinear(atDistance: -delta)
            - meanLuminanceBilinear(atDistance: delta)
        if g0 >= gradientThreshold {
            diagnostics?(EdgeDiagnostic(
                edge: edgeIndex, g0: g0, outward: 0, inward: 0, shift: 0
            ))
            return .zero
        }
        /// 沿方向 `sign` 找**第一处**过阈值的边缘并取其峰位（最近峰策略，
        /// spec/frame-stability）。折页书的折痕（页内一侧）与折脊轮廓
        /// （更外侧、往往更强）都是「亮→暗」边——按「全窗最强梯度」会
        /// 跳过折痕、命中折脊，把折起来的部分留在框/成片里；按「第一个
        /// 过阈值的边」则稳定命中折痕，三条外缘也不受影响（第一个峰就是
        /// 纸边）。越过第一峰即止，不追更远的边缘。
        func firstEdgePeak(
            sign: Double, steps: Int, threshold: Double, limit: Double
        ) -> (shift: Double, gradient: Double)? {
            var crossed = false
            var peakShift = 0.0
            var peakGradient = 0.0
            for step in 1...steps {
                let s = sign * Double(step) * delta
                guard abs(s) + delta <= limit + 1e-9 else { break }
                let gradient = meanLuminanceBilinear(atDistance: s - delta)
                    - meanLuminanceBilinear(atDistance: s + delta)
                if !crossed {
                    if gradient >= threshold {
                        crossed = true
                        peakShift = s
                        peakGradient = gradient
                    }
                } else if gradient > peakGradient {
                    peakShift = s
                    peakGradient = gradient
                } else {
                    break
                }
            }
            return crossed ? (peakShift, peakGradient) : nil
        }
        let outward = firstEdgePeak(
            sign: 1, steps: shiftStepCount,
            threshold: gradientThreshold, limit: maxShift
        )
        let inward = firstEdgePeak(
            sign: -1, steps: shiftStepCount / 2,
            threshold: inwardGradientThreshold, limit: maxShift * inwardShiftRatio
        )
        // 最近峰胜出（|s| 更小者；同距外向优先）。
        let chosen: (shift: Double, gradient: Double)?
        switch (outward, inward) {
        case let (o?, i?):
            chosen = abs(o.shift) <= abs(i.shift) ? o : i
        case let (o?, nil):
            chosen = o
        case let (nil, i?):
            chosen = i
        case (nil, nil):
            chosen = nil
        }
        guard let chosen else {
            diagnostics?(EdgeDiagnostic(
                edge: edgeIndex, g0: g0,
                outward: outward?.gradient ?? 0,
                inward: inward?.gradient ?? 0,
                shift: 0
            ))
            return .zero
        }
        diagnostics?(EdgeDiagnostic(
            edge: edgeIndex, g0: g0,
            outward: outward?.gradient ?? 0,
            inward: inward?.gradient ?? 0,
            shift: chosen.shift
        ))
        return CGPoint(x: nx * chosen.shift, y: ny * chosen.shift)
    }

    // MARK: - 校验辅助

    /// 四边形凸性：相邻边叉积符号一致（共线视为可接受）。
    private static func isConvex(_ quad: Quad) -> Bool {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var sign = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            let c = points[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-12 { continue }
            let current = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = current
            } else if sign != current {
                return false
            }
        }
        return true
    }

    /// 顶点全部落在图像范围内（归一化 [0, 1]²，带极小数值容差）。
    private static func isInBounds(_ quad: Quad) -> Bool {
        let slack: CGFloat = 1e-6
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        return points.allSatisfy {
            $0.x >= -slack && $0.x <= 1 + slack && $0.y >= -slack && $0.y <= 1 + slack
        }
    }

    private static func shifted(_ point: CGPoint, by first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: point.x + first.x + second.x, y: point.y + first.y + second.y)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - 栅格（InkFigureDetector 先例）

    /// 亮度栅格：CGContext 缩放绘制 + y 翻转，原点左上，与 Quad 归一化空间一致。
    private struct Raster {
        let columns: Int
        let rows: Int
        let luminance: [Double]

        init?(image: CGImage) {
            let columns = EdgeSnapper.gridWidth
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

            // CGContext 原点在左下；本栅格统一「原点左上」，读取时翻转。
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

        /// 双线性采样（spec/frame-truth FR-004）：s=0 守卫的 ±δ 仅约 0.37
        /// 栅格列，最近邻会把两个采样点取整到同一像素（梯度被量化成 0）。
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
