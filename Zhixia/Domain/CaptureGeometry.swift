import Foundation

/// 运行时测得的取景几何（plan D2）——视频流帧与照片输出各自的**竖屏**宽高比。
///
/// ## 为什么必须运行时测量
/// 上一轮「虚线框 3.86× 拉伸」与本轮「框系统性偏窄」同根：映射层假设
/// 预览 / 视频流 / 照片三者宽高比一致。模拟器视频流实测 16:9（720×405 横向）、
/// 照片 4:3；真机随设备而异。任何硬编码（16:9 / 4:3 常量）都会随设备/系统组合破裂，
/// 所以几何参数只来自实测：视频宽高比取实际送达帧的尺寸，照片宽高比取
/// `activeFormat` 尺寸（快门时以 `CapturedPhoto.pixelSize` 复核并记录差异日志）。
///
/// 「竖屏宽高比」= 宽 ÷ 高（4:3 = 0.75；16:9 ≈ 0.5625）。两个归一化空间间的
/// 换算由 `FOVLayout` 按「同传感器中心裁切」规则完成。
struct CaptureGeometry: Equatable, Sendable {
    /// 视频流帧的竖屏宽高比（宽 ÷ 高）。检测输入空间（live 帧归一化 Quad）的真实度量。
    let videoAspect: Double
    /// 照片输出的竖屏宽高比（宽 ÷ 高）。成片裁剪用框的唯一权威空间的度量。
    let photoAspect: Double

    /// 未配置会话时的默认组合：两级相等 → `FOVLayout` 换算恒等（协议契约：
    /// `CameraCapturing.geometry()` 未配置时返回本值，调用方不崩溃、不变形）。
    static let identity = CaptureGeometry(videoAspect: 1, photoAspect: 1)

    init(videoAspect: Double, photoAspect: Double) {
        self.videoAspect = videoAspect
        self.photoAspect = photoAspect
    }
}
