import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// P0.1 纸张/内容包络的确定性单测（不依赖 Vision）。
struct PageContentEnvelopeDetectorTests {
    private func image(
        width: Int = 400,
        height: Int = 560,
        pageRect: CGRect,
        background: UIColor,
        paper: UIColor,
        marks: [CGRect]
    ) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            paper.setFill()
            context.fill(pageRect)
            UIColor.black.setFill()
            for mark in marks {
                context.fill(mark)
            }
        }
        return try #require(image.cgImage)
    }

    @Test("暗桌面 + 页内标题/页码/图块：包络裁掉页外背景且包含内容")
    func detectsPageAndContent() throws {
        let page = CGRect(x: 42, y: 38, width: 318, height: 484)
        let title = CGRect(x: 58, y: 62, width: 180, height: 18)
        let pageNumber = CGRect(x: 330, y: 500, width: 17, height: 16)
        let figure = CGRect(x: 210, y: 330, width: 120, height: 110)
        let image = try image(
            pageRect: page,
            background: UIColor(red: 0.16, green: 0.12, blue: 0.10, alpha: 1),
            paper: UIColor(white: 0.94, alpha: 1),
            marks: [title, pageNumber, figure]
        )

        let candidate = try #require(PageContentEnvelopeDetector.detect(in: image))
        #expect(candidate.paperRect.minX > 0.07)
        #expect(candidate.paperRect.minY > 0.04)
        #expect(candidate.paperRect.maxX < 0.95)
        #expect(candidate.paperRect.maxY < 0.95)
        #expect(candidate.rect.minX <= title.minX / 400)
        #expect(candidate.rect.minY <= title.minY / 560)
        #expect(candidate.rect.maxX >= pageNumber.maxX / 400)
        #expect(candidate.rect.maxY >= pageNumber.maxY / 560)
        #expect(candidate.contentRect != nil)
        #expect(candidate.backgroundResidual >= 0)
    }

    @Test("没有可辨识页边时宁可不返回候选")
    func rejectsLowContrastPage() throws {
        // 全图都是纸色、没有页外背景；不应凭空白产生一个裁切框。
        let image = try image(
            pageRect: CGRect(x: 0, y: 0, width: 400, height: 560),
            background: UIColor(white: 0.94, alpha: 1),
            paper: UIColor(white: 0.94, alpha: 1),
            marks: []
        )
        // 全纸页可能仍返回 full-frame 候选；调用方由“没有向内收边”拒绝。
        if let candidate = PageContentEnvelopeDetector.detect(in: image) {
            #expect(candidate.trimmedPaperEdges.isEmpty)
        }
    }
}
