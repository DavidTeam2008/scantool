import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 低分辨率预览帧编码（spec/guided-capture T003 / FR-007）——诊断包「最近 5s 帧」。
///
/// ## 为什么缩到这么小
/// 诊断包要在飞行模式下从真机导出并回传到开发机，体积敏感；而帧的作用只是
/// **肉眼复现当时的构图**（右页在不在画面里、框在哪），不是像素级取证。
/// 短边 128px / JPEG 质量 0.4 的单帧约 3–6KB，30 帧 ≈ 150KB——可接受。
///
/// ## 成本
/// 缩放 + 编码约 1–2ms/帧；ViewModel 按 1/3 帧采样（≈10fps），对 30fps 预览
/// 的额外开销 <5%（真机性能验收见 `device-acceptance.md` §6-5）。
enum CaptureFrameThumbnail {
    /// 短边上限（像素）。
    static let maxDimension: CGFloat = 128
    /// JPEG 质量（0.4 = 肉眼足够、体积优先）。
    static let quality: Double = 0.4

    /// 把一帧编码成低分辨率 JPEG（失败返回 nil——诊断不该影响主流程）。
    static func encode(_ image: CGImage, maxDimension: CGFloat = CaptureFrameThumbnail.maxDimension) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxDimension / CGFloat(max(width, height)))
        let targetWidth = max(1, (CGFloat(width) * scale).rounded())
        let targetHeight = max(1, (CGFloat(height) * scale).rounded())

        let context = CGContext(
            data: nil,
            width: Int(targetWidth),
            height: Int(targetHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
