import Foundation

/// 图像归一化空间 → 视图归一化空间的 aspect-fill 映射（`.resizeAspectFill`）。
///
/// ## 定位（spec/scan-fidelity T019 起）：**已退出 overlay 渲染链**
/// overlay 映射真值改走解析链（`OverlaySpaceMap`：照片→视频→屏幕），预览层
/// 探针与其回退路径（本模块）均退役。模块与既有测试（`FrameMapperTests`）
/// 保留：单幅图像 aspect-fill 的通用纯函数仍有回归覆盖，供历史对照与后续
/// 复用；不再有生产调用方。
enum FrameMapper {
    /// Maps a quad in image-normalized space to view-normalized space for `.resizeAspectFill`.
    static func viewQuad(from imageQuad: Quad, imageSize: CGSize, viewSize: CGSize) -> Quad {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return imageQuad
        }
        return Quad(
            topLeft: map(imageQuad.topLeft, imageSize: imageSize, viewSize: viewSize),
            topRight: map(imageQuad.topRight, imageSize: imageSize, viewSize: viewSize),
            bottomRight: map(imageQuad.bottomRight, imageSize: imageSize, viewSize: viewSize),
            bottomLeft: map(imageQuad.bottomLeft, imageSize: imageSize, viewSize: viewSize)
        )
    }

    private static func map(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            let scale = imageAspect / viewAspect
            return CGPoint(x: (point.x - 0.5) * scale + 0.5, y: point.y)
        }
        let scale = viewAspect / imageAspect
        return CGPoint(x: point.x, y: (point.y - 0.5) * scale + 0.5)
    }
}
