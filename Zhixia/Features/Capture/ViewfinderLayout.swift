import CoreGraphics
import Foundation

/// 取景窗布局（CF-T010，spec FR-012）——纯函数，无 SwiftUI 依赖。
///
/// ## 为什么需要
/// 视频 11/12 的根因是预览层 `.resizeAspectFill` 把 4:3 视频帧铺满 19.5:9
/// 全屏，只显示帧宽的 **61.6%**（两侧各裁 19.2%），而检测/成片用整帧。
/// 修复不是调映射公式，而是让**取景窗本身的宽高比等于视频帧宽高比**：
/// 容器比例一匹配，`OverlaySpaceMap.videoFramePlacement` 的 aspectFill
/// 放置恰好铺满整个容器（fill == fit），既有映射与测试零改动。
///
/// 本类型只负责「在可用空间里放一个保持视频宽高比的最大矩形」：
/// 宽度优先；高度不够时按高度反推宽度。退化输入返回 `.zero`，调用方
/// 不崩溃、不画变形取景窗。
enum ViewfinderLayout {
    /// 在 `available` 内求保持 `videoAspect` 的取景窗尺寸。
    ///
    /// - Parameters:
    ///   - available: 可用宽高（`width` 为屏宽，`height` 已扣除控制区预算）。
    ///   - videoAspect: 竖屏视频帧宽高比（宽 ÷ 高，实测 4:3 = 0.75）。
    /// - Returns: 宽度优先、超高时高度优先的尺寸；入力退化 → `.zero`。
    static func fittedSize(in available: CGSize, videoAspect: Double) -> CGSize {
        guard available.width > 0, available.height > 0,
              videoAspect.isFinite, videoAspect > 0
        else { return .zero }
        let width = available.width
        let height = width / CGFloat(videoAspect)
        if height <= available.height {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: available.height * CGFloat(videoAspect), height: available.height)
    }
}
