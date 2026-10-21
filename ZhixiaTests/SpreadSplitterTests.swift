import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

/// 书页拆分（spec/scan-enhance FR-002）纯函数单测。
struct SpreadSplitterTests {
    @Test("Spine valley is found near the centre of a spread")
    func spineFoundOnSyntheticSpread() throws {
        let image = Self.spreadImage()
        let spine = try #require(SpreadSplitter.spine(inRectified: image))
        #expect(abs(spine.u - 0.5) < 0.06, "书脊应在中央，实际 u=\(spine.u)")
        #expect(spine.prominence >= SpreadSplitter.prominenceThreshold)
    }

    @Test("A uniform page has no spine")
    func noSpineOnUniformPage() {
        let image = Self.uniformImage(value: 0.9)
        #expect(SpreadSplitter.spine(inRectified: image) == nil)
    }

    @Test("Splitting at the spine produces the right page starting at the valley")
    func splitRightPageStartsAtSpine() {
        let quad = Self.wideQuad
        let (left, right) = SpreadSplitter.split(quad, at: 0.5)
        // 右页左缘 = 顶边中点（宽 0.5 处）。
        #expect(abs(right.topLeft.x - quad.topLeft.x - (quad.topRight.x - quad.topLeft.x) * 0.5) < 1e-9)
        #expect(abs(right.bottomLeft.x - quad.bottomLeft.x - (quad.bottomRight.x - quad.bottomLeft.x) * 0.5) < 1e-9)
        // 两页面积之和 ≈ 整书面积。
        #expect(abs((left.area + right.area) - quad.area) < 0.01)
        #expect(abs(left.area - right.area) < 0.02)
    }

    @Test("Pixel aspect distinguishes a spread from a portrait page")
    func pixelAspectRecognizesSpread() {
        let size = CGSize(width: 400, height: 300)
        #expect(SpreadSplitter.pixelAspect(of: Self.wideQuad, imageSize: size) > 1.2)
        let portrait = Quad(
            topLeft: CGPoint(x: 0.3, y: 0.05),
            topRight: CGPoint(x: 0.7, y: 0.05),
            bottomRight: CGPoint(x: 0.7, y: 0.95),
            bottomLeft: CGPoint(x: 0.3, y: 0.95)
        )
        // 0.4×400 / 0.9×300 = 160/270 ≈ 0.59（竖版单页，诊断值）
        #expect(SpreadSplitter.pixelAspect(of: portrait, imageSize: size) < 1.0)
    }

    @Test("A dark folded strip on the left is trimmed at the first bright column")
    func leftTrimCutsDarkStrip() throws {
        let image = Self.foldStripImage()
        let trim = try #require(SpreadSplitter.leftFoldTrim(inRectified: image))
        #expect(abs(trim.u - 0.08) < 0.03, "折条右缘≈0.08，实际 \(trim.u)")
        #expect(trim.stripDepth > 0.15, "折条必须显著暗于页面")
    }

    @Test("A bright page/spread without a folded strip is never left-trimmed")
    func noLeftTrimOnBrightContent() {
        #expect(SpreadSplitter.leftFoldTrim(inRectified: Self.uniformImage(value: 0.9)) == nil)
        // 摊开书左页是亮的：左折条模型不得误裁（该场景走书脊暗谷）。
        #expect(SpreadSplitter.leftFoldTrim(inRectified: Self.spreadImage()) == nil)
    }

    // MARK: - Fixtures

    /// 摊开书：400×300，左右亮页 + 中央暗脊（x 0.48..0.52 贯穿全高）。
    private static func spreadImage() -> CGImage {
        let width = 400
        let height = 300
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 20, y: 15, width: 172, height: 270))
        context.fill(CGRect(x: 208, y: 15, width: 172, height: 270))
        context.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 192, y: 0, width: 16, height: 300))
        return context.makeImage()!
    }

    /// 折页书场景 2：左侧 8% 暗折条 + 右侧亮页（400×300）。
    private static func foldStripImage() -> CGImage {
        let width = 400
        let height = 300
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: width - 32, height: height)) // 8%
        return context.makeImage()!
    }

    private static func uniformImage(value: Double) -> CGImage {
        let context = CGContext(
            data: nil, width: 400, height: 300,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context.makeImage()!
    }

    private static let wideQuad = Quad(
        topLeft: CGPoint(x: 0.02, y: 0.05),
        topRight: CGPoint(x: 0.98, y: 0.05),
        bottomRight: CGPoint(x: 0.98, y: 0.95),
        bottomLeft: CGPoint(x: 0.02, y: 0.95)
    )
}
