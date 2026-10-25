import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

actor ImagePipeline: PerspectiveCorrecting, Enhancing, Thumbnailing, ImageRendering {
    private let context: CIContext
    private let maxLongestEdge: CGFloat

    init(maxLongestEdge: CGFloat = 2200) {
        self.maxLongestEdge = maxLongestEdge
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context = CIContext(options: [
            .workingColorSpace: space,
            .useSoftwareRenderer: false
        ])
    }

    func correct(original: URL, quad: Quad, rotationTurns: Int) async throws -> Data {
        let image = try loadUpright(url: original)
        let corrected = try perspectiveCorrect(image, quad: quad)
        let rotated = rotate(corrected, turns: rotationTurns)
        return try jpegData(from: rotated, quality: 0.9)
    }

    func apply(imageData: Data, enhancement: Enhancement) async throws -> Data {
        guard let image = CIImage(data: imageData) else {
            throw ZhixiaError.perspectiveFailed
        }
        let filtered = applyRecipe(image, enhancement: enhancement)
        return try jpegData(from: filtered, quality: 0.82)
    }

    func makeThumbnail(imageData: Data, maxWidth: CGFloat) async throws -> Data {
        guard let image = CIImage(data: imageData) else {
            throw ZhixiaError.perspectiveFailed
        }
        let width = image.extent.width
        guard width > 0 else { throw ZhixiaError.perspectiveFailed }
        let scale = min(1, maxWidth / width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try jpegData(from: scaled, quality: 0.7)
    }

    func renderPage(original: URL, draft: PageDraft) async throws -> RenderedPageData {
        // P0 页面预处理：拍后/相册路径若四角检测退化或接近整图，用文档分割
        // 再试一次页面边界；只有检测框通过“提议框回退”才采用（不裁字优先）。
        let boundary = pageBoundary(original: original, proposed: draft.quad)
        writePreprocessReport(boundary.report, original: original)
        // P0 gate：页面裁切尚未通过表格稳定性 A/B（真机 after 页 table 从 2×5
        // 变 0），先只保留检测/指标，不把 crop 接到 OCR/导出的实际底座。
        // 恢复条件：table 结构与未裁切原图一致 + textCoverage ≥0.99。
        let corrected = try await correct(
            original: original,
            quad: draft.quad,
            rotationTurns: draft.rotationTurns
        )
        let enhanced = try await apply(imageData: corrected, enhancement: draft.enhancement)
        let thumb = try await makeThumbnail(imageData: enhanced, maxWidth: 360)
        let size: CGSize
        if let image = CIImage(data: enhanced) {
            size = image.extent.size
        } else {
            size = .zero
        }
        return RenderedPageData(jpeg: enhanced, thumbnail: thumb, pixelSize: size)
    }

    func averageSaturation(imageData: Data) async -> Double {
        guard let image = CIImage(data: imageData) else { return 0 }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// 仅在提议四角退化/近整图时补跑文档分割，避免改变正常取景框。
    /// 检测成功后外扩 1% 安全边（各边约 1% 页宽/页高），并写可观测报告。
    private func pageBoundary(
        original: URL,
        proposed: Quad
    ) -> (quad: Quad, report: PagePreprocessReport) {
        let started = Date()
        let margin = 0.01
        guard proposed.isDegenerate || proposed.area >= 0.95 else {
            return (
                proposed,
                PagePreprocessReport(
                    source: original.path,
                    proposed: .init(proposed),
                    detected: nil,
                    chosen: .init(proposed),
                    detectionConfidence: nil,
                    detectedArea: nil,
                    safetyMarginRatio: margin,
                    elapsedMilliseconds: elapsedMilliseconds(since: started),
                    fallbackReason: "proposed_not_degenerate",
                    createdAt: Date()
                )
            )
        }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return (
                proposed,
                PagePreprocessReport(
                    source: original.path,
                    proposed: .init(proposed),
                    detected: nil,
                    chosen: .init(proposed),
                    detectionConfidence: nil,
                    detectedArea: nil,
                    safetyMarginRatio: margin,
                    elapsedMilliseconds: elapsedMilliseconds(since: started),
                    fallbackReason: "image_unreadable",
                    createdAt: Date()
                )
            )
        }
        let orientation: CGImagePropertyOrientation = {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let raw = properties[kCGImagePropertyOrientation] as? UInt32,
                  let value = CGImagePropertyOrientation(rawValue: raw)
            else { return .up }
            return value
        }()
        let detection = PageBoundaryDetector.detect(in: image, orientation: orientation)
        let textBounds = PageBoundaryDetector.textBounds(in: image, orientation: orientation)
        let chosen = PageBoundaryDetector.choose(
            proposed: proposed,
            detected: detection,
            inkBounds: textBounds
        )
        let expanded = chosen.expanded(by: margin)
        let coverage: Double? = {
            guard let textBounds, !textBounds.isEmpty else { return nil }
            let intersection = expanded.boundingRect.intersection(textBounds)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return Double(intersection.width * intersection.height / max(textBounds.width * textBounds.height, 0.0001))
        }()
        let angles = PageBoundaryMetrics.edgeAnglesDegrees(expanded)
        let parallel = PageBoundaryMetrics.parallelErrorsDegrees(expanded)
        let reason: String
        if detection == nil {
            reason = "no_detection"
        } else if chosen.meanVertexDistance(to: proposed) < 0.01 {
            reason = "detected_near_proposed"
        } else {
            reason = "detected_used"
        }
        let report = PagePreprocessReport(
            source: original.path,
            proposed: .init(proposed),
            detected: detection.map { .init($0.quad) },
            chosen: .init(expanded),
            detectionConfidence: detection?.confidence,
            detectedArea: detection?.area,
            textBounds: textBounds.map { PagePreprocessReport.QuadPayload(CGRectPayload: $0) },
            textCoverage: coverage,
            outsideAreaRatio: PageBoundaryMetrics.outsideAreaRatio(expanded),
            edgeAnglesDegrees: angles,
            parallelErrorsDegrees: [parallel.horizontal, parallel.vertical],
            safetyMarginRatio: margin,
            cropApplied: false,
            elapsedMilliseconds: elapsedMilliseconds(since: started),
            fallbackReason: reason,
            createdAt: Date()
        )
        return (expanded, report)
    }

    private func writePreprocessReport(_ report: PagePreprocessReport, original: URL) {
        let url = original
            .deletingPathExtension()
            .appendingPathExtension("preprocess.json")
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func loadUpright(url: URL) throws -> CIImage {
        guard var image = CIImage(contentsOf: url) else {
            throw ZhixiaError.perspectiveFailed
        }
        if let raw = image.properties[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw)
        {
            image = image.oriented(orientation)
        }
        return image
    }

    private func perspectiveCorrect(_ image: CIImage, quad: Quad) throws -> CIImage {
        let working = quad.isDegenerate ? Quad.fullImage : quad
        let size = image.extent.size
        let pixels = working.pixelPoints(imageSize: size)
        let top = hypot(pixels.1.x - pixels.0.x, pixels.1.y - pixels.0.y)
        let bottom = hypot(pixels.2.x - pixels.3.x, pixels.2.y - pixels.3.y)
        let left = hypot(pixels.3.x - pixels.0.x, pixels.3.y - pixels.0.y)
        let right = hypot(pixels.2.x - pixels.1.x, pixels.2.y - pixels.1.y)
        var width = (top + bottom) / 2
        var height = (left + right) / 2
        guard width > 8, height > 8 else {
            return image
        }
        let longest = max(width, height)
        if longest > maxLongestEdge {
            let scale = maxLongestEdge / longest
            width *= scale
            height *= scale
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = ciPoint(pixels.0, height: size.height)
        filter.topRight = ciPoint(pixels.1, height: size.height)
        filter.bottomRight = ciPoint(pixels.2, height: size.height)
        filter.bottomLeft = ciPoint(pixels.3, height: size.height)
        guard var output = filter.outputImage else {
            return image
        }
        let current = output.extent.size
        if current.width > 0, current.height > 0 {
            let scaleX = width / current.width
            let scaleY = height / current.height
            output = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        return output
    }

    private func rotate(_ image: CIImage, turns: Int) -> CIImage {
        let steps = ((turns % 4) + 4) % 4
        guard steps > 0 else { return image }
        var result = image
        for _ in 0..<steps {
            let extent = result.extent
            result = result
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            let rotated = result.extent
            result = result.transformed(by: CGAffineTransform(translationX: -rotated.origin.x, y: -rotated.origin.y))
        }
        return result
    }

    private func applyRecipe(_ image: CIImage, enhancement: Enhancement) -> CIImage {
        guard let recipe = EnhancementRecipe.recipe(for: enhancement) else {
            return image
        }
        var current = image
        let shadow = CIFilter.highlightShadowAdjust()
        shadow.inputImage = current
        shadow.shadowAmount = Float(recipe.shadows)
        shadow.highlightAmount = Float(1 + recipe.highlights)
        if let output = shadow.outputImage {
            current = output
        }
        let color = CIFilter.colorControls()
        color.inputImage = current
        color.contrast = Float(recipe.contrast)
        color.saturation = Float(recipe.saturation)
        color.brightness = Float(recipe.brightness)
        if let output = color.outputImage {
            current = output
        }
        if recipe.temperature != 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = current
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500 + recipe.temperature * 1500, y: 0)
            if let output = temp.outputImage {
                current = output
            }
        }
        if recipe.sharpness > 0 {
            let sharp = CIFilter.sharpenLuminance()
            sharp.inputImage = current
            sharp.sharpness = Float(recipe.sharpness)
            if let output = sharp.outputImage {
                current = output
            }
        }
        return current
    }

    private func jpegData(from image: CIImage, quality: CGFloat) throws -> Data {
        let extent = image.extent.integral
        guard let cgImage = context.createCGImage(image, from: extent) else {
            throw ZhixiaError.perspectiveFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ZhixiaError.perspectiveFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ZhixiaError.perspectiveFailed
        }
        return data as Data
    }

    private func ciPoint(_ uiPoint: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: uiPoint.x, y: height - uiPoint.y)
    }
}
