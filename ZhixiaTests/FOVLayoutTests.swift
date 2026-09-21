import Foundation
import Testing
@testable import Zhixia

/// FOVLayout 换算回归网（FR-011：任意宽高比组合、可逆性、恒等、非法输入兜底）。
struct FOVLayoutTests {
    /// 模拟器组合：竖屏 16:9 视频（0.5625）→ 4:3 照片（0.75）。
    private static let videoAspect = 9.0 / 16.0
    private static let photoAspect = 3.0 / 4.0

    @Test("16:9 video full frame maps to the center 75% horizontal span of a 4:3 photo")
    func videoToPhotoHorizontalSpan() {
        let converted = FOVLayout.convert(
            quad: .fullImage,
            fromAspect: Self.videoAspect,
            toAspect: Self.photoAspect
        )
        #expect(abs(converted.topLeft.x - 0.125) < 0.001)
        #expect(abs(converted.topRight.x - 0.875) < 0.001)
        #expect(abs(converted.bottomLeft.x - 0.125) < 0.001)
        #expect(abs(converted.bottomRight.x - 0.875) < 0.001)
        // 纵向视野共享（同传感器中心裁切的长轴）。
        #expect(abs(converted.topLeft.y - 0) < 0.001)
        #expect(abs(converted.bottomRight.y - 1) < 0.001)
    }

    @Test("Video-space quad converts to photo space with exact numeric mapping")
    func videoQuadMapsNumerically() {
        // 视频空间 x=0.25 → 照片空间 0.125 + 0.25 × 0.75 = 0.3125。
        let videoQuad = Quad(
            topLeft: CGPoint(x: 0.25, y: 0.1),
            topRight: CGPoint(x: 0.75, y: 0.1),
            bottomRight: CGPoint(x: 0.75, y: 0.9),
            bottomLeft: CGPoint(x: 0.25, y: 0.9)
        )
        let converted = FOVLayout.convert(
            quad: videoQuad,
            fromAspect: Self.videoAspect,
            toAspect: Self.photoAspect
        )
        #expect(abs(converted.topLeft.x - 0.3125) < 0.001)
        #expect(abs(converted.topRight.x - 0.6875) < 0.001)
        #expect(abs(converted.topLeft.y - 0.1) < 0.001)
        #expect(abs(converted.bottomRight.y - 0.9) < 0.001)
    }

    @Test("Equal aspects convert to identity")
    func equalAspectsAreIdentity() {
        let quad = Quad(
            topLeft: CGPoint(x: 0.2, y: 0.1),
            topRight: CGPoint(x: 0.8, y: 0.1),
            bottomRight: CGPoint(x: 0.8, y: 0.9),
            bottomLeft: CGPoint(x: 0.2, y: 0.9)
        )
        let converted = FOVLayout.convert(quad: quad, fromAspect: 0.75, toAspect: 0.75)
        #expect(converted == quad)

        let identityGeometry = FOVLayout.convert(quad: quad, fromAspect: 1, toAspect: 1)
        #expect(identityGeometry == quad)
    }

    @Test("Conversion round-trips for arbitrary aspect pairs")
    func conversionRoundTrips() {
        let aspects: [Double] = [9.0 / 16.0, 0.6, 0.75, 0.9, 1.0]
        let quad = Quad(
            topLeft: CGPoint(x: 0.3, y: 0.2),
            topRight: CGPoint(x: 0.7, y: 0.2),
            bottomRight: CGPoint(x: 0.7, y: 0.8),
            bottomLeft: CGPoint(x: 0.3, y: 0.8)
        )
        for from in aspects {
            for to in aspects where from != to {
                let there = FOVLayout.convert(quad: quad, fromAspect: from, toAspect: to)
                let back = FOVLayout.convert(quad: there, fromAspect: to, toAspect: from)
                #expect(back.meanVertexDistance(to: quad) < 0.0001)
            }
        }
    }

    @Test("Narrower-to-wider conversion stays inside the target frame")
    func narrowToWideStaysInBounds() {
        let converted = FOVLayout.convert(quad: .fullImage, fromAspect: 0.1, toAspect: 1.0)
        #expect(converted.boundingRect.minX >= 0)
        #expect(converted.boundingRect.maxX <= 1)
        #expect(converted.boundingRect.minY >= 0)
        #expect(converted.boundingRect.maxY <= 1)
        // x∈[0,1] → [(1−0.1)/2, 1−(1−0.1)/2] = [0.45, 0.55]。
        #expect(abs(converted.boundingRect.minX - 0.45) < 0.001)
        #expect(abs(converted.boundingRect.maxX - 0.55) < 0.001)
    }

    @Test("Invalid aspects return the quad unchanged")
    func invalidAspectsReturnInput() {
        let quad = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let invalidAspects: [Double] = [0, -0.75, .nan, .infinity, -.infinity]
        for aspect in invalidAspects {
            #expect(FOVLayout.convert(quad: quad, fromAspect: aspect, toAspect: 0.75) == quad)
            #expect(FOVLayout.convert(quad: quad, fromAspect: 0.75, toAspect: aspect) == quad)
        }
    }
}
