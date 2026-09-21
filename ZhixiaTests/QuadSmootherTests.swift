import Foundation
import Testing
@testable import Zhixia

struct QuadSmootherTests {
    @Test("A stable quad locks after the configured duration")
    func locksWhenStable() {
        var smoother = QuadSmoother(lockDuration: 0.55, frameDt: 0.1)
        let quad = Quad.fullImage
        var state = QuadTrackState.searching
        for _ in 0..<8 {
            state = smoother.ingest(quad)
        }
        guard case .locked(let locked) = state else {
            Issue.record("Expected lock")
            return
        }
        #expect(locked.meanVertexDistance(to: quad) < 0.02)
    }

    @Test("Missing detections unlock after the miss limit")
    func unlocksAfterMisses() {
        var smoother = QuadSmoother(lockDuration: 0.2, frameDt: 0.1, missLimit: 3)
        for _ in 0..<6 {
            _ = smoother.ingest(.fullImage)
        }
        var state = QuadTrackState.locked(.fullImage)
        for _ in 0..<3 {
            state = smoother.ingest(nil)
        }
        #expect(state == .searching)
    }

    @Test("A large area jump clears the lock")
    func areaJumpClearsLock() {
        var smoother = QuadSmoother(lockDuration: 0.2, frameDt: 0.1, areaJump: 0.35)
        for _ in 0..<6 {
            _ = smoother.ingest(.fullImage)
        }
        let tiny = Quad(
            topLeft: CGPoint(x: 0.35, y: 0.35),
            topRight: CGPoint(x: 0.65, y: 0.35),
            bottomRight: CGPoint(x: 0.65, y: 0.65),
            bottomLeft: CGPoint(x: 0.35, y: 0.65)
        )
        let state = smoother.ingest(tiny)
        if case .locked = state {
            Issue.record("Lock should not survive an area jump")
        }
    }

    // MARK: - Quad 扫描框边精度扩展（plan D5/D8，T006）

    private func rectQuad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: x0, y: y0),
            topRight: CGPoint(x: x1, y: y0),
            bottomRight: CGPoint(x: x1, y: y1),
            bottomLeft: CGPoint(x: x0, y: y1)
        )
    }

    @Test("Suspicion matrix: touching-edge and near-full are suspicious; normal and far are not")
    func autoCaptureSuspicionMatrix() {
        // 触边：左边距 0.5% < 1.5% 阈值。
        let touchingEdge = rectQuad(0.005, 0.2, 0.6, 0.8)
        #expect(touchingEdge.isSuspiciousForAutoCapture())

        // 右边距 0.8% 同样触边。
        let touchingRight = rectQuad(0.2, 0.2, 0.992, 0.8)
        #expect(touchingRight.isSuspiciousForAutoCapture())

        // 近满幅（面积分支，用 edgeMargin: 0 隔离——margin 分支在边距 ≥0 时不触发）：
        // 面积 1.0 ≥ 0.95；以及 0.98 的横贯框（上下边距 1%，但 edgeMargin=0 时不走 margin 分支）。
        #expect(Quad.fullImage.isSuspiciousForAutoCapture(edgeMargin: 0))
        let nearFull = rectQuad(0.0, 0.01, 1.0, 0.99)
        #expect(nearFull.isSuspiciousForAutoCapture(edgeMargin: 0))
        #expect(Quad.fullImage.isSuspiciousForAutoCapture())

        // 正常：边距 5%、面积 0.81 —— 照旧自动拍。
        let normal = rectQuad(0.05, 0.05, 0.95, 0.95)
        #expect(!normal.isSuspiciousForAutoCapture())

        // 远离：居中小框。
        let far = rectQuad(0.3, 0.3, 0.7, 0.7)
        #expect(!far.isSuspiciousForAutoCapture())

        // 阈值是参数化的：边距 2% 在 1.5% 阈值下正常，在 3% 阈值下可疑。
        let twoPercent = rectQuad(0.02, 0.02, 0.98, 0.98)
        #expect(!twoPercent.isSuspiciousForAutoCapture())
        #expect(twoPercent.isSuspiciousForAutoCapture(edgeMargin: 0.03))
    }

    @Test("Containment: full containment is 1, partial is proportional, disjoint is 0")
    func containmentMatrix() {
        let outer = rectQuad(0.1, 0.1, 0.9, 0.9)
        let inner = rectQuad(0.3, 0.3, 0.7, 0.7)

        // 全含：交集 = 自身包围盒 → 1。
        #expect(abs(inner.containment(in: outer) - 1) < 0.001)
        // 包含者自身的包含度（被内含者覆盖）应显著小于 1。
        #expect(outer.containment(in: inner) < 0.25)

        // 部分：交集 0.04 / 自身 0.16 = 0.25，且方向不对称。
        let a = rectQuad(0.1, 0.1, 0.5, 0.5)
        let b = rectQuad(0.3, 0.3, 0.7, 0.7)
        #expect(abs(a.containment(in: b) - 0.25) < 0.001)
        #expect(abs(b.containment(in: a) - 0.25) < 0.001)

        // 相离：无交集 → 0。
        let disjoint = rectQuad(0.1, 0.1, 0.2, 0.2)
        #expect(disjoint.containment(in: b) == 0)
    }
}

struct FrameMapperTests {
    @Test("Aspect-fill fallback centers the wider axis")
    func aspectFillCentersWideAxis() {
        // 横图进竖屏视图：宽受限 → x 拉伸出屏（aspect-fill 裁切），y 恒等。
        let image = CGSize(width: 1920, height: 1080)
        let view = CGSize(width: 390, height: 844)
        let mapped = FrameMapper.viewQuad(from: .fullImage, imageSize: image, viewSize: view)
        #expect(mapped.topLeft.x < 0)
        #expect(mapped.topRight.x > 1)
        #expect(abs(mapped.topLeft.y - 0) < 1e-9)
        #expect(abs(mapped.bottomRight.y - 1) < 1e-9)
        #expect(abs(mapped.center.x - 0.5) < 1e-9)
    }
}

struct DocumentTitleTests {
    @Test("Duplicate titles get a numeric suffix")
    func suffix() {
        let now = Date(timeIntervalSince1970: 1_788_048_000)
        let first = DocumentTitle.automatic(now: now, existingTitles: [])
        let second = DocumentTitle.automatic(now: now, existingTitles: [first])
        #expect(first.contains("扫描"))
        #expect(second.contains("· 2"))
    }
}

struct DocumentMaskQuadTests {
    @Test("A centered document mask becomes an inset quad")
    func centeredMask() {
        let quad = DocumentMaskQuad.make(width: 10, height: 10) { x, y in
            (2...7).contains(x) && (2...7).contains(y)
        }
        #expect(quad != nil)
        #expect(abs((quad?.topLeft.x ?? 0) - 2.0 / 9.0) < 0.02)
        #expect(abs((quad?.bottomRight.x ?? 0) - 7.0 / 9.0) < 0.02)
        #expect((quad?.area ?? 0) > 0.2)
        #expect((quad?.area ?? 1) < 0.9)
    }

    @Test("A full-frame mask is ignored so screenshots stay uncropped")
    func fullMaskIgnored() {
        let quad = DocumentMaskQuad.make(width: 8, height: 8) { _, _ in true }
        #expect(quad == nil)
    }
}
