import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

/// US5（plan D9，FR-012）：裁剪画布轮廓改在 aspect-fit 显示矩形内绘制，
/// 与拖角手柄同坐标系——图像宽高比 ≠ 画布宽高比时「所见即所裁」。
struct CropCanvasLayoutTests {
    @Test("Contour quad lands inside the aspect-fit display rect")
    func contourQuadLandsInFittedRect() {
        // 4:3 横图放入竖屏画布：宽受限，垂直方向留黑边。
        let image = CGSize(width: 400, height: 300)
        let canvas = CGSize(width: 390, height: 844)
        let fitted = CropCanvas.fittedRect(for: image, in: canvas)

        // scale = min(390/400, 844/300) = 0.975 → fitted = (0, 275.75, 390, 292.5)。
        #expect(abs(fitted.width - 390) < 1e-9)
        #expect(abs(fitted.height - 292.5) < 1e-9)
        #expect(abs(fitted.minY - 275.75) < 1e-9)

        let quad = centeredQuad
        let mapped = CropCanvas.canvasQuad(quad, in: fitted)

        // 手算期望：轮廓顶点在 fitted 矩形内（旧缺陷是全画布映射，y 会是 211）。
        #expect(approx(mapped.topLeft, CGPoint(x: 97.5, y: 348.875)))
        #expect(approx(mapped.topRight, CGPoint(x: 292.5, y: 348.875)))
        #expect(approx(mapped.bottomRight, CGPoint(x: 292.5, y: 495.125)))
        #expect(approx(mapped.bottomLeft, CGPoint(x: 97.5, y: 495.125)))

        // 轮廓整体落在 fitted 显示矩形内（与手柄同坐标系）。
        let bbox = mapped.boundingRect
        #expect(bbox.minX >= fitted.minX - 1e-9 && bbox.maxX <= fitted.maxX + 1e-9)
        #expect(bbox.minY >= fitted.minY - 1e-9 && bbox.maxY <= fitted.maxY + 1e-9)
    }

    @Test("Equal aspect maps without letterbox offset")
    func equalAspectIsOffsetFree() {
        let size = CGSize(width: 390, height: 844)
        let fitted = CropCanvas.fittedRect(for: size, in: size)
        #expect(fitted.origin == .zero)
        #expect(fitted.size == size)

        // 宽高比相等：映射退化为画布比例缩放（无信箱偏移）。
        let mapped = CropCanvas.canvasQuad(centeredQuad, in: fitted)
        #expect(approx(mapped.topLeft, CGPoint(x: 97.5, y: 211)))
        #expect(approx(mapped.bottomRight, CGPoint(x: 292.5, y: 633)))
    }

    @Test("Contour vertices coincide with handle positions")
    func contourMatchesHandlePositions() {
        let image = CGSize(width: 400, height: 300)
        let canvas = CGSize(width: 390, height: 844)
        let fitted = CropCanvas.fittedRect(for: image, in: canvas)
        let quad = tiltedQuad
        let mapped = CropCanvas.canvasQuad(quad, in: fitted)

        // 轮廓顶点与手柄定位点共用同一映射（canvasPoint）。
        #expect(approx(mapped.topLeft, CropCanvas.canvasPoint(quad.topLeft, in: fitted)))
        #expect(approx(mapped.topRight, CropCanvas.canvasPoint(quad.topRight, in: fitted)))
        #expect(approx(mapped.bottomRight, CropCanvas.canvasPoint(quad.bottomRight, in: fitted)))
        #expect(approx(mapped.bottomLeft, CropCanvas.canvasPoint(quad.bottomLeft, in: fitted)))
    }

    @Test("Drag gesture round-trips through the fitted rect")
    func dragRoundTripsThroughFittedRect() {
        let image = CGSize(width: 400, height: 300)
        let canvas = CGSize(width: 390, height: 844)
        let fitted = CropCanvas.fittedRect(for: image, in: canvas)

        // 手势逆映射（画布点 → 归一化）与轮廓正映射互逆 → 拖动后成片与所见一致。
        let dragged = CGPoint(x: 200, y: 400)
        let normalized = CGPoint(
            x: (dragged.x - fitted.minX) / max(fitted.width, 1),
            y: (dragged.y - fitted.minY) / max(fitted.height, 1)
        )
        #expect(approx(CropCanvas.canvasPoint(normalized, in: fitted), dragged))
    }

    // MARK: - Fixtures

    private var centeredQuad: Quad {
        Quad(
            topLeft: CGPoint(x: 0.25, y: 0.25),
            topRight: CGPoint(x: 0.75, y: 0.25),
            bottomRight: CGPoint(x: 0.75, y: 0.75),
            bottomLeft: CGPoint(x: 0.25, y: 0.75)
        )
    }

    private var tiltedQuad: Quad {
        Quad(
            topLeft: CGPoint(x: 0.12, y: 0.18),
            topRight: CGPoint(x: 0.82, y: 0.14),
            bottomRight: CGPoint(x: 0.88, y: 0.9),
            bottomLeft: CGPoint(x: 0.08, y: 0.84)
        )
    }

    private func approx(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-9) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }
}
