import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// 墨迹提取服务契约（wps-parity-layout plan D5 / FR-006 / T011）。
///
/// 导出前墨迹-文本对账哨兵的「原页哪里有墨」证据来源。Domain 对账纯函数
/// （`InkTextReconciler`）不碰图像 I/O —— 本协议是它与图像世界之间唯一的门，
/// 测试可注入替身控制墨迹区域集（协议随实现放，模式对齐 `BarcodeDetecting`）。
protocol InkRegionProviding: Sendable {
    /// 渲染页图片 → 归一化墨迹区域集（Vision 坐标，原点左下）。
    ///
    /// 图片不可解码时返回空集 —— 对账在「无墨迹证据」下自然零缺口，
    /// 哨兵不因文件缺失而阻断导出（FR-006 只记不阻断）。
    func inkRegions(imageURL: URL) -> [CGRect]
}

/// 默认实现：加载渲染页 → `InkFigureDetector.rawInkRegions`。
///
/// 协议化复用既有墨块能力（栅格化 + 连通域），不重复造图像处理轮子；
/// 走**原始连通域**而非 figures 通道 —— 行级漏识的墨过不了 figures 的
/// 质量闸门，对账证据必须从无闸门的墨迹出发（详见 `rawInkRegions` 注释）。
struct InkRegionProvider: InkRegionProviding {
    func inkRegions(imageURL: URL) -> [CGRect] {
        guard let image = Self.loadCGImage(at: imageURL) else { return [] }
        return InkFigureDetector.rawInkRegions(in: image)
    }

    /// 解码链与 `VisionTextRecognizer` / `OnDeviceDocumentParser` 同款
    /// （仓库既有惯例：各服务私有解码，互不耦合）：
    /// UIImage 优先（拉平 EXIF 方向），fallback `CGImageSource`。
    private static func loadCGImage(at url: URL) -> CGImage? {
        if let uiImage = UIImage(contentsOfFile: url.path) {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: uiImage.size, format: format)
            let flattened = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
            }
            return flattened.cgImage ?? uiImage.cgImage
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
