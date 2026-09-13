import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// V3.2：OCR 专用预处理档（docs/09 §7 的 P0-2）。
///
/// 这里验的是**滤镜链真的做了它该做的事**，而不是「调用没崩」：
/// 输出必须与输入同尺寸、必须是灰度、文字必须仍然比背景暗（对比度没被抹平）。
struct OCRPreprocessorTests {

    /// 造一张「纸上有阴影 + 有字」的合成图：
    /// 左半边是受光的纸（浅灰），右半边是阴影里的纸（深灰），中间一条黑色横条当文字。
    private func shadowedPage(width: Int = 80, height: Int = 80) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            UIColor(white: 0.86, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            // 阴影半边：明显更暗
            UIColor(white: 0.45, alpha: 1).setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            // 文字：跨过明暗交界
            UIColor.black.setFill()
            context.fill(CGRect(x: width / 4, y: height / 2 - 4, width: width / 2, height: 8))
        }
        return image.cgImage
    }

    private func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    /// 取一块区域的平均亮度（0…1）。`CGContext.draw` 的原点在左下。
    private func luminance(_ bytes: [UInt8], width: Int, x: Int, y: Int, size: Int = 8) -> Double {
        var total = 0.0
        var count = 0
        for row in y..<(y + size) {
            for column in x..<(x + size) {
                let index = (row * width + column) * 4
                guard index + 2 < bytes.count else { continue }
                let value = (0.2126 * Double(bytes[index])
                    + 0.7152 * Double(bytes[index + 1])
                    + 0.0722 * Double(bytes[index + 2])) / 255
                total += value
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    @Test("预处理档输出与输入同尺寸")
    func preservesSize() async throws {
        let source = try #require(shadowedPage())
        let prepared = try #require(await OCRPreprocessor().prepareForOCR(source))
        #expect(prepared.width == source.width)
        #expect(prepared.height == source.height)
    }

    @Test("预处理档输出必须是灰度图")
    func outputIsGrayscale() async throws {
        let source = try #require(shadowedPage())
        let prepared = try #require(await OCRPreprocessor().prepareForOCR(source))
        let bytes = try #require(pixels(of: prepared))

        var maxSpread: Int = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index])
            let g = Int(bytes[index + 1])
            let b = Int(bytes[index + 2])
            maxSpread = max(maxSpread, max(r, g, b) - min(r, g, b))
        }
        // 去饱和之后三个通道应当一致；给一点容差，避免不同色彩空间的舍入差异造成假失败。
        #expect(maxSpread <= 3, "输出不是灰度：最大通道差 \(maxSpread)")
    }

    @Test("预处理档必须保留文字与背景的对比度")
    func keepsTextDarkerThanBackground() async throws {
        let source = try #require(shadowedPage())
        let prepared = try #require(await OCRPreprocessor().prepareForOCR(source))
        let bytes = try #require(pixels(of: prepared))
        let width = prepared.width
        let height = prepared.height

        // 文字条在 y = height/2 - 4 … +4（UIKit 坐标），CGContext 是左下原点，位置对称，取中间即可
        let textRow = height / 2
        let text = luminance(bytes, width: width, x: width / 2 - 12, y: textRow - 3, size: 6)
        let background = luminance(bytes, width: width, x: 8, y: height - 16, size: 8)

        #expect(text < background, "文字没有比背景暗：文字 \(text)，背景 \(background)")
        // 极端情况：整张图被滤镜抹成同一片灰 —— 那样 OCR 也没法用了
        #expect(background - text > 0.15, "对比度被抹平：文字 \(text)，背景 \(background)")
    }

    @Test("预处理档要把阴影两侧的背景拉近（这就是「去阴影」）")
    func equalizesShadow() async throws {
        let source = try #require(shadowedPage())
        let prepared = try #require(await OCRPreprocessor().prepareForOCR(source))

        let sourceBytes = try #require(pixels(of: source))
        let preparedBytes = try #require(pixels(of: prepared))
        let width = source.width
        let height = source.height

        // 取两块纯背景区域：左侧受光纸、右侧阴影纸（都在文字条上方）
        let litY = height - 16
        let sourceGap = abs(
            luminance(sourceBytes, width: width, x: 16, y: litY, size: 8)
                - luminance(sourceBytes, width: width, x: width - 24, y: litY, size: 8)
        )
        let preparedGap = abs(
            luminance(preparedBytes, width: width, x: 16, y: litY, size: 8)
                - luminance(preparedBytes, width: width, x: width - 24, y: litY, size: 8)
        )

        #expect(sourceGap > 0.2, "合成图本身就该有明显阴影，实际 \(sourceGap)")
        #expect(
            preparedGap < sourceGap,
            "预处理后阴影没有被拉近：处理前 \(sourceGap)，处理后 \(preparedGap)"
        )
    }

    @Test("退化输入不崩：1×1 图返回 nil 而不是构造非法上下文")
    func degenerateInputReturnsNil() async throws {
        // ⚠️ scale 必须是 1：默认 format 会按屏幕倍率放大，1×1 的点会变成 3×3 的像素，
        // 那样就绕过 `extent.width > 1` 的守卫了。
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }())
        let tiny = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let cgImage = try #require(tiny.cgImage)
        #expect(cgImage.width == 1)
        let prepared = await OCRPreprocessor().prepareForOCR(cgImage)
        #expect(prepared == nil)
    }
}

/// `confidentScore` 的语义锁定。
///
/// 这个阈值决定了「OCR 认为自己读出来了没有」，进而决定要不要跑反色档与预处理档。
/// 它以前是 `cjkCount >= 12`（12 个汉字就算读过），低到几乎等于「看到中文就停」——
/// 于是 `VisionTextRecognizer` 自己设计的两轮配置择优在中文页面上永远跑不到第二轮。
struct OCRConfidenceThresholdTests {

    @Test("读得正常的页面应当过线")
    func normalPageClearsThreshold() {
        let page = Array(repeating: "这是一行正常的正文内容，用来验证质量分。", count: 12).joined(separator: "\n")
        #expect(OCRTextQuality.score(page) >= VisionTextRecognizer.confidentScore)
    }

    @Test("几乎没读出东西的页面不该过线")
    func nearlyEmptyPageStaysBelowThreshold() {
        // 12 个汉字 —— 旧门槛刚好放行，新门槛必须拦住
        let thin = "营养成分表项目能量蛋白质"
        #expect(OCRTextQuality.cjkCount(thin) == 12)
        #expect(OCRTextQuality.score(thin) < VisionTextRecognizer.confidentScore)
    }

    @Test("整页乱码不该过线")
    func garbageStaysBelowThreshold() {
        let garbage = "|~^`\\/<>*#@!~^`\\/<>*#@!~^`\\/<>*#@!"
        #expect(OCRTextQuality.score(garbage) < VisionTextRecognizer.confidentScore)
    }
}
