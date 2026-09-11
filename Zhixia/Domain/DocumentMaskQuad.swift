import Foundation

enum DocumentMaskQuad {
    static func make(width: Int, height: Int, step: Int = 1, isForeground: (Int, Int) -> Bool) -> Quad? {
        guard width > 1, height > 1 else { return nil }
        let strideStep = max(1, step)
        var minSum = Double.greatestFiniteMagnitude
        var maxSum = -Double.greatestFiniteMagnitude
        var minDiff = Double.greatestFiniteMagnitude
        var maxDiff = -Double.greatestFiniteMagnitude
        var topLeft = CGPoint.zero
        var topRight = CGPoint.zero
        var bottomRight = CGPoint.zero
        var bottomLeft = CGPoint.zero
        var found = false

        for y in stride(from: 0, to: height, by: strideStep) {
            for x in stride(from: 0, to: width, by: strideStep) {
                guard isForeground(x, y) else { continue }
                found = true
                let nx = Double(x)
                let ny = Double(y)
                let sum = nx + ny
                let diff = nx - ny
                if sum < minSum {
                    minSum = sum
                    topLeft = CGPoint(x: nx, y: ny)
                }
                if sum > maxSum {
                    maxSum = sum
                    bottomRight = CGPoint(x: nx, y: ny)
                }
                if diff < minDiff {
                    minDiff = diff
                    bottomLeft = CGPoint(x: nx, y: ny)
                }
                if diff > maxDiff {
                    maxDiff = diff
                    topRight = CGPoint(x: nx, y: ny)
                }
            }
        }

        guard found else { return nil }
        let quad = Quad(
            topLeft: CGPoint(x: topLeft.x / Double(width - 1), y: topLeft.y / Double(height - 1)),
            topRight: CGPoint(x: topRight.x / Double(width - 1), y: topRight.y / Double(height - 1)),
            bottomRight: CGPoint(x: bottomRight.x / Double(width - 1), y: bottomRight.y / Double(height - 1)),
            bottomLeft: CGPoint(x: bottomLeft.x / Double(width - 1), y: bottomLeft.y / Double(height - 1))
        ).clamped()
        guard !quad.isDegenerate, quad.area > 0.08, quad.area < 0.96 else {
            return nil
        }
        return quad
    }
}
