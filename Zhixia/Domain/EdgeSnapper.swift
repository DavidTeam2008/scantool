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
enum EdgeSnapper {
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

    // MARK: - 单一入口

    /// 把 still 检出 `quad` 沿四边外法线吸附到 `image` 的真实亮度边缘。
    ///
    /// - `maxShiftRatio`：单边最大位移 = 比例 × quad 短边（任务带 3~5%）。
    /// - 四项校验（凸性 / 图像边界 / 最大位移 / 面积变化）任一失败 → 原样返回。
    /// - `image` 必须与 `quad` 同方向（直立）；调用方负责 EXIF 校正。
    static func snap(quad: Quad, image: CGImage, maxShiftRatio: Double) -> Quad {
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
        let shifts = edges.map { edge in
            edgeShift(
                from: edge.0,
                to: edge.1,
                centroid: centroid,
                maxShift: maxShift,
                raster: raster
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

    /// 单条边的外推位移向量：外法线方向 × 最强梯度距离；无有效梯度 → 零向量。
    private static func edgeShift(
        from start: CGPoint,
        to end: CGPoint,
        centroid: CGPoint,
        maxShift: Double,
        raster: Raster
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

        /// 沿边均匀取 `edgeSampleCount` 个点，取距边 `distance` 处的平均亮度。
        func meanLuminance(atDistance distance: Double) -> Double {
            var total = 0.0
            for index in 0..<edgeSampleCount {
                let t = (Double(index) + 0.5) / Double(edgeSampleCount)
                let point = CGPoint(
                    x: start.x + dx * t + nx * distance,
                    y: start.y + dy * t + ny * distance
                )
                total += raster.luminance(atNormalized: point)
            }
            return total / Double(edgeSampleCount)
        }

        // 剖面梯度 G(s) = L(s−δ) − L(s+δ)：s 落在「亮→暗」边界时最大。
        let delta = maxShift / Double(shiftStepCount)
        var bestShift = 0.0
        var bestGradient = 0.0
        for step in 0...shiftStepCount {
            let s = Double(step) * delta
            guard s - delta >= 0, s + delta <= maxShift + 1e-9 else { continue }
            let gradient = meanLuminance(atDistance: s - delta) - meanLuminance(atDistance: s + delta)
            if gradient > bestGradient {
                bestGradient = gradient
                bestShift = s
            }
        }
        guard bestGradient >= gradientThreshold else { return .zero }
        return CGPoint(x: nx * bestShift, y: ny * bestShift)
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

        func luminance(atNormalized point: CGPoint) -> Double {
            let column = min(max(Int((point.x * CGFloat(columns)).rounded()), 0), columns - 1)
            let row = min(max(Int((point.y * CGFloat(rows)).rounded()), 0), rows - 1)
            return luminance[row * columns + column]
        }
    }
}
