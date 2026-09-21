import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit
import Vision

actor VisionTextRecognizer: TextRecognizing {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let preprocessor: any OCRImagePreparing

    /// 「这一遍读得够不够」的分数线。
    ///
    /// 改动前用的是 `OCRTextQuality.cjkCount(text) >= 12` —— 只要认出 12 个汉字就提前返回。
    /// 那个门槛低到几乎等于「看到中文就停」，于是这个类**自己设计的两轮配置择优**
    /// （`usesLanguageCorrection` 关/开）在中文页面上永远跑不到第二轮，
    /// 更不会去试反色档或 OCR 专用预处理档。换成按质量分判断：240 ≈ 30 个汉字，或 240 个拉丁字符。
    ///
    /// 分数够高时行为与改动前一致（第一轮就返回，不多花时间）；只有「没读出来」时才多跑几轮。
    static let confidentScore = 240

    init(preprocessor: any OCRImagePreparing = OCRPreprocessor()) {
        self.preprocessor = preprocessor
    }

    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        guard let image = loadCGImage(at: imageURL) else {
            throw ZhixiaError.ocrFailed
        }

        let dark = isDark(image)
        var variants = [image]
        if dark, let inverted = invert(image) {
            variants.insert(inverted, at: 0)
        }

        let languages = preferredLanguages()
        let configs: [(VNRequestTextRecognitionLevel, [String], Bool)] = [
            (.accurate, languages, false),
            (.accurate, languages, true)
        ]

        var bestLines: [OCRLine] = []
        var bestScore = Int.min

        func consider(_ lines: [OCRLine]) -> Bool {
            let text = lines.map(\.text).joined(separator: "\n")
            let score = OCRTextQuality.score(text)
            if score > bestScore {
                bestLines = lines
                bestScore = score
            }
            return score >= Self.confidentScore
        }

        for variant in variants {
            for (level, langs, correction) in configs {
                guard let lines = try? recognizeLines(
                    in: variant,
                    level: level,
                    languages: langs,
                    correction: correction
                ), !lines.isEmpty else { continue }
                if consider(lines) {
                    return OCRPageText(pageID: pageID, lines: bestLines)
                }
            }
        }

        if !dark, OCRTextQuality.cjkCount(bestLines.map(\.text).joined()) == 0, let inverted = invert(image) {
            for (level, langs, correction) in configs {
                guard let lines = try? recognizeLines(
                    in: inverted,
                    level: level,
                    languages: langs,
                    correction: correction
                ), !lines.isEmpty else { continue }
                if consider(lines) {
                    return OCRPageText(pageID: pageID, lines: bestLines)
                }
            }
        }

        // P0-3：到这一步说明「读得不够」。用 OCR 专用预处理档（去阴影 / 灰度 / 轻度锐化）
        // 重跑一次。这一步能救的是真机最常见的失败模式 —— 手机在纸面投下阴影、
        // 或对比度不足导致字符误识（docs/08 §3 的 R1 之后剩下的那部分）。
        // 只有在质量分不达标时才会走到这里，所以正常页面不付这份成本。
        if bestScore < Self.confidentScore, let prepared = await preprocessor.prepareForOCR(image) {
            for (level, langs, correction) in configs {
                guard let lines = try? recognizeLines(
                    in: prepared,
                    level: level,
                    languages: langs,
                    correction: correction
                ), !lines.isEmpty else { continue }
                if consider(lines) { break }
            }
        }

        guard !bestLines.isEmpty else {
            throw ZhixiaError.ocrFailed
        }
        return OCRPageText(pageID: pageID, lines: bestLines)
    }

    private func recognizeLines(
        in image: CGImage,
        level: VNRequestTextRecognitionLevel,
        languages: [String],
        correction: Bool
    ) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = correction
        request.minimumTextHeight = 0.012
        request.revision = VNRecognizeTextRequest.currentRevision
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            // 透传 Vision 的行级置信度（spec/layout-restore plan D4）：
            // 乱码区域判定的第一道门控靠它；两轮识别「择优」路径自然选中
            // 哪一轮的行，就透传那一轮候选的 confidence。
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(
                text: text,
                boundingBox: observation.boundingBox,
                confidence: Double(candidate.confidence)
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.02 {
                return lhs.boundingBox.minY > rhs.boundingBox.minY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    private func preferredLanguages() -> [String] {
        let wanted = ["zh-Hans", "zh-Hant", "en-US"]
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequest.currentRevision
        )) ?? []
        let matched = wanted.filter { language in
            supported.contains { $0.hasPrefix(language) || $0.hasPrefix(language.replacingOccurrences(of: "-", with: "_")) }
        }
        return matched.isEmpty ? wanted : matched
    }

    private func loadCGImage(at url: URL) -> CGImage? {
        if let uiImage = UIImage(contentsOfFile: url.path) {
            return uiImage.normalizedCGImage() ?? uiImage.cgImage
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func invert(_ image: CGImage) -> CGImage? {
        let inverted = CIImage(cgImage: image).applyingFilter("CIColorInvert")
        return context.createCGImage(inverted, from: inverted.extent)
    }

    private func isDark(_ image: CGImage) -> Bool {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return false }
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = extent
        guard let output = filter.outputImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let luminance = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
        return luminance < 0.42
    }
}

private extension UIImage {
    func normalizedCGImage() -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let flattened = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return flattened.cgImage
    }
}
