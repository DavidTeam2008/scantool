import CoreGraphics
import Testing

@testable import Zhixia

/// CF-T010（spec FR-012 / SC-007）：贴画幅边 = 书/页没完整进框。
///
/// 取景域 == 成片域后，照片空间 [0,1] 就是屏幕所见画幅；修复前预览只显示
/// 61.6% 宽，被钳到“可见域”的包络在照片空间里离画幅边很远（0.192），
/// 旧的贴边判定抓不到——这个纯函数是快门/overlay 未就绪态的共同依据。
struct CaptureFrameClippingTests {
    private func quad(
        _ minX: Double,
        _ minY: Double,
        _ maxX: Double,
        _ maxY: Double
    ) -> Quad {
        Quad(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomRight: CGPoint(x: maxX, y: maxY),
            bottomLeft: CGPoint(x: minX, y: maxY)
        )
    }

    @Test("四边留白 ≥1.5% → 完整，不算裁切")
    func completeInside() {
        #expect(!quad(0.05, 0.05, 0.95, 0.95).isClippedAtFrameEdge())
        #expect(!quad(0.016, 0.016, 0.984, 0.984).isClippedAtFrameEdge())
    }

    @Test("任一边贴画幅边 → 裁切（四个方向）")
    func eachEdgeClipped() {
        #expect(quad(0.0, 0.1, 0.9, 0.9).isClippedAtFrameEdge(), "左")
        #expect(quad(0.1, 0.0, 0.9, 0.9).isClippedAtFrameEdge(), "上")
        #expect(quad(0.1, 0.1, 1.0, 0.9).isClippedAtFrameEdge(), "右")
        #expect(quad(0.1, 0.1, 0.9, 1.0).isClippedAtFrameEdge(), "下")
    }

    @Test("容差边界：1.4% 判裁切，1.6% 不判（默认 1.5%）")
    func marginBoundary() {
        #expect(quad(0.014, 0.1, 0.9, 0.9).isClippedAtFrameEdge())
        #expect(!quad(0.016, 0.1, 0.9, 0.9).isClippedAtFrameEdge())
    }

    @Test("越出画幅（负坐标 / >1）也算裁切")
    func outsideFrame() {
        #expect(quad(-0.02, 0.1, 0.9, 0.9).isClippedAtFrameEdge())
        #expect(quad(0.1, 0.1, 1.02, 0.9).isClippedAtFrameEdge())
    }

    @Test("近距单页判定：归一化宽高比 <1.3 为单页，整摊 ≥1.3 不是")
    func singlePageForCapture() {
        // 3:4 照片里一页竖版书页的归一化宽高比 ≈1.0（不是像素比 0.75），
        // 所以不能复用 spreadAspectThreshold=0.95——那会把单页也判成整摊。
        #expect(PageIntentResolver.isSinglePageForCapture(quad(0.10, 0.10, 1.00, 0.90)))
        #expect(!PageIntentResolver.isSinglePageForCapture(quad(0.00, 0.20, 1.00, 0.62)))
        #expect(!PageIntentResolver.isSinglePageForCapture(quad(0.10, 0.10, 0.11, 0.11)))
    }

    @Test("自定义容差生效（贴边引导线可按 2% 放宽）")
    func customMargin() {
        #expect(!quad(0.025, 0.1, 0.9, 0.9).isClippedAtFrameEdge(margin: 0.02))
        #expect(quad(0.025, 0.1, 0.9, 0.9).isClippedAtFrameEdge(margin: 0.03))
    }
}
