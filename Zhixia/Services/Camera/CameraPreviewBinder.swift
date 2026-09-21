import AVFoundation
import Foundation

@MainActor
final class CameraPreviewBinder: CameraPreviewAttaching {
    private let bind: (AnyObject) -> Void
    /// 最近 attach 的预览层（弱引用——层由 `CameraPreviewView` 持有，避免保留环）。
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init(bind: @escaping (AnyObject) -> Void) {
        self.bind = bind
    }

    convenience init(camera: AVCameraSession) {
        self.init { layer in
            camera.bindPreview(layer)
        }
    }

    func attachPreview(to layer: AnyObject) {
        bind(layer)
        previewLayer = layer as? AVCaptureVideoPreviewLayer
    }

    /// 预览层探针（T022 起降级为**诊断对照源**，spec/scan-fidelity FR-007）：
    /// 以**全幅矩形探针**用预览层自带的坐标转换 API 标定「照片空间 → 该视图
    /// 尺寸屏幕坐标」的逐轴缩放与偏移。
    ///
    /// ⚠️ 本方法**不再被 overlay 渲染消费**——`layerRectConverted` 在无
    /// metadataOutput / 不同 iOS 版本组合下行为未定义（探针失效曾致边框系统性
    /// 偏窄甚至不可见），渲染真值已改走解析链（`OverlaySpaceMap`，T019）。
    /// 实现与协议签名保留，仅由 `EdgeOverlayView.diagnosticProbe` 调用，输出
    /// 「探针值 vs 解析式值」比对日志（`ZhixiaLog.overlayProbeAnalytic` 通道，
    /// SC-004 真机验收证据链）。
    ///
    /// 无有效预览层（未 attach / session 未连接 / 尺寸非法）→ 返回 `nil`。
    func overlayTransform(forViewSize viewSize: CGSize) -> QuadSpaceTransform? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let layer = previewLayer,
              layer.session != nil,
              layer.connection != nil
        else {
            return nil
        }
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // 全幅探针：照片空间 [0,1]² 在层坐标中的可见落点。
        let visible = layer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard visible.minX.isFinite, visible.minY.isFinite,
              visible.width.isFinite, visible.height.isFinite,
              visible.width > 0, visible.height > 0
        else { return nil }

        // 层坐标 → 目标视图坐标：预览层与 overlay 同处一个全屏 ZStack、空间对齐，
        // 层 bounds 尺寸 ≠ 视图尺寸时按比例换算，保持归一化一致。
        let scaleX = viewSize.width / bounds.width
        let scaleY = viewSize.height / bounds.height
        return QuadSpaceTransform(
            scaleX: visible.width * scaleX,
            scaleY: visible.height * scaleY,
            offsetX: visible.minX * scaleX,
            offsetY: visible.minY * scaleY
        )
    }
}
