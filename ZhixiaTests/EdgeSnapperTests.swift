import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

/// US6（plan D7，FR-014）：still 检出框普遍内缩 1~3%（圆角/低对比度），
/// `EdgeSnapper` 沿四边外法线把框吸附回真实亮度边缘；四项校验任一失败原样返回。
struct EdgeSnapperTests {
    @Test("Inward-shifted quad snaps back onto the true block edges")
    func snapRecoversTrueEdge() {
        // 亮块 x∈[0.2, 0.8]、y∈[0.15, 0.85]（归一化·原点左上）。
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))

        // 内缩 2% 的检出框（模拟 Vision 的典型内缩缺陷）。
        let inset = rectQuad(0.22, 0.17, 0.78, 0.83)
        let snapped = EdgeSnapper.snap(quad: inset, image: image, maxShiftRatio: 0.05)

        // 误差 ≤ 短边 2%（短边 0.56 → 0.0112）。
        let tolerance: CGFloat = 0.02 * 0.56
        #expect(abs(snapped.topLeft.x - 0.2) <= tolerance)
        #expect(abs(snapped.topLeft.y - 0.15) <= tolerance)
        #expect(abs(snapped.topRight.x - 0.8) <= tolerance)
        #expect(abs(snapped.topRight.y - 0.15) <= tolerance)
        #expect(abs(snapped.bottomRight.x - 0.8) <= tolerance)
        #expect(abs(snapped.bottomRight.y - 0.85) <= tolerance)
        #expect(abs(snapped.bottomLeft.x - 0.2) <= tolerance)
        #expect(abs(snapped.bottomLeft.y - 0.85) <= tolerance)
    }

    @Test("Uniform image has no gradient and keeps the original quad")
    func uniformImageKeepsQuad() {
        let image = SnapperImages.uniformImage()
        let quad = rectQuad(0.25, 0.2, 0.75, 0.8)

        // 同色无梯度：不产生任何位移。
        #expect(EdgeSnapper.snap(quad: quad, image: image, maxShiftRatio: 0.05) == quad)
    }

    @Test("True edge beyond the shift limit keeps the original quad")
    func beyondMaxShiftKeepsQuad() {
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))

        // 内缩 8%，maxShift = 0.03 × 短边 0.44 ≈ 1.3% < 8% → 搜索够不着真实边缘。
        let far = rectQuad(0.28, 0.23, 0.72, 0.77)
        #expect(EdgeSnapper.snap(quad: far, image: image, maxShiftRatio: 0.03) == far)
    }

    @Test("Non-convex result is rejected and keeps the original quad")
    func nonConvexResultKeepsQuad() {
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))

        // 凹四边形（BR 顶点内凹）：外法线方向不可靠，凸性校验直接拒绝。
        let concave = Quad(
            topLeft: CGPoint(x: 0.25, y: 0.2),
            topRight: CGPoint(x: 0.75, y: 0.2),
            bottomRight: CGPoint(x: 0.5, y: 0.45),
            bottomLeft: CGPoint(x: 0.25, y: 0.8)
        )
        #expect(EdgeSnapper.snap(quad: concave, image: image, maxShiftRatio: 0.05) == concave)
    }

    @Test("Area change beyond the limit keeps the original quad")
    func areaChangeBeyondLimitKeepsQuad() {
        // 中心亮块 0.25×0.25，小框 0.2×0.2（每边间隙 2.5%，maxShift 内可达）。
        let image = SnapperImages.blockImage(block: CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25))
        let small = rectQuad(0.4, 0.4, 0.6, 0.6)

        // 若无面积校验，吸附会把框扩到 0.25×0.25（面积 +56% > 20% 上限）→ 必须拒绝。
        #expect(EdgeSnapper.snap(quad: small, image: image, maxShiftRatio: 0.15) == small)
    }

    // MARK: - Fixtures

    private func rectQuad(
        _ minX: CGFloat,
        _ minY: CGFloat,
        _ maxX: CGFloat,
        _ maxY: CGFloat
    ) -> Quad {
        Quad(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomRight: CGPoint(x: maxX, y: maxY),
            bottomLeft: CGPoint(x: minX, y: maxY)
        )
    }
}

/// 合成测试图：暗背景 + 亮块（EdgeSnapper 靠亮度梯度找真实边缘）。
private enum SnapperImages {
    static func blockImage(
        width: Int = 300,
        height: Int = 400,
        block: CGRect,
        background: Double = 0.1,
        foreground: Double = 0.95
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // block 为「原点左上」的归一化矩形；CGContext 原点在左下 → y 翻转。
        let pixelRect = CGRect(
            x: block.minX * CGFloat(width),
            y: (1 - block.maxY) * CGFloat(height),
            width: block.width * CGFloat(width),
            height: block.height * CGFloat(height)
        )
        context.setFillColor(CGColor(red: foreground, green: foreground, blue: foreground, alpha: 1))
        context.fill(pixelRect)
        return context.makeImage()!
    }

    static func uniformImage(value: Double = 0.6) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 300,
            height: 400,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        return context.makeImage()!
    }
}
