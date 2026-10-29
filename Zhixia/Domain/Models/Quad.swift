import Foundation

struct Quad: Equatable, Sendable, Codable, Hashable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let fullImage = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// Portrait preview window approximating an 85.6∶54 card.
    static let idCardWindow = Quad(
        topLeft: CGPoint(x: 0.12, y: 0.32),
        topRight: CGPoint(x: 0.88, y: 0.32),
        bottomRight: CGPoint(x: 0.88, y: 0.68),
        bottomLeft: CGPoint(x: 0.12, y: 0.68)
    )

    var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    var center: CGPoint {
        let xs = points.map(\.x).reduce(0, +) / 4
        let ys = points.map(\.y).reduce(0, +) / 4
        return CGPoint(x: xs, y: ys)
    }

    var area: Double {
        abs(shoelace())
    }

    var isDegenerate: Bool {
        area < 0.02 || isSelfIntersecting || !isConvex
    }

    var boundingRect: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    var squareness: Double {
        let corners = [
            cornerAngle(bottomLeft, topLeft, topRight),
            cornerAngle(topLeft, topRight, bottomRight),
            cornerAngle(topRight, bottomRight, bottomLeft),
            cornerAngle(bottomRight, bottomLeft, topLeft)
        ]
        let errors = corners.map { abs($0 - .pi / 2) }
        let mean = errors.reduce(0, +) / 4
        return max(0, 1 - mean / (.pi / 2))
    }

    func score(preferringCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Double {
        let distance = hypot(center.x - preferringCenter.x, center.y - preferringCenter.y)
        let centerWeight = max(0, 1 - distance / 0.5)
        return area * centerWeight * squareness
    }

    func interpolated(toward other: Quad, alpha: Double) -> Quad {
        let t = min(1, max(0, alpha))
        return Quad(
            topLeft: lerp(topLeft, other.topLeft, t),
            topRight: lerp(topRight, other.topRight, t),
            bottomRight: lerp(bottomRight, other.bottomRight, t),
            bottomLeft: lerp(bottomLeft, other.bottomLeft, t)
        )
    }

    func meanVertexDistance(to other: Quad) -> Double {
        zip(points, other.points)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .reduce(0, +) / 4
    }

    func pixelPoints(imageSize: CGSize) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        (
            CGPoint(x: topLeft.x * imageSize.width, y: topLeft.y * imageSize.height),
            CGPoint(x: topRight.x * imageSize.width, y: topRight.y * imageSize.height),
            CGPoint(x: bottomRight.x * imageSize.width, y: bottomRight.y * imageSize.height),
            CGPoint(x: bottomLeft.x * imageSize.width, y: bottomLeft.y * imageSize.height)
        )
    }

    /// 以中心为基准向外扩 `ratio`（0.01 = 各边约 1% 页宽/页高），并夹回页面。
    /// 用于页面检测后的安全边，避免页边文字被切。
    func expanded(by ratio: CGFloat) -> Quad {
        guard ratio > 0 else { return clamped() }
        let center = self.center
        let scale = 1 + ratio * 2
        func expand(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: center.x + (p.x - center.x) * scale,
                y: center.y + (p.y - center.y) * scale
            )
        }
        return Quad(
            topLeft: expand(topLeft),
            topRight: expand(topRight),
            bottomRight: expand(bottomRight),
            bottomLeft: expand(bottomLeft)
        ).clamped()
    }

    func clamped() -> Quad {
        Quad(
            topLeft: clamp(topLeft),
            topRight: clamp(topRight),
            bottomRight: clamp(bottomRight),
            bottomLeft: clamp(bottomLeft)
        )
    }

    func iou(with other: Quad) -> Double {
        let a = boundingRect
        let b = other.boundingRect
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    private var isSelfIntersecting: Bool {
        segmentsIntersect(topLeft, topRight, bottomLeft, bottomRight)
            || segmentsIntersect(topLeft, bottomLeft, topRight, bottomRight)
    }

    private var isConvex: Bool {
        let pts = points
        var previous: Double = 0
        for index in 0..<4 {
            let a = pts[index]
            let b = pts[(index + 1) % 4]
            let c = pts[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if index > 0, cross * previous < 0 {
                return false
            }
            if cross != 0 {
                previous = cross
            }
        }
        return true
    }

    private func shoelace() -> Double {
        let pts = points
        var sum: Double = 0
        for index in 0..<4 {
            let current = pts[index]
            let next = pts[(index + 1) % 4]
            sum += current.x * next.y - next.x * current.y
        }
        return sum / 2
    }
}

// MARK: - 扫描框边精度扩展（spec/scan-edge-accuracy，plan D5/D8）
//
// 纯函数扩展：不改动既有成员与持久化语义（照片空间归一化，FR-012）。

extension Quad {
    /// 自动快门门禁（plan D8 / FR-008）：判定锁定框是否「可疑」——
    /// 任一边距图像边缘 < `edgeMargin`（书可能被画面裁切/触边），或面积 ≥ `maxArea`
    /// （近满幅，取景大概率切到书）。可疑时 ViewModel 抑制自动快门并提示后移。
    ///
    /// - Parameters:
    ///   - edgeMargin: 边距阈值（归一化比例），默认 0.015（1.5%）。
    ///   - maxArea: 面积阈值（归一化），默认 0.95。
    /// - Returns: 可疑 → `true`（不得自动拍）；正常 → `false`（照旧自动拍）。
    func isSuspiciousForAutoCapture(edgeMargin: Double = 0.015, maxArea: Double = 0.95) -> Bool {
        if area >= maxArea { return true }
        let rect = boundingRect
        let minimumMargin = min(rect.minX, rect.minY, 1 - rect.maxX, 1 - rect.maxY)
        return minimumMargin < edgeMargin
    }

    /// 是否被画幅边缘裁切（CF-T010，spec FR-012）——任一边距画幅边界
    /// < `margin` 即视为“书/页没有完整进框”。
    ///
    /// 与 `isSuspiciousForAutoCapture` 的区别：这里**只看贴边**，不看面积
    /// （近满幅但四边留白足够的页面仍然可拍）；也不含“自动快门”语义。
    /// 取景域 == 成片域后，这个判定第一次真正成立：修复前预览只显示帧宽
    /// 61.6%，被裁的书在照片空间里仍离画幅边界很远，旧的贴边判定抓不到
    /// （视频 11 t≈36 的整页假框就是这么来的——包络被钳到“可见域”，照片
    /// 空间边距 0.192，看起来完全安全）。
    ///
    /// - Parameter margin: 贴边容差（归一化），默认 0.015（1.5%）。
    func isClippedAtFrameEdge(margin: Double = 0.015) -> Bool {
        let rect = boundingRect
        return min(rect.minX, rect.minY, 1 - rect.maxX, 1 - rect.maxY) < margin
    }

    /// 包含度（plan D5 / FR-003）：自身包围盒被 `other` 包围盒覆盖的比例
    /// （交集面积 ÷ 自身包围盒面积）。供候选「内部矩形降权」判定。
    /// 自身包围盒退化（宽或高为 0）或无交集时返回 0。
    func containment(in other: Quad) -> Double {
        let own = boundingRect
        guard own.width > 0, own.height > 0 else { return 0 }
        let intersection = own.intersection(other.boundingRect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        return (intersection.width * intersection.height) / (own.width * own.height)
    }
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

private func clamp(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
}

private func cornerAngle(_ a: CGPoint, _ vertex: CGPoint, _ c: CGPoint) -> Double {
    let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
    let v2 = CGPoint(x: c.x - vertex.x, y: c.y - vertex.y)
    let dot = v1.x * v2.x + v1.y * v2.y
    let mag = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
    guard mag > 0 else { return 0 }
    return acos(min(1, max(-1, dot / mag)))
}

private func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
    func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }
    let o1 = orient(a, b, c)
    let o2 = orient(a, b, d)
    let o3 = orient(c, d, a)
    let o4 = orient(c, d, b)
    return o1 * o2 < 0 && o3 * o4 < 0
}
