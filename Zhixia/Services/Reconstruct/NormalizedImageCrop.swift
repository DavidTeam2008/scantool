import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NormalizedImageCrop {
    static func png(from image: CGImage, visionBox: CGRect, padding: CGFloat = 0.012) -> Data? {
        let padded = visionBox.insetBy(dx: -padding, dy: -padding)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let x = max(0, padded.minX * width)
        let y = max(0, (1 - padded.maxY) * height)
        let crop = CGRect(
            x: x,
            y: y,
            width: max(0, min(width - x, padded.width * width)),
            height: max(0, min(height - y, padded.height * height))
        ).integral
        guard crop.width > 8, crop.height > 8,
              let sliced = image.cropping(to: crop)
        else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, sliced, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 裁图并落盘（spec/layout-restore plan D2 / T009）：**落盘目录由调用方参数化**。
    ///
    /// 之前 `OnDeviceDocumentParser` 把裁图写死在 `temporaryDirectory` 下，系统清理后
    /// 导出就缺图（FR-010）。现在调用方传入持久目录（PageFileStore 文档级目录）下的
    /// 完整文件 URL；目录不存在时自动创建，失败返回 nil（与既有 `png` 的容错语义一致）。
    @discardableResult
    static func writePNG(
        from image: CGImage,
        visionBox: CGRect,
        to fileURL: URL,
        padding: CGFloat = 0.012
    ) -> URL? {
        guard let data = png(from: image, visionBox: visionBox, padding: padding) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
