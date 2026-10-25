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

    @Test("A bright folded comic strip is trimmed at its right edge")
    func brightFoldTrimCutsContentStrip() throws {
        let trim = try #require(SpreadSplitter.leftBrightFoldTrim(inRectified: Self.brightFoldStripImage()))
        #expect(abs(trim.u - 0.08) < 0.03, "亮折条右缘≈0.08，实际 \(trim.u)")
        #expect(trim.stripDepth > 0.04)
    }

    @Test("A uniform page or a spread has no bright folded strip")
    func noBrightFoldOnNormalPage() {
        #expect(SpreadSplitter.leftBrightFoldTrim(inRectified: Self.uniformImage(value: 0.9)) == nil)
        #expect(SpreadSplitter.leftBrightFoldTrim(inRectified: Self.spreadImage()) == nil)
    }

    @Test("A narrow bright strip at the page's left edge is trimmed")
    func narrowBrightFoldTrimCutsEdgeStrip() throws {
        let trim = try #require(SpreadSplitter.leftBrightFoldTrim(inRectified: Self.narrowBrightStripImage()))
        #expect(abs(trim.u - 0.015) < 0.02, "窄折条右缘≈0.015，实际 \(trim.u)")
    }

    @Test("Right paper edge stops before a dark wood/background strip")
    func rightPaperEdgeStopsBeforeWood() throws {
        let edge = try #require(SpreadSplitter.rightPaperEdge(inRectified: Self.pageWithWoodImage()))
        #expect(abs(edge - 0.94) < 0.03, "纸面右缘≈0.94，实际 \(edge)")
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

    /// 左缘 1.5% 窄亮折条（真机边缘框已切掉大部分折页）。
    private static func narrowBrightStripImage() -> CGImage {
        let width = 400
        let height = 300
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: height)) // 1.5%
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        for row in stride(from: 0, to: height, by: 50) {
            context.fill(CGRect(x: 0, y: row, width: 6, height: 18))
        }
        return context.makeImage()!
    }

    /// 右侧 6% 深色木桌 + 左侧亮页。
    private static func pageWithWoodImage() -> CGImage {
        let width = 400
        let height = 300
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.25, green: 0.18, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 376, y: 0, width: 24, height: height)) // 94%..100%
        return context.makeImage()!
    }

    /// 亮折页条：左侧 8% 纸面（印着深色漫画格）+ 右侧更亮的正文页。
    private static func brightFoldStripImage() -> CGImage {
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
        context.setFillColor(CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 8, y: 0, width: 24, height: height)) // 2%..8%
        context.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1))
        for row in stride(from: 0, to: height, by: 40) {
            context.fill(CGRect(x: 10, y: row, width: 20, height: 16))
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: width - 32, height: height))
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
