import SwiftUI
import UIKit

/// 图片版预览（spec/word-fidelity T002 / FR-002）——**整页增强图直接呈现**。
///
/// 与 `.pageImage` 导出产物**同源同形**：Word 里就是这张图铺满页面，预览里
/// 就是这张图铺满画布 —— 用户在导出前看到的即导出所得（预览/导出同源，
/// 与「切档画面纹丝不动」的老问题相反）。
///
/// 底图缺失（页面没有 rendered 图）时退化为纸色空页，并给出提示文案
/// （由 `ReconstructView` 统一提示）。
struct PageImageCanvas: View {
    /// 页面（尺寸决定画布比例）。
    let page: ReconstructPage
    /// 底图 URL（页面 rendered 图：透视矫正 + 增强后的整页）。
    let backgroundImageURL: URL?

    /// 底图下采样上限（像素）：屏幕宽度 ≈ 400pt × 3x scale ≈ 1200px，2048 留足余量。
    private static let baseMaxPixelSize = 2048

    private var aspect: CGFloat {
        guard page.size.width > 0, page.size.height > 0 else { return 3.0 / 4.0 }
        return page.size.width / page.size.height
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width / aspect
            ZStack(alignment: .topLeading) {
                if let baseImage = backgroundImageURL.flatMap(Self.loadDownsampled) {
                    Image(uiImage: baseImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    Tokens.paper
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tokens.line, lineWidth: 0.5)
        )
    }

    /// 底图下采样（长边上限 `baseMaxPixelSize`）。
    private static func loadDownsampled(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: baseMaxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
