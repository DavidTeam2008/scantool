import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// P0.1 纸张/内容包络的确定性单测（不依赖 Vision）。
struct PageContentEnvelopeDetectorTests {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return (-1, -1, -1) }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

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

    @Test("右侧白边内侧的页外条只刷白、不改变尺寸")
    func cleansRightBackgroundStrip() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 560),
            format: format
        )
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
            UIColor(red: 0.55, green: 0.18, blue: 0.20, alpha: 1).setFill()
            context.fill(CGRect(x: 382, y: 0, width: 10, height: 560))
            UIColor.black.setFill()
            context.fill(CGRect(x: 30, y: 40, width: 300, height: 20))
        }
        let cg = try #require(image.cgImage)
        let cleaned = try #require(PageEdgeCleaner.cleanedBackground(in: cg))
        #expect(cleaned.width == cg.width)
        #expect(cleaned.height == cg.height)
        let right = pixel(cleaned, x: 395, y: 100)
        #expect(right.0 > 245 && right.1 > 245 && right.2 > 245)
        let ink = pixel(cleaned, x: 100, y: 50)
        #expect(ink.0 < 50 && ink.1 < 50 && ink.2 < 50)
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/tmp-edge-synthetic.jpg")
        try #require(UIImage(cgImage: cleaned).jpegData(compressionQuality: 0.95))
            .write(to: out)
    }

    @Test("粉色封面：页面内粉带保持，只有右缘木纹被刷白")
    func preservesPinkCoverInterior() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 560),
            format: format
        )
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
            // 粉色封面本体：顶部 7% 也在页面内，过去会被全宽红色清理洗白。
            UIColor(red: 0.84, green: 0.28, blue: 0.48, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 40, width: 350, height: 480))
            // 页面右侧白边 + 页外木纹；清理必须只动木纹。
            UIColor(red: 0.55, green: 0.18, blue: 0.20, alpha: 1).setFill()
            context.fill(CGRect(x: 382, y: 0, width: 10, height: 560))
            UIColor.black.setFill()
            context.fill(CGRect(x: 60, y: 100, width: 250, height: 20))
        }
        let cg = try #require(image.cgImage)
        let cleaned = try #require(PageEdgeCleaner.cleanedBackground(in: cg))
        let topPink = pixel(cleaned, x: 200, y: 55)
        #expect(topPink.0 > 120 && topPink.1 < 140 && topPink.2 < 160,
                "页面内粉色不得被顶部红色清理刷白，实际 \(topPink)")
        let midPink = pixel(cleaned, x: 200, y: 300)
        #expect(midPink.0 > 120 && midPink.1 < 140 && midPink.2 < 160,
                "页面内部粉色必须保持")
        let wood = pixel(cleaned, x: 387, y: 100)
        #expect(wood.0 > 245 && wood.1 > 245 && wood.2 > 245,
                "页外右上木纹仍应被清掉，实际 \(wood)")
    }

    @Test("真机 round1-3 右侧页外条可被识别")
    func detectsDeviceRound13RightStrip() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appending(
            path: "docs/media/optimize/round1-3-2C35B62C-D12F-4E13-A2A3-7AA9702F552F-rendered.jpg"
        )
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        let cleaned = try #require(PageEdgeCleaner.cleanedBackground(in: image))
        #expect(cleaned.width == image.width)
        #expect(cleaned.height == image.height)
        let rightTop = pixel(cleaned, x: cleaned.width - 2, y: 20)
        #expect(rightTop.0 > 245 && rightTop.1 > 245 && rightTop.2 > 245)
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/device-round1-3/edge-cleaned.jpg")
        try #require(UIImage(cgImage: cleaned).jpegData(compressionQuality: 0.95))
            .write(to: out)
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
