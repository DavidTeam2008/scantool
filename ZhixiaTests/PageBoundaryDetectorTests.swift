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

    @Test("1% 安全边：外扩但不越出页面")
    func expandsSafetyMarginAndClamps() {
        let expanded = Self.paper.expanded(by: 0.01)
        #expect(expanded.area > Self.paper.area)
        #expect(expanded.topLeft.x < Self.paper.topLeft.x)
        #expect(expanded.topLeft.y < Self.paper.topLeft.y)
        #expect(expanded.bottomRight.x > Self.paper.bottomRight.x)
        let full = Quad.fullImage.expanded(by: 0.01)
        #expect(full.topLeft == CGPoint(x: 0, y: 0))
        #expect(full.bottomRight == CGPoint(x: 1, y: 1))
    }

    @Test("页内文字框过滤：页左外的折条文字不算页内墨迹")
    func filtersTextBoxesInsidePage() {
        let page = Quad(
            topLeft: CGPoint(x: 0.09, y: 0.04),
            topRight: CGPoint(x: 0.95, y: 0.03),
            bottomRight: CGPoint(x: 0.99, y: 0.96),
            bottomLeft: CGPoint(x: 0.097, y: 0.957)
        )
        let strip = CGRect(x: 0.0436, y: 0.4, width: 0.03, height: 0.006)
        let title = CGRect(x: 0.1056, y: 0.125, width: 0.21, height: 0.02)
        let body = CGRect(x: 0.14, y: 0.3, width: 0.3, height: 0.012)
        let inside = PageBoundaryDetector.textBoxes(
            in: page,
            from: [strip, title, body]
        )
        #expect(inside == [title, body])
        #expect(PageBoundaryDetector.textBounds(boxes: inside)?.minX == title.minX)
    }

    @Test("页级左缘内收 1%，给标题保留 0.3% 安全边")
    func insetsPageLeftAndKeepsTitleMargin() throws {
        let page = Quad(
            topLeft: CGPoint(x: 0.0899, y: 0.0412),
            topRight: CGPoint(x: 0.9510, y: 0.0334),
            bottomRight: CGPoint(x: 0.9861, y: 0.9648),
            bottomLeft: CGPoint(x: 0.0972, y: 0.9570)
        )
        let strip = CGRect(x: 0.0436, y: 0.4, width: 0.03, height: 0.006)
        let title = CGRect(x: 0.1056, y: 0.125, width: 0.21, height: 0.02)
        let result = try #require(
            PageBoundaryDetector.pageLeftInset(
                in: page,
                allTextBoxes: [strip, title]
            )
        )
        #expect(result.quad.topLeft.x > page.topLeft.x)
        #expect(result.quad.topLeft.x + 0.003 <= title.minX + 0.0001)
        #expect(result.quad.topRight == page.topRight)
        #expect(result.quad.bottomRight == page.bottomRight)
        #expect(result.quad.area < page.area)
        #expect(result.ratio > 0.009)
        #expect(result.ratio <= 0.0101)
    }

    @Test("页内无文字/文字太靠左/非页级框不内收")
    func rejectsUnsafeLeftInset() {
        let page = Quad(
            topLeft: CGPoint(x: 0.09, y: 0.04),
            topRight: CGPoint(x: 0.95, y: 0.04),
            bottomRight: CGPoint(x: 0.95, y: 0.96),
            bottomLeft: CGPoint(x: 0.09, y: 0.96)
        )
        #expect(PageBoundaryDetector.pageLeftInset(in: page, allTextBoxes: []) == nil)
        #expect(
            PageBoundaryDetector.pageLeftInset(
                in: page,
                allTextBoxes: [CGRect(x: 0.091, y: 0.2, width: 0.2, height: 0.02)]
            ) == nil
        )
        #expect(
            PageBoundaryDetector.pageLeftInset(
                in: .fullImage,
                allTextBoxes: [CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.02)]
            ) == nil
        )
    }
}
