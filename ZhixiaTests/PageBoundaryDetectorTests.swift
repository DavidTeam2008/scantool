import CoreGraphics
import Testing
@testable import Zhixia

struct PageBoundaryDetectorTests {
    private static let full = Quad.fullImage
    private static let paper = Quad(
        topLeft: CGPoint(x: 0.05, y: 0.04),
        topRight: CGPoint(x: 0.95, y: 0.04),
        bottomRight: CGPoint(x: 0.95, y: 0.96),
        bottomLeft: CGPoint(x: 0.05, y: 0.96)
    )

    @Test("拍后页面分割：包含全部墨迹时采用检测框")
    func acceptsDetectedPageWhenInkCovered() {
        let chosen = PageBoundaryDetector.choose(
            proposed: Self.full,
            detected: .init(quad: Self.paper, confidence: 0.9, area: Self.paper.area),
            inkBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        #expect(chosen == Self.paper)
    }

    @Test("检测框会裁到墨迹时退回提议框（不裁字优先）")
    func rejectsDetectedPageThatCropsInk() {
        let tooSmall = Quad(
            topLeft: CGPoint(x: 0.2, y: 0.2),
            topRight: CGPoint(x: 0.8, y: 0.2),
            bottomRight: CGPoint(x: 0.8, y: 0.8),
            bottomLeft: CGPoint(x: 0.2, y: 0.8)
        )
        let chosen = PageBoundaryDetector.choose(
            proposed: Self.full,
            detected: .init(quad: tooSmall, confidence: 0.95, area: tooSmall.area),
            inkBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        #expect(chosen == Self.full)
    }

    @Test("低置信/退化/无检测时保持提议框")
    func fallsBackToProposed() {
        #expect(
            PageBoundaryDetector.choose(proposed: Self.full, detected: nil, inkBounds: nil)
                == Self.full
        )
        // 真机文档分割 confidence 可能为 0；有效几何应被采用（置信度只记遥测）。
        #expect(
            PageBoundaryDetector.choose(
                proposed: Self.full,
                detected: .init(quad: Self.paper, confidence: 0, area: Self.paper.area),
                inkBounds: nil
            ) == Self.paper
        )
        #expect(
            PageBoundaryDetector.choose(
                proposed: Self.full,
                detected: .init(quad: .fullImage, confidence: 0.9, area: 1),
                inkBounds: nil
            ) == Self.full
        )
    }
}
