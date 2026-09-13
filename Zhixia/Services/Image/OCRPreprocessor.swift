import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// OCR 专用图像预处理（docs/09 §7 的 P0-2）。
///
/// **为什么要和「展示用 rendered」解耦**：用户要的是「好看」（饱和、明亮、像原件，
/// 甚至明确选 `Enhancement.original` 要求保留原图观感），OCR 要的是「好认」
/// （无阴影、高局部对比、无色彩噪声）。同一张图不可能同时最优。
/// 扫描王的做法就是让 OCR 跑在去阴影 + 高对比后的图上，**而不是跑在「好看」的图上** ——
/// 这两件事必须解耦，用户选「原图」滤镜时 OCR 也仍然要走这一档。
protocol OCRImagePreparing: Sendable {
    /// 产出一张「为 OCR 优化」的图。失败返回 `nil` —— 调用方必须能接受「没有预处理档」。
    /// `async` 是为了让实现可以是一个 actor（滤镜链要独占一个 `CIContext`）。
    func prepareForOCR(_ image: CGImage) async -> CGImage?
}

/// 默认实现：`CIDocumentEnhancer` + 灰度 + 轻度锐化。
///
/// 对比改动前：`EnhancementRecipe` 的 `deskewShadow` 档只做 `CIHighlightShadowAdjust`
/// （shadows 0.55）—— 那是「整体抬暗部」，对手机投在纸上的**局部阴影**基本无效，
/// 而且名字里的 deskew 在图像管线里根本不存在。这里换成系统自带的文档增强滤镜：
/// 它做的是背景估计 + 白化 + 对比增强，正是文档场景需要的。
///
/// 滤镜链顺序有意义：
/// 1. `CIDocumentEnhancer` —— 去阴影 + 背景白化 + 增强对比（iOS 13+，一行调用）。
/// 2. 灰度 —— 去掉彩色噪声；Vision 在灰度图上更稳，也更快。
/// 3. `CISharpenLuminance` 轻度锐化 —— 补偿前两步与 JPEG 压缩造成的边缘软化。
actor OCRPreprocessor: OCRImagePreparing {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// `CIDocumentEnhancer` 的强度。Apple 文档示例用 4。
    private let enhancement: Float
    private let sharpness: Float

    init(enhancement: Float = 4, sharpness: Float = 0.3) {
        self.enhancement = enhancement
        self.sharpness = sharpness
    }

    func prepareForOCR(_ image: CGImage) async -> CGImage? {
        let extent = CIImage(cgImage: image).extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        var ciImage = CIImage(cgImage: image)

        let enhancer = CIFilter.documentEnhancer()
        enhancer.inputImage = ciImage
        enhancer.amount = enhancement
        if let output = enhancer.outputImage { ciImage = output }

        let color = CIFilter.colorControls()
        color.inputImage = ciImage
        color.saturation = 0
        color.contrast = 1.05
        if let output = color.outputImage { ciImage = output }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = ciImage
        sharpen.sharpness = sharpness
        if let output = sharpen.outputImage { ciImage = output }

        // 用**原始** extent 裁剪：滤镜链不改变 extent，但显式钉住可以避免
        // 将来插入某个带边缘外扩的滤镜时静默产出尺寸不同的图。
        return context.createCGImage(ciImage, from: extent)
    }
}
