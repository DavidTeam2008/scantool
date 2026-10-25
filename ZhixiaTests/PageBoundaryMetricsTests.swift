import CoreGraphics
import Testing
@testable import Zhixia

struct PageBoundaryMetricsTests {
    private static let square = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )

    @Test("方页边角为 0，平行误差为 0")
    func squareHasZeroErrors() {
        let angles = PageBoundaryMetrics.edgeAnglesDegrees(Self.square)
        #expect(angles.allSatisfy { abs($0) < 0.001 })
        let parallel = PageBoundaryMetrics.parallelErrorsDegrees(Self.square)
        #expect(abs(parallel.horizontal) < 0.001)
        #expect(abs(parallel.vertical) < 0.001)
    }

    @Test("倾斜页会报告角度与平行误差")
    func skewedQuadReportsErrors() {
        let skewed = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.12),
            topRight: CGPoint(x: 0.9, y: 0.10),
            bottomRight: CGPoint(x: 0.9, y: 0.90),
            bottomLeft: CGPoint(x: 0.1, y: 0.88)
        )
        let angles = PageBoundaryMetrics.edgeAnglesDegrees(skewed)
        #expect(abs(angles[0]) > 1.0)
        let parallel = PageBoundaryMetrics.parallelErrorsDegrees(skewed)
        #expect(parallel.horizontal > 1.0)
    }

    @Test("页外面积比例")
    func outsideAreaRatio() {
        #expect(abs(PageBoundaryMetrics.outsideAreaRatio(Self.square) - 0.36) < 0.001)
        #expect(PageBoundaryMetrics.outsideAreaRatio(.fullImage) == 0)
    }
}
