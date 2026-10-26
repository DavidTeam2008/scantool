import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import Zhixia

@Suite(.serialized)
struct PaperIlluminationFlattenerTests {
    private static let sharedContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        .useSoftwareRenderer: false,
    ])
    private let context = sharedContext

    @Test("折痕阴影被压平，文字仍保持深色")
    func flattensCreaseShadowAndKeepsTextContrast() throws {
        let input = try makePageImage()
        let flattener = PaperIlluminationFlattener()
        let output = try #require(flattener.flatten(input, context: context))
        #expect(output.metrics.applied)
        #expect(output.metrics.paperCoverage > 0.5)
        #expect(output.metrics.gainMax <= 1.501)
        #expect(output.metrics.gainP50 > 1.01)
        #expect(output.metrics.varianceAfter < output.metrics.varianceBefore * 0.70)

        let before = try pixels(of: input)
        let after = try pixels(of: output.image)
        let shadowPoint = (x: 198, y: 30)
        let brightPoint = (x: 320, y: 30)
        let shadowBefore = luma(before, width: 360, point: shadowPoint)
        let brightBefore = luma(before, width: 360, point: brightPoint)
        let shadowAfter = luma(after, width: 360, point: shadowPoint)
        let brightAfter = luma(after, width: 360, point: brightPoint)
        #expect(brightBefore - shadowBefore > 0.20)
        #expect(abs(brightAfter - shadowAfter) < 0.10)
        #expect(shadowAfter > shadowBefore + 0.10)

        let text = (x: 198, y: 180)
        let textAfter = luma(after, width: 360, point: text)
        #expect(textAfter < 0.18)
        #expect(shadowAfter - textAfter > 0.60)
    }

    @Test("表格/保护区不做增益")
    func preservesProtectedRegions() throws {
        let input = try makePageImage()
        let output = try #require(
            PaperIlluminationFlattener().flatten(
                input,
                context: context,
                protectedRects: [CGRect(x: 0.45, y: 0, width: 0.20, height: 1)]
            )
        )
        #expect(output.metrics.applied)
        let before = try pixels(of: input)
        let after = try pixels(of: output.image)
        let shadowPoint = (x: 198, y: 30)
        let shadowBefore = luma(before, width: 360, point: shadowPoint)
        let shadowAfter = luma(after, width: 360, point: shadowPoint)
        #expect(abs(shadowAfter - shadowBefore) < 0.012)
    }

    @Test("彩色插图区域不做强增益")
    func preservesSaturatedArtwork() throws {
        let input = try makePageImage()
        let output = try #require(PaperIlluminationFlattener().flatten(input, context: context))
        let before = try pixels(of: input)
        let after = try pixels(of: output.image)
        let artwork = (x: 285, y: 390)
        let beforeRGB = rgb(before, width: 360, point: artwork)
        let afterRGB = rgb(after, width: 360, point: artwork)
        #expect(abs(beforeRGB.r - afterRGB.r) < 0.02)
        #expect(abs(beforeRGB.g - afterRGB.g) < 0.02)
        #expect(abs(beforeRGB.b - afterRGB.b) < 0.02)
        let saturation = (max(afterRGB.r, afterRGB.g, afterRGB.b) - min(afterRGB.r, afterRGB.g, afterRGB.b))
            / max(afterRGB.r, afterRGB.g, afterRGB.b)
        #expect(saturation > 0.4)
    }

    @Test("均匀白纸不做无意义增益")
    func leavesFlatPageUnchanged() throws {
        let input = try makeFlatPageImage()
        let output = try #require(PaperIlluminationFlattener().flatten(input, context: context))
        #expect(!output.metrics.applied)
        #expect(output.metrics.fallbackReason == "low_gain")
        let before = try pixels(of: input)
        let after = try pixels(of: output.image)
        #expect(before == after)
    }

    @Test("无纸面的深色/彩色图回退原图")
    func fallsBackWithoutPaper() throws {
        let input = try makeDarkImage()
        let output = try #require(PaperIlluminationFlattener().flatten(input, context: context))
        #expect(!output.metrics.applied)
        #expect(output.metrics.fallbackReason == "no_paper")
        let before = try pixels(of: input)
        let after = try pixels(of: output.image)
        #expect(before == after)
    }

    // MARK: - 夹具

    private func makePageImage() throws -> CIImage {
        let width = 360
        let height = 520
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                let v = Double(y) / Double(height - 1)
                let crease = 0.34 * exp(-0.5 * pow((u - 0.55) / 0.075, 2))
                let gradient = 0.035 * v
                var value = 0.91 - crease - gradient
                // 黑色文字条：跨过折痕，用来验证黑字不被一起提亮。
                if isTextBar(x: x, y: y) {
                    value = 0.07
                }
                // 右下方彩色插图；覆盖文字条，验证饱和区域 mask。
                if u > 0.72, u < 0.90, v > 0.62, v < 0.82 {
                    let checker = (x / 12 + y / 12) % 2 == 0
                    let rgb = checker
                        ? (r: 0.92, g: 0.28, b: 0.10)
                        : (r: 0.10, g: 0.32, b: 0.82)
                    set(bytes: &bytes, width: width, x: x, y: y, r: rgb.r, g: rgb.g, b: rgb.b)
                    continue
                }
                set(bytes: &bytes, width: width, x: x, y: y, r: value, g: value, b: value)
            }
        }
        return try makeCIImage(bytes: bytes, width: width, height: height)
    }

    private func makeFlatPageImage() throws -> CIImage {
        let width = 240
        let height = 320
        var bytes = [UInt8](repeating: 235, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) {
            bytes[index] = 255
        }
        return try makeCIImage(bytes: bytes, width: width, height: height)
    }

    private func makeDarkImage() throws -> CIImage {
        let width = 240
        let height = 320
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let r = 0.15 + 0.45 * u
                let g = 0.12 + 0.20 * v
                let b = 0.35 + 0.30 * (1 - u)
                set(bytes: &bytes, width: width, x: x, y: y, r: r, g: g, b: b)
            }
        }
        return try makeCIImage(bytes: bytes, width: width, height: height)
    }

    private func isTextBar(x: Int, y: Int) -> Bool {
        guard x > 36, x < 324 else { return false }
        let rows = [140, 180, 220, 260, 300, 340, 380]
        return rows.contains { y >= $0 && y < $0 + 6 }
    }

    private func set(
        bytes: inout [UInt8],
        width: Int,
        x: Int,
        y: Int,
        r: Double,
        g: Double,
        b: Double
    ) {
        let offset = (y * width + x) * 4
        bytes[offset] = UInt8((min(1, max(0, r)) * 255).rounded())
        bytes[offset + 1] = UInt8((min(1, max(0, g)) * 255).rounded())
        bytes[offset + 2] = UInt8((min(1, max(0, b)) * 255).rounded())
        bytes[offset + 3] = 255
    }

    private func makeCIImage(bytes: [UInt8], width: Int, height: Int) throws -> CIImage {
        let data = Data(bytes) as CFData
        let provider = try #require(CGDataProvider(data: data))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return CIImage(cgImage: image)
    }

    private func pixels(of image: CIImage) throws -> [UInt8] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: image.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return bytes
    }

    private func luma(
        _ bytes: [UInt8],
        width: Int,
        point: (x: Int, y: Int)
    ) -> Double {
        let rgb = rgb(bytes, width: width, point: point)
        return 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
    }

    private func rgb(
        _ bytes: [UInt8],
        width: Int,
        point: (x: Int, y: Int)
    ) -> (r: Double, g: Double, b: Double) {
        let offset = (point.y * width + point.x) * 4
        return (
            Double(bytes[offset]) / 255,
            Double(bytes[offset + 1]) / 255,
            Double(bytes[offset + 2]) / 255
        )
    }
}
