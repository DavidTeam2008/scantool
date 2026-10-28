import SwiftUI
import Testing
@testable import Zhixia

/// US1（spec/overlay-frame-visibility，plan D1/D3，FR-001~004）：取景整框
/// `QuadShape` 的**屏幕点坐标契约**——`path(in:)` 忽略 rect、输出点恒等于
/// 输入点（与 `CornerBracketsShape` 同约定）。
///
/// 回归背景：scan-fidelity T019 起输入的屏幕点曾被当归一化 [0,1]² × rect
/// 缩放（如 x≈195 × 390 ≈ 76,050pt），整框描边、压暗挖孔、idCard 检测框
/// 全部画到屏幕外——真机「四角括号可见、整框从未出现」，且无测试锚点存活
/// 两个周期。本套件以 path 数值断言钉死坐标语义（不依赖快照测试）。
struct EdgeOverlayRenderingTests {
    /// 屏幕点空间的取景整框（`OverlaySpaceMap.screenQuad` 产物形态：
    /// iPhone 13 390×844 屏内、带轻微旋转的非轴对齐四边形；顶点均 > 1，
    /// 结构上即与归一化坐标区分）。
    private static let screenQuad = Quad(
        topLeft: CGPoint(x: 63, y: 212),
        topRight: CGPoint(x: 342, y: 198),
        bottomRight: CGPoint(x: 355, y: 704),
        bottomLeft: CGPoint(x: 48, y: 718)
    )

    /// 全屏 rect（视图铺满 overlay 区域时的典型输入）。
    private static let fullScreenRect = CGRect(x: 0, y: 0, width: 390, height: 844)

    @Test("Path bounding box equals the input quad's bounding box in screen points")
    func pathBoundingBoxMatchesInputQuad() {
        let shape = QuadShape(quad: Self.screenQuad)
        let boundingBox = shape.path(in: Self.fullScreenRect).boundingRect
        let expected = Self.screenQuad.boundingRect

        // 屏幕点契约：输出包围盒 == 输入包围盒（容差 < 0.5pt）。
        // 旧缺陷形态下输入被 ×rect 尺寸缩放（x≈63 → 63×390 ≈ 24,570），
        // 包围盒远超屏外——本断言即为该回归的爆炸锚点。
        #expect(abs(boundingBox.minX - expected.minX) < 0.5)
        #expect(abs(boundingBox.minY - expected.minY) < 0.5)
        #expect(abs(boundingBox.maxX - expected.maxX) < 0.5)
        #expect(abs(boundingBox.maxY - expected.maxY) < 0.5)
    }

    @Test("Path output is independent of the rect argument")
    func pathIsIndependentOfRect() {
        let shape = QuadShape(quad: Self.screenQuad)
        let baseline = Self.renderedPoints(shape, in: Self.fullScreenRect)

        // rect 尺寸/原点变化（含单位 rect 与非原点 rect）：输出点必须恒等——
        // `path(in:)` 不得用 rect 缩放/平移输入。旧缺陷形态下不同 rect 产出
        // 完全不同的路径（单位 rect 时整框塌缩到原点附近）。
        let rects = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 50, width: 200, height: 300)
        ]
        for rect in rects {
            #expect(Self.renderedPoints(shape, in: rect) == baseline)
        }
    }

    @Test("Vertex order stays TL→TR→BR→BL and the loop is closed")
    func vertexOrderIsPreservedAndClosed() {
        let shape = QuadShape(quad: Self.screenQuad)
        var moveCount = 0
        var isClosed = false
        var points: [CGPoint] = []
        shape.path(in: Self.fullScreenRect).forEach { element in
            switch element {
            case .move(let point):
                moveCount += 1
                points.append(point)
            case .line(let point):
                points.append(point)
            case .closeSubpath:
                isClosed = true
            case .quadCurve, .curve:
                break
            }
        }

        // 顶点顺序（输出点 == 输入点，逐点恒等）+ 单一闭合子路径
        //（恰好一次 move、三次 line、一次 close）。
        #expect(points == [
            Self.screenQuad.topLeft,
            Self.screenQuad.topRight,
            Self.screenQuad.bottomRight,
            Self.screenQuad.bottomLeft
        ])
        #expect(moveCount == 1)
        #expect(points.count == 4)
        #expect(isClosed)
    }

    /// 提取 path 的顶点序列（move + line 元素），供恒等/顺序断言。
    private static func renderedPoints(_ shape: QuadShape, in rect: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        shape.path(in: rect).forEach { element in
            switch element {
            case .move(let point), .line(let point):
                points.append(point)
            case .closeSubpath, .quadCurve, .curve:
                break
            }
        }
        return points
    }
}

/// CF-T004：左/右页目标必须是实线主框，整摊包络只是虚线上下文。
/// 该解析是 `EdgeOverlayView` 的渲染输入，钉住它即可防止“只画包络、
/// 目标页四角永远不出现”的回归。
struct CaptureOverlayQuadsTests {
    private static let envelope = Quad(
        topLeft: CGPoint(x: 10, y: 100),
        topRight: CGPoint(x: 380, y: 100),
        bottomRight: CGPoint(x: 380, y: 740),
        bottomLeft: CGPoint(x: 10, y: 740)
    )

    private static let leftPage = Quad(
        topLeft: CGPoint(x: 10, y: 100),
        topRight: CGPoint(x: 195, y: 100),
        bottomRight: CGPoint(x: 195, y: 740),
        bottomLeft: CGPoint(x: 10, y: 740)
    )

    @Test("目标页优先作为主框，包络降为上下文")
    func targetWinsOverEnvelope() {
        let resolved = CaptureOverlayQuads.resolve(
            envelope: Self.envelope,
            target: Self.leftPage
        )
        #expect(resolved.primary == Self.leftPage)
        #expect(resolved.context == Self.envelope)
        // 左页右侧两角落在书脊上（x≈195），不随包络右缘（x=380）出屏。
        #expect(resolved.primary?.topRight.x == 195)
        #expect(resolved.primary?.bottomRight.x == 195)
    }

    @Test("没有目标页时包络就是主框；目标与包络重合时不画第二框")
    func withoutTargetOnlyEnvelope() {
        let onlyEnvelope = CaptureOverlayQuads.resolve(envelope: Self.envelope, target: nil)
        #expect(onlyEnvelope.primary == Self.envelope)
        #expect(onlyEnvelope.context == nil)

        let same = CaptureOverlayQuads.resolve(envelope: Self.envelope, target: Self.envelope)
        #expect(same.primary == Self.envelope)
        #expect(same.context == nil)
    }
}
