import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// 亮缝（gutter）模型（CF-T005 / 视频 8 回归）。
///
/// 真实摊开书的中缝不一定是暗谷：白内边距更常见，`analyzeSpine` 的
/// 「两侧亮、中间暗」判据会直接落空。这里钉住亮缝模型的互补性：
/// - 两个文字块之间的亮空白带 → 可拆；
/// - 暗书脊（书脊阴影）→ 不抢暗谷模型的活；
/// - 单页/无空白带 → 不硬拆；
/// - 细反光/印刷竖线不算缝。
struct SpreadSplitterGutterTests {
    private func image(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) -> CGImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let ui = renderer.image { context in
            draw(context.cgContext)
        }
        return ui.cgImage!
    }

    private func paper(_ context: CGContext, width: Int, height: Int) {
        UIColor(white: 0.94, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func textLines(
        _ context: CGContext,
        x: CGFloat,
        width: CGFloat,
        height: Int
    ) {
        UIColor(white: 0.18, alpha: 1).setFill()
        for y in stride(from: 24, to: height - 24, by: 18) {
            context.fill(CGRect(x: x, y: CGFloat(y), width: width, height: 5))
        }
    }

    @Test("两个文字块之间的亮空白带 → 亮缝定位在带中心")
    func findsBrightGutterBetweenTextBlocks() throws {
        let image = image(width: 600, height: 400) { context in
            paper(context, width: 600, height: 400)
            textLines(context, x: 60, width: 210, height: 400)
            textLines(context, x: 330, width: 210, height: 400)
        }
        let gutter = try #require(SpreadSplitter.analyzeGutter(inRectified: image))
        #expect(abs(gutter.u - 0.5) < 0.06, "亮缝中心应在 0.5 附近，实际 \(gutter.u)")
        #expect(gutter.width >= 0.04, "空白带宽度应被量到，实际 \(gutter.width)")
        #expect(gutter.confidence >= 0.5, "清晰亮缝应达到可自动落地置信度")
    }

    @Test("暗书脊不是亮缝：两个模型互补，不抢暗谷的活")
    func darkSpineIsNotGutter() {
        let image = image(width: 400, height: 300) { context in
            paper(context, width: 400, height: 300)
            UIColor(white: 0.25, alpha: 1).setFill()
            context.fill(CGRect(x: 192, y: 0, width: 16, height: 300))
        }
        let gutter = SpreadSplitter.analyzeGutter(inRectified: image)
        #expect(gutter == nil || gutter!.confidence < 0.5, "暗谷不应被亮缝模型重复识别")
    }

    @Test("单页正文没有贯穿空白带 → 不返回亮缝")
    func singleColumnPageHasNoGutter() {
        let image = image(width: 300, height: 400) { context in
            paper(context, width: 300, height: 400)
            textLines(context, x: 30, width: 240, height: 400)
        }
        #expect(SpreadSplitter.analyzeGutter(inRectified: image) == nil)
    }

    @Test("页内栏间距偏离中线 → 不当作书脊（视频 9 的 0.759 误拆）")
    func gutterOutsideCenterBandIsIgnored() {
        let image = image(width: 600, height: 400) { context in
            paper(context, width: 600, height: 400)
            // 正文块一直排到 0.72；0.72~0.82 是一条亮栏缝；右侧再起一栏。
            textLines(context, x: 40, width: 390, height: 400)
            textLines(context, x: 492, width: 88, height: 400)
        }
        #expect(
            SpreadSplitter.analyzeGutter(inRectified: image) == nil,
            "栏缝在 [0.30,0.70] 之外，不得当成书脊"
        )
    }

    @Test("1px 反光细线不算亮缝（带宽下限）")
    func narrowReflectionIsNotGutter() {
        let image = image(width: 600, height: 400) { context in
            paper(context, width: 600, height: 400)
            textLines(context, x: 60, width: 480, height: 400)
            UIColor(white: 0.99, alpha: 1).setFill()
            context.fill(CGRect(x: 299, y: 0, width: 2, height: 400))
        }
        let gutter = SpreadSplitter.analyzeGutter(inRectified: image)
        #expect(gutter == nil || gutter!.width < 0.02 || gutter!.confidence < 0.5)
    }
}
