import CoreGraphics
import CoreImage
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// CU-T003：自动模式的页面意图解析（整书拆分 / 单页直通 / 右页左折条）。
struct PageIntentResolverTests {
    private func spreadImage() -> CGImage {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 15, width: 172, height: 270))
            context.fill(CGRect(x: 208, y: 15, width: 172, height: 270))
            UIColor(white: 0.25, alpha: 1).setFill()
            context.fill(CGRect(x: 192, y: 0, width: 16, height: 300))
        }
        return image.cgImage!
    }

    private func pageImage() -> CGImage {
        let size = CGSize(width: 300, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 20, width: 260, height: 360))
        }
        return image.cgImage!
    }

    @Test("整书外框 + 左页意图：按书脊拆出左半页")
    func splitsSpreadForLeftIntent() throws {
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: spread,
            candidates: [spread],
            intent: .leftPage,
            image: spreadImage(),
            ciContext: context
        )
        #expect(result?.source == .spine)
        let left = try #require(result?.quad)
        #expect(left.center.x < 0.5, "左页目标中心应在书脊左侧")
        #expect(left.area < spread.area * 0.75, "目标应是单页面积")
    }

    @Test("整书外框 + 右页意图：按书脊拆出右半页")
    func splitsSpreadForRightIntent() throws {
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: spread,
            candidates: [spread],
            intent: .rightPage,
            image: spreadImage(),
            ciContext: context
        )
        #expect(result?.source == .spine)
        let right = try #require(result?.quad)
        #expect(right.center.x > 0.5, "右页目标中心应在书脊右侧")
        #expect(right.area < spread.area * 0.75, "目标应是单页面积")
    }

    @Test("单页没有书脊时不硬拆：左/右意图都得到整张单页")
    func keepsSinglePageWithoutSpine() {
        let page = Quad(
            topLeft: CGPoint(x: 0.06, y: 0.02),
            topRight: CGPoint(x: 0.94, y: 0.02),
            bottomRight: CGPoint(x: 0.94, y: 0.98),
            bottomLeft: CGPoint(x: 0.06, y: 0.98)
        )
        let context = CIContext()
        for intent in [CaptureIntent.leftPage, .rightPage] {
            let result = PageIntentResolver.resolve(
                selection: page,
                candidates: [page],
                intent: intent,
                image: pageImage(),
                ciContext: context
            )
            #expect(result?.quad == page, "无书脊的单页不得被中心线硬拆（intent=\(intent)）")
        }
    }

    @Test("整书外框在无书脊时返回 nil，调用方回到搜索态而非拿整摊凑数")
    func rejectsUnsplitSpread() {
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let flat = renderer.image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: spread,
            candidates: [spread],
            intent: .rightPage,
            image: flat.cgImage!,
            ciContext: context
        )
        #expect(result == nil, "没有书脊证据时不得硬拆整摊")
    }

    @Test("右页候选带左侧折条时，按左折痕裁掉折条")
    func trimsLeftFoldFromRightPage() {
        let size = CGSize(width: 300, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // 亮折条：折起页仍有内容（不是纯暗带），右侧是完整亮页。
            UIColor(white: 0.62, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 36, height: 400))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 36, y: 0, width: 264, height: 400))
            UIColor(white: 0.18, alpha: 1).setFill()
            for y in stride(from: 20, to: 380, by: 24) {
                context.fill(CGRect(x: 5, y: y, width: 25, height: 4))
            }
        }
        // 归一化宽高比 <0.98，模拟“右页内框但左缘带折条”（不是整书方框）。
        let page = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.02),
            topRight: CGPoint(x: 0.92, y: 0.02),
            bottomRight: CGPoint(x: 0.92, y: 0.98),
            bottomLeft: CGPoint(x: 0.02, y: 0.98)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: page,
            candidates: [page],
            intent: .rightPage,
            image: image.cgImage!,
            ciContext: context
        )
        #expect(result?.source == .leftFoldTrim)
        #expect((result?.quad.topLeft.x ?? 0) > 0.05, "右页左缘应裁到折条右侧")
    }
}
