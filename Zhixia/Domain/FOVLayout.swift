import CoreGraphics
import Foundation

/// 视频↔照片视野的归一化四边形换算（plan D2）——纯几何、无状态、可逆。
///
/// ## 规则：同传感器中心裁切
/// 同一传感器的任何中心裁切在竖屏下都保留**纵向全视野**（长轴共享），只裁短轴：
/// 竖屏宽高比（宽÷高）更小的空间，其横向视野是宽高比更大者的**中心子区间**。
///
/// 例（模拟器组合）：竖屏 16:9 视频（0.5625）的 x∈[0,1] 恰好对应 4:3 照片（0.75）
/// 的 x∈[0.125, 0.875] —— 即「视频套照片，横向中心 75% 跨度」，y 恒等。
/// 真机 4:3 = 4:3 时退化为恒等。数学推导：16:9 裁切保留传感器全宽，旋转后即竖屏全高。
///
/// FR-011：全部空间换算收敛到本模块（唯一的换算实现），任意宽高比组合可逆。
enum FOVLayout {
    /// 把 `quad` 从竖屏宽高比 `fromAspect` 的归一化空间换算到 `toAspect` 的空间。
    ///
    /// - 宽高比相等 → 原样返回（恒等，零成本）。
    /// - 输入非法（≤0 / 非有限）→ 原样返回（调用方不崩溃、不变形）。
    /// - `fromAspect < toAspect`（源更窄长，如视频→照片）：x ↦ `inset + x × scale`，y 不变。
    /// - `fromAspect > toAspect`（源更宽，如照片→视频的逆运算）：x ↦ `(x − inset) / scale`，y 不变。
    static func convert(quad: Quad, fromAspect: Double, toAspect: Double) -> Quad {
        guard fromAspect.isFinite, toAspect.isFinite,
              fromAspect > 0, toAspect > 0
        else {
            return quad
        }
        guard fromAspect != toAspect else { return quad }

        if fromAspect < toAspect {
            // 源空间更窄长：源 x∈[0,1] 落在目标空间的中心子区间 [inset, 1−inset]。
            let scale = fromAspect / toAspect
            let inset = (1 - scale) / 2
            return Quad(
                topLeft: CGPoint(x: inset + quad.topLeft.x * scale, y: quad.topLeft.y),
                topRight: CGPoint(x: inset + quad.topRight.x * scale, y: quad.topRight.y),
                bottomRight: CGPoint(x: inset + quad.bottomRight.x * scale, y: quad.bottomRight.y),
                bottomLeft: CGPoint(x: inset + quad.bottomLeft.x * scale, y: quad.bottomLeft.y)
            )
        }

        // 源空间更宽：目标空间的 x∈[0,1] 对应源空间的中心子区间 [inset, 1−inset]。
        let scale = toAspect / fromAspect
        let inset = (1 - scale) / 2
        return Quad(
            topLeft: CGPoint(x: (quad.topLeft.x - inset) / scale, y: quad.topLeft.y),
            topRight: CGPoint(x: (quad.topRight.x - inset) / scale, y: quad.topRight.y),
            bottomRight: CGPoint(x: (quad.bottomRight.x - inset) / scale, y: quad.bottomRight.y),
            bottomLeft: CGPoint(x: (quad.bottomLeft.x - inset) / scale, y: quad.bottomLeft.y)
        )
    }
}
