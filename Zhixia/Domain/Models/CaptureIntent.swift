import CoreGraphics
import Foundation

/// 拍摄意图（spec/guided-capture T010 / FR-001 / D1）——引导模式下「要拍哪一页」。
///
/// 意图只影响**引导框的默认位置**（`defaultScreenRect`），不改变任何检测阈值：
/// 用户随时可以拖到别处（用户意图优先，见 spec 边界「用户框内仍包含左页/折痕：
/// 这是用户意图，成片忠实执行」）。
enum CaptureIntent: String, Codable, Sendable, CaseIterable, Hashable {
    /// 右页（折页书主场景的默认意图）。
    case rightPage
    /// 左页。
    case leftPage
    /// 整页（整书/单页）。
    case wholePage

    /// 默认引导框的**屏幕比例**（归一化 x/y 区间，y-down）——`plan.md` D3：
    /// 「默认框按屏幕比例给出（右页 0.50…0.98 / 0.12…0.92 等），再逆映射到照片」。
    ///
    /// 之所以定义在**屏幕**空间：引导框是屏幕上的可见物，屏幕比例才是用户
    /// 看到的东西；照片空间由逆映射（`OverlaySpaceMap.photoQuad`）派生。
    var defaultScreenRect: CGRect {
        switch self {
        case .rightPage:
            return CGRect(x: 0.50, y: 0.12, width: 0.48, height: 0.80)
        case .leftPage:
            return CGRect(x: 0.02, y: 0.12, width: 0.48, height: 0.80)
        case .wholePage:
            return CGRect(x: 0.06, y: 0.08, width: 0.88, height: 0.86)
        }
    }
}