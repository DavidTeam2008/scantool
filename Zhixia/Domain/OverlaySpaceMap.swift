import CoreGraphics
import Foundation

/// 照片空间 → 屏幕坐标的解析式映射（spec/scan-fidelity T004 / FR-007）。
///
/// ## 背景（为什么要解析式）
/// 旧链路把 overlay 映射锚在运行时探针上（`layerRectConverted` 全帧探针回调，
/// `CameraPreviewBinder.overlayTransform`）：探针一旦失效（surface 尺寸为 0 /
/// 布局未就绪 / 回调丢帧），映射退化为恒等，边框系统性偏窄甚至不可见。
/// 本模块用**两步解析合成**替代探针锚定：
///
/// 1. 照片 → 视频：`FOVLayout.convert`（同传感器中心裁切规则，逆换算可逆）；
/// 2. 视频 → 屏幕：`.resizeAspectFill` 的解析放置（`videoFramePlacement`）。
///
/// ## 坐标约定（FR-011：全链 y-down 不翻转）
/// - 入参 `photoQuad`：照片归一化空间 [0,1]，y-down（原点左上，与 `Quad.fullImage` 一致）；
/// - 中间：视频归一化空间 [0,1]，y-down；
/// - 出参：屏幕点空间（`viewSize` 像素），y-down。
/// 两步换算都只做 x/y 的仿射缩放平移，**任何一步都不翻转 y**。
///
/// 纯函数、无状态、无 I/O；退化输入（aspect ≤ 0 / 非有限 / viewSize 退化）原样
/// 返回（与 `FOVLayout` 的容错契约一致：调用方不崩溃、不变形）。
enum OverlaySpaceMap {
    /// 照片归一化四边形 → 屏幕点四边形（照片 → 视频 → 屏幕两步合成）。
    ///
    /// 复合语义注意：这**不是**「照片直接 aspectFill 进 viewSize」——照片先落到
    /// 视频视野（可能出界：照片比视频视野宽时，照片 x∈[0,1] 映到视频 x 超出 [0,1]），
    /// 再随视频帧 aspectFill 进屏幕（超出部分被裁掉）。两者只在视频放置为高度主导
    /// 时数值等价；测试断言必须锚复合语义（spec/scan-fidelity T023）。
    static func screenQuad(fromPhotoQuad photoQuad: Quad, geometry: CaptureGeometry, viewSize: CGSize) -> Quad {
        guard geometry.videoAspect.isFinite, geometry.videoAspect > 0,
              geometry.photoAspect.isFinite, geometry.photoAspect > 0,
              viewSize.width > 0, viewSize.height > 0
        else {
            return photoQuad
        }
        // 照片空间 → 视频空间（中心裁切逆换算；纵轴恒等）
        let videoQuad = FOVLayout.convert(
            quad: photoQuad,
            fromAspect: geometry.photoAspect,
            toAspect: geometry.videoAspect
        )
        // 视频空间 → 屏幕点空间（aspectFill 放置）
        let placement = videoFramePlacement(geometry: geometry, viewSize: viewSize)
        func toScreen(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: placement.minX + CGFloat(point.x) * placement.width,
                y: placement.minY + CGFloat(point.y) * placement.height
            )
        }
        return Quad(
            topLeft: toScreen(videoQuad.topLeft),
            topRight: toScreen(videoQuad.topRight),
            bottomRight: toScreen(videoQuad.bottomRight),
            bottomLeft: toScreen(videoQuad.bottomLeft)
        )
    }

    /// 视频帧在取景视图内的 `.resizeAspectFill` 解析放置（屏幕点空间）。
    ///
    /// `scale = max(viewWidth / videoAspect, viewHeight)`——哪个维度贴边哪个决定
    /// 缩放；显示尺寸 `videoAspect × scale` × `scale`，居中放置（超出 viewSize 的
    /// 部分即裁切区）。退化输入（aspect ≤ 0 / viewSize 退化）→ 零尺寸居中矩形。
    static func videoFramePlacement(geometry: CaptureGeometry, viewSize: CGSize) -> CGRect {
        guard geometry.videoAspect.isFinite, geometry.videoAspect > 0,
              viewSize.width > 0, viewSize.height > 0
        else {
            return .zero
        }
        let scale = max(Double(viewSize.width) / geometry.videoAspect, Double(viewSize.height))
        let displayWidth = geometry.videoAspect * scale
        let displayHeight = scale
        return CGRect(
            x: (Double(viewSize.width) - displayWidth) / 2,
            y: (Double(viewSize.height) - displayHeight) / 2,
            width: displayWidth,
            height: displayHeight
        )
    }

    // MARK: - 逆映射（spec/guided-capture T011 / FR-004 / plan D2）

    /// 屏幕点 → 照片归一化点（正向链 `screenQuad` 的逆）。
    ///
    /// 逆链与正向链**逐段取逆**（不另写一套宽高比公式）：
    /// 屏幕点 →（除以 aspectFill 放置矩形）→ 视频归一化点 →
    /// `FOVLayout.convert(video → photo)` → 照片归一化点。
    ///
    /// ## 退化与越界语义
    /// - 退化输入（aspect ≤ 0 / 非有限 / viewSize 退化）→ **原样返回入参**
    ///   （与 `screenQuad` 的容错契约一致：调用方不崩溃、不变形）；
    /// - 越界（屏幕点在视图外）→ **不钳制**：照片坐标可以出界，调用方
    ///   （`CaptureViewModel` 的引导框校验）据此判定非法并回退——
    ///   「静默钳制」会把越界拖动伪装成合法框，破坏 WYSIWYG 承诺。
    static func photoPoint(
        fromScreenPoint point: CGPoint,
        geometry: CaptureGeometry,
        viewSize: CGSize
    ) -> CGPoint {
        guard geometry.videoAspect.isFinite, geometry.videoAspect > 0,
              geometry.photoAspect.isFinite, geometry.photoAspect > 0,
              viewSize.width > 0, viewSize.height > 0
        else {
            return point
        }
        let placement = videoFramePlacement(geometry: geometry, viewSize: viewSize)
        guard placement.width > 0, placement.height > 0 else { return point }
        let videoX = (Double(point.x) - placement.minX) / placement.width
        let videoY = (Double(point.y) - placement.minY) / placement.height
        let videoPoint = Quad(
            topLeft: CGPoint(x: videoX, y: videoY),
            topRight: CGPoint(x: videoX, y: videoY),
            bottomRight: CGPoint(x: videoX, y: videoY),
            bottomLeft: CGPoint(x: videoX, y: videoY)
        )
        return FOVLayout.convert(
            quad: videoPoint,
            fromAspect: geometry.videoAspect,
            toAspect: geometry.photoAspect
        ).topLeft
    }

    /// 屏幕四边形 → 照片空间四边形（逐角逆映射）。
    static func photoQuad(
        fromScreenQuad screenQuad: Quad,
        geometry: CaptureGeometry,
        viewSize: CGSize
    ) -> Quad {
        Quad(
            topLeft: photoPoint(
                fromScreenPoint: screenQuad.topLeft,
                geometry: geometry,
                viewSize: viewSize
            ),
            topRight: photoPoint(
                fromScreenPoint: screenQuad.topRight,
                geometry: geometry,
                viewSize: viewSize
            ),
            bottomRight: photoPoint(
                fromScreenPoint: screenQuad.bottomRight,
                geometry: geometry,
                viewSize: viewSize
            ),
            bottomLeft: photoPoint(
                fromScreenPoint: screenQuad.bottomLeft,
                geometry: geometry,
                viewSize: viewSize
            )
        )
    }
}
