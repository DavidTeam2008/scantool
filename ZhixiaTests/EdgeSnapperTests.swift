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

    // MARK: - 内向相（spec/folded-page-capture，FR-006）

    @Test("Overshot quad beyond the true edge snaps inward onto the block edges")
    func snapPullsOvershotQuadInward() {
        // 折页书左缘形态：检出框**越过**真实边缘 1%（把暗色折痕带/背景
        // 当作页内）——纯外向搜索永远够不着页内的真实边缘，折痕留进成片。
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))

        // 外扩 1% 的检出框（短边 0.62 → maxShift 3.1%，内拉限幅 1.55% ≥ 1%）。
        let overshot = rectQuad(0.19, 0.14, 0.81, 0.86)
        let snapped = EdgeSnapper.snap(quad: overshot, image: image, maxShiftRatio: 0.05)

        // 内拉恢复到真实边缘，误差 ≤ 短边 2%。
        let tolerance: CGFloat = 0.02 * 0.62
        #expect(abs(snapped.topLeft.x - 0.2) <= tolerance)
        #expect(abs(snapped.topLeft.y - 0.15) <= tolerance)
        #expect(abs(snapped.topRight.x - 0.8) <= tolerance)
        #expect(abs(snapped.topRight.y - 0.15) <= tolerance)
        #expect(abs(snapped.bottomRight.x - 0.8) <= tolerance)
        #expect(abs(snapped.bottomRight.y - 0.85) <= tolerance)
        #expect(abs(snapped.bottomLeft.x - 0.2) <= tolerance)
        #expect(abs(snapped.bottomLeft.y - 0.85) <= tolerance)
    }

    @Test("Overshoot beyond the inward shift limit keeps the original quad")
    func beyondInwardLimitKeepsQuad() {
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))

        // 外扩 4%：短边 0.68 → maxShift 3.4%，内拉限幅 1.7% < 4% →
        // 两相都够不着真实边缘，原样返回（宁可不修，不可错修）。
        let far = rectQuad(0.16, 0.11, 0.84, 0.89)
        #expect(EdgeSnapper.snap(quad: far, image: image, maxShiftRatio: 0.05) == far)
    }

    @Test("Inset quad still snaps outward first (inward phase never preempts)")
    func outwardPhaseKeepsPriority() {
        // 既有语义锚点：内缩框的外向相可达真实边缘时，直接外推——内向相
        // 不参与（相位顺序钉死，防止未来改动让内拉抢先收缩有效裁切范围）。
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))
        let inset = rectQuad(0.22, 0.17, 0.78, 0.83)
        let snapped = EdgeSnapper.snap(quad: inset, image: image, maxShiftRatio: 0.05)
        #expect(snapped.topLeft.x <= 0.22, "内缩框必须外推（左缘左移），不得内拉")
        #expect(snapped.topLeft.y <= 0.17)
        #expect(snapped.bottomRight.x >= 0.78, "内缩框必须外推（右缘右移），不得内拉")
        #expect(snapped.bottomRight.y >= 0.83)
    }

    @Test("An edge already on the true edge is not pushed outward (s=0 guard)")
    func edgeOnTrueEdgeStaysPut() {
        // spec/frame-truth FR-004：检出框恰好落在真实块边界上时，外向相
        // 此前会因 guard 跳过 s=0 而至少外推 δ（折脊/阴影场景 1–2%）——
        // s=0 守卫（双线性 G0）必须让该边原样不动；而 1% 外扩用例
        // （snapPullsOvershotQuadInward，G0≈0）仍必须能内拉，证明守卫
        // 不误吞小幅修正。
        let image = SnapperImages.blockImage(block: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7))
        let onEdge = rectQuad(0.2, 0.15, 0.8, 0.85)
        let snapped = EdgeSnapper.snap(quad: onEdge, image: image, maxShiftRatio: 0.05)
        #expect(snapped == onEdge, "边已在真实边缘上：不得外推、不得内拉")
    }

    @Test("Fold crease wins over a stronger fold silhouette (nearest-peak policy)")
    func foldCreaseBeatsSilhouette() {
        // spec/frame-stability：亮度剖面（x 方向）＝背景 0.15 ｜ 折起面 0.95
        // [0.10,0.26] ｜ 折痕阴影 0.45 [0.26,0.30] ｜ 页面 0.95 [0.30,0.80]。
        // 检出框左缘在 0.32（页内）：向外第一个「亮→暗」边是页面/折痕边界
        // （0.95→0.45，梯度 0.5）；更外侧的折脊轮廓（0.95→0.15，梯度 0.8）
        // 更强——「全窗最强梯度」会跳到折脊、把折起来的部分留在框里；
        // 最近峰策略必须停在折痕一侧。
        let image = SnapperImages.foldImage()
        let inset = rectQuad(0.32, 0.18, 0.78, 0.82)
        let snapped = EdgeSnapper.snap(quad: inset, image: image, maxShiftRatio: 0.08)
        #expect(snapped.topLeft.x >= 0.27 && snapped.topLeft.x <= 0.33,
                "左缘必须吸附到折痕（页面边界 ≈0.30），实际 \(snapped.topLeft.x)")
        #expect(snapped.topLeft.x > 0.20, "不得越过折痕吸到折脊轮廓（≈0.10）")
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

    /// spec/frame-stability：折页书亮度剖面——背景 0.15 ｜ 折起面 0.95
    /// [0.10,0.26] ｜ 折痕阴影 0.45 [0.26,0.30] ｜ 页面 0.95 [0.30,0.80]。
    static func foldImage() -> CGImage {
        let width = 300
        let height = 400
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func fill(_ x0: Double, _ x1: Double, _ value: Double) {
            context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            context.fill(CGRect(
                x: x0 * Double(width),
                y: 0.15 * Double(height),
                width: (x1 - x0) * Double(width),
                height: 0.7 * Double(height)
            ))
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fill(0.10, 0.26, 0.95) // 折起面
        fill(0.26, 0.30, 0.45) // 折痕阴影
        fill(0.30, 0.80, 0.95) // 页面
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
