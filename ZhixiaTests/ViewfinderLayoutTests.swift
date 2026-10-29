import CoreGraphics
import Testing

@testable import Zhixia

/// CF-T010（spec FR-012）：取景窗必须保持运行时视频宽高比——容器比例
/// 与视频帧一致时，`OverlaySpaceMap` 的 aspectFill 放置恰好铺满容器
///（fill == fit），取景域 == 成片域。
struct ViewfinderLayoutTests {
    @Test("4:3 视频在 390 宽的屏上宽度优先：390×520")
    func widthLimited4x3() {
        let size = ViewfinderLayout.fittedSize(
            in: CGSize(width: 390, height: 763),
            videoAspect: 0.75
        )
        #expect(abs(size.width - 390) < 1e-9)
        #expect(abs(size.height - 520) < 1e-9)
    }

    @Test("可用高度不足时按高度反推宽度，保持 4:3")
    func heightLimited4x3() {
        let size = ViewfinderLayout.fittedSize(
            in: CGSize(width: 500, height: 400),
            videoAspect: 0.75
        )
        #expect(abs(size.width - 300) < 1e-9)
        #expect(abs(size.height - 400) < 1e-9)
    }

    @Test("16:9 视频按 9:16 反推（不被屏宽拉伸）")
    func widthLimited16x9() {
        let size = ViewfinderLayout.fittedSize(
            in: CGSize(width: 390, height: 844),
            videoAspect: 0.5625
        )
        #expect(abs(size.width - 390) < 1e-9)
        #expect(abs(size.height - 693.333333) < 1e-6)
    }

    @Test("退化输入返回 zero（不崩溃、不画变形取景窗）")
    func degenerateInputs() {
        #expect(
            ViewfinderLayout.fittedSize(in: CGSize(width: 0, height: 800), videoAspect: 0.75)
                == .zero
        )
        #expect(
            ViewfinderLayout.fittedSize(in: CGSize(width: 390, height: 0), videoAspect: 0.75)
                == .zero
        )
        #expect(
            ViewfinderLayout.fittedSize(in: CGSize(width: 390, height: 844), videoAspect: 0)
                == .zero
        )
        #expect(
            ViewfinderLayout.fittedSize(in: CGSize(width: 390, height: 844), videoAspect: .nan)
                == .zero
        )
    }

    @Test("宽高比保持不变（fill == fit 的前提）")
    func aspectPreserved() {
        let size = ViewfinderLayout.fittedSize(
            in: CGSize(width: 375, height: 501),
            videoAspect: 0.75
        )
        #expect(size.width > 0 && size.height > 0)
        #expect(abs(Double(size.width / size.height) - 0.75) < 1e-9)
    }
}
