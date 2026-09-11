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
}

struct FrameMapperTests {
    @Test("Aspect-fill mapping is invertible for a centered point")
    func mappingRoundTrips() {
        let image = CGSize(width: 1920, height: 1080)
        let view = CGSize(width: 390, height: 844)
        let source = Quad.fullImage
        let viewQuad = FrameMapper.viewQuad(from: source, imageSize: image, viewSize: view)
        let back = FrameMapper.imageQuad(from: viewQuad, imageSize: image, viewSize: view)
        #expect(abs(back.center.x - source.center.x) < 0.01)
        #expect(abs(back.center.y - source.center.y) < 0.01)
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
