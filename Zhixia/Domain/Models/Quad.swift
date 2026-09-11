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
