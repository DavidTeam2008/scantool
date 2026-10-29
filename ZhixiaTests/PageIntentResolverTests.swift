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

    @Test("显示包络优先选整摊，而不是页面内的小候选")
    func envelopePrefersSpread() {
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        let page = Quad(
            topLeft: CGPoint(x: 0.50, y: 0.08),
            topRight: CGPoint(x: 0.96, y: 0.08),
            bottomRight: CGPoint(x: 0.96, y: 0.92),
            bottomLeft: CGPoint(x: 0.50, y: 0.92)
        )
        let envelope = PageIntentResolver.envelope(
            selection: page,
            candidates: [page, spread]
        )
        #expect(envelope == spread)
        #expect(PageIntentResolver.envelope(selection: nil, candidates: []) == nil)
    }

    @Test("整幅/贴边画面外框不是包络：不得回退 fullImage")
    func envelopeRejectsScreenEdgeFrames() {
        #expect(
            PageIntentResolver.envelope(selection: .fullImage, candidates: [.fullImage]) == nil,
            "整幅外框不是页面，必须回到搜索态而不是画贴屏假框"
        )
        let edge = Quad(
            topLeft: CGPoint(x: 0, y: 0.01),
            topRight: CGPoint(x: 1, y: 0.01),
            bottomRight: CGPoint(x: 1, y: 0.99),
            bottomLeft: CGPoint(x: 0, y: 0.99)
        )
        #expect(PageIntentResolver.envelope(selection: edge, candidates: [edge]) == nil)
        // 真实整摊（左右留边、上下留边）不受影响。
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        #expect(PageIntentResolver.envelope(selection: spread, candidates: [spread]) == spread)
    }

    @Test("整幅候选不得被书脊拆成半屏")
    func resolveRejectsScreenEdgeFrame() {
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: .fullImage,
            candidates: [.fullImage],
            intent: .rightPage,
            image: spreadImage(),
            ciContext: context
        )
        #expect(result == nil, "整幅画面里的暗带不是书脊，不能拆成半屏")
    }

    private func flatImage() -> CGImage {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.cgImage!
    }

    @Test("右页意图：页内竖条候选被宽高比下界拒绝，回落到书脊拆出的整页")
    func rejectsNarrowColumnCandidate() throws {
        let spread = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.04),
            topRight: CGPoint(x: 0.98, y: 0.04),
            bottomRight: CGPoint(x: 0.98, y: 0.96),
            bottomLeft: CGPoint(x: 0.02, y: 0.96)
        )
        // 右页栏间距的竖条：宽 0.19、高 0.90，面积 0.171，但宽高比 0.21。
        let column = Quad(
            topLeft: CGPoint(x: 0.80, y: 0.05),
            topRight: CGPoint(x: 0.99, y: 0.05),
            bottomRight: CGPoint(x: 0.99, y: 0.95),
            bottomLeft: CGPoint(x: 0.80, y: 0.95)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: column,
            candidates: [column, spread],
            intent: .rightPage,
            image: spreadImage(),
            ciContext: context
        )
        let target = try #require(result?.quad)
        #expect(target != column, "窄竖条不是页面目标")
        #expect(target.center.x > 0.5, "应回落到书脊右侧的整页")
    }

    @Test("包络外的画面边缘矩形不得成为目标页")
    func rejectsCandidateOutsideEnvelope() {
        let spread = Quad(
            topLeft: CGPoint(x: 0.08, y: 0.08),
            topRight: CGPoint(x: 0.78, y: 0.08),
            bottomRight: CGPoint(x: 0.78, y: 0.92),
            bottomLeft: CGPoint(x: 0.08, y: 0.92)
        )
        // 与包络右侧重叠、但明显伸出包络：画面边缘/桌面矩形。
        let edge = Quad(
            topLeft: CGPoint(x: 0.70, y: 0.10),
            topRight: CGPoint(x: 0.99, y: 0.10),
            bottomRight: CGPoint(x: 0.99, y: 0.68),
            bottomLeft: CGPoint(x: 0.70, y: 0.68)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: edge,
            candidates: [edge, spread],
            intent: .rightPage,
            image: flatImage(),
            ciContext: context
        )
        #expect(result == nil, "画面边缘矩形不是页面，平图上无书脊可拆 → nil")
    }

    @Test("目标在包络中心错误一侧 → 拒绝（右页意图不能给左半页）")
    func rejectsWrongSideTarget() {
        let spread = Quad(
            topLeft: CGPoint(x: 0.20, y: 0.10),
            topRight: CGPoint(x: 1.00, y: 0.10),
            bottomRight: CGPoint(x: 1.00, y: 0.90),
            bottomLeft: CGPoint(x: 0.20, y: 0.90)
        )
        // 中心 0.58 在 0.45 的 right 侧阈值内，但仍在包络中心 0.60 左侧。
        let page = Quad(
            topLeft: CGPoint(x: 0.40, y: 0.10),
            topRight: CGPoint(x: 0.76, y: 0.10),
            bottomRight: CGPoint(x: 0.76, y: 0.70),
            bottomLeft: CGPoint(x: 0.40, y: 0.70)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: page,
            candidates: [page, spread],
            intent: .rightPage,
            image: flatImage(),
            ciContext: context
        )
        #expect(result == nil, "目标必须落在包络中心的意图侧")
    }

    @Test("视频 10：大场景矩形 + 左右页候选 → 页对包络，目标选干净页")
    func pagePairEnvelopeAndTargets() {
        // 设备日志 23:04:23：整摊包络把背景墙包进来，y 到 0.05；
        // 池里另有左页/右页两个干净矩形。
        let giant = Quad(
            topLeft: CGPoint(x: 0.1592, y: 0.0547),
            topRight: CGPoint(x: 0.8408, y: 0.0469),
            bottomRight: CGPoint(x: 0.8408, y: 0.7812),
            bottomLeft: CGPoint(x: 0.1592, y: 0.7227)
        )
        let left = Quad(
            topLeft: CGPoint(x: 0.1592, y: 0.3438),
            topRight: CGPoint(x: 0.3490, y: 0.3438),
            bottomRight: CGPoint(x: 0.3490, y: 0.7200),
            bottomLeft: CGPoint(x: 0.1592, y: 0.7200)
        )
        let right = Quad(
            topLeft: CGPoint(x: 0.3740, y: 0.3200),
            topRight: CGPoint(x: 0.7850, y: 0.3200),
            bottomRight: CGPoint(x: 0.7850, y: 0.7300),
            bottomLeft: CGPoint(x: 0.3740, y: 0.7300)
        )
        let pool = [giant, left, right]
        let envelope = PageIntentResolver.envelope(selection: giant, candidates: pool)
        #expect(envelope != giant, "包络不能选到“墙 + 书”的大矩形")
        #expect(envelope?.topLeft == left.topLeft, "页对包络左缘取左页左缘")
        #expect(envelope?.topRight == right.topRight, "页对包络右缘取右页右缘")

        let context = CIContext()
        // 右页候选是整页（0.168 ≥ 包络半页 0.123 的 85%）→ 直接用；
        // 左页候选只有 0.071（页内左栏）→ 留给整摊拆分，不能切掉左页右栏。
        let rightResult = PageIntentResolver.resolve(
            selection: giant,
            candidates: pool,
            intent: .rightPage,
            image: spreadImage(),
            ciContext: context
        )
        #expect(rightResult?.quad == right, "右页应直接用池里的整页候选")

        let leftResult = PageIntentResolver.resolve(
            selection: giant,
            candidates: pool,
            intent: .leftPage,
            image: spreadImage(),
            ciContext: context
        )
        let leftTarget = try? #require(leftResult?.quad)
        #expect(leftTarget?.topLeft == left.topLeft, "左页左缘取左页候选")
        #expect(
            (leftTarget?.topRight.x ?? 0) > 0.34,
            "左页目标不能是 0.159~0.349 的页内左栏；应从整摊拆分到书脊"
        )
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

    /// 视频 8 左页场景的合成版：整摊比预览宽，右页被裁到屏幕外；
    /// 中缝是一条**亮**的文字间隙（没有暗谷）。
    private func clippedSpreadImage() -> CGImage {
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.18, alpha: 1).setFill()
            for y in stride(from: 24, to: 376, by: 18) {
                // 左页文字 0.15~0.64，右页文字 0.68~0.95，中缝 0.64~0.68 是亮空白带。
                context.fill(CGRect(x: 90, y: y, width: 294, height: 5))
                context.fill(CGRect(x: 408, y: y, width: 162, height: 5))
            }
        }
        return image.cgImage!
    }

    @Test("被屏幕裁掉的整摊 + 亮缝：左页意图仍能拆出左页（视频 8 回归）")
    func splitsClippedSpreadWithBrightGutter() throws {
        // 包络被预览右缘裁掉：面积 0.18 < isSpreadLike 的 0.20，中心 0.655
        // 偏右（右页在屏幕外）——正是视频 8 左页的几何。
        let clipped = Quad(
            topLeft: CGPoint(x: 0.43, y: 0.10),
            topRight: CGPoint(x: 0.88, y: 0.10),
            bottomRight: CGPoint(x: 0.88, y: 0.50),
            bottomLeft: CGPoint(x: 0.43, y: 0.50)
        )
        let context = CIContext()
        let result = PageIntentResolver.resolve(
            selection: clipped,
            candidates: [clipped],
            intent: .leftPage,
            image: clippedSpreadImage(),
            ciContext: context
        )
        #expect(result?.source == .gutter, "暗谷找不到时应由亮缝模型接管")
        let left = try #require(result?.quad)
        #expect(left.center.x < clipped.center.x)
        #expect(left.topRight.x > 0.60 && left.topRight.x < 0.72, "左页右缘应落在亮缝")
        #expect(left.area < clipped.area * 0.8)
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
