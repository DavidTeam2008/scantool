import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// 像素配图检测（`InkFigureDetector`）。
///
/// 真机反馈（2026-09-12）：一页教材拍下来做「还原」，正文里那张**照片整个丢了**。
/// 根因是配图检测原来全是几何的 —— 把 OCR 文字盒当墙找「空白连通域」，
/// 而它**区分不了「照片」和「白纸」**：整页空白连成了一整块（bbox 覆盖 94%×96%），
/// 插图的空白和页边距、行间距全部连通，照片从来没有作为独立区域出现过。
struct InkFigureDetectorTests {

    /// 造一页：左边几行「文字」（细横条），右边一块「照片」（带噪点的大色块）。
    ///
    /// 噪点是关键：`InkFigureDetector` 的 `minDetailRatio` 靠局部高频把照片
    /// 和平滑阴影分开，纯色块会被当成阴影挡掉。
    /// 用确定性伪随机（测试必须可复现）。
    private func pageWithPhotoDeterministic() -> CGImage? {
        let width = 300
        let height = 425
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed = 12345

        func next() -> Int {
            seed = (seed &* 1103515245 &+ 12345) & 0x7fff_ffff
            return seed
        }

        // 左栏文字条
        for line in 0..<14 {
            let y0 = 40 + line * 17
            for y in y0..<(y0 + 5) {
                for x in 20..<125 {
                    let index = (y * width + x) * 4
                    pixels[index] = 0; pixels[index+1] = 0; pixels[index+2] = 0; pixels[index+3] = 255
                }
            }
        }
        // 右侧「照片」：灰底 + 噪点
        for y in 60..<(60 + 190) {
            for x in 150..<(150 + 130) {
                let noise = UInt8(60 + next() % 130)
                let index = (y * width + x) * 4
                pixels[index] = noise; pixels[index+1] = noise; pixels[index+2] = noise; pixels[index+3] = 255
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
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
        )
    }

    /// 左栏那些文字条对应的「已知 OCR 文字盒」。
    private func textBoxes(width: Int = 300, height: Int = 425) -> [CGRect] {
        (0..<14).map { line in
            let y0 = 40 + line * 17
            return CGRect(
                x: 20.0 / CGFloat(width),
                y: 1 - CGFloat(y0 + 5) / CGFloat(height),
                width: 105.0 / CGFloat(width),
                height: 5.0 / CGFloat(height)
            )
        }
    }

    @Test("带噪点的照片区域要能被找出来")
    func findsPhotoRegion() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let boxes = InkFigureDetector.boxes(.init(image: image, textBoxes: textBoxes()))

        #expect(boxes.isEmpty == false, "照片没有被检出")
        // 照片在右半边
        let photo = try #require(boxes.first { $0.midX > 0.5 })
        #expect(photo.width > 0.25, "照片框太窄：\(photo)")
        #expect(photo.height > 0.25, "照片框太矮：\(photo)")
    }

    @Test("被 OCR 文字盒覆盖的区域不能被当成照片")
    func textBlockIsNotAFigure() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let boxes = InkFigureDetector.boxes(.init(image: image, textBoxes: textBoxes()))
        // 左栏文字条整片被文字盒覆盖 → 不该出图
        #expect(boxes.allSatisfy { $0.midX > 0.35 }, "左栏文字区被误判成配图：\(boxes)")
    }

    @Test("没有文字盒时，文字条也不该被当成照片（长宽比闸门）")
    func textStripsWithoutTextBoxesAreRejectedByAspect() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let boxes = InkFigureDetector.boxes(.init(image: image, textBoxes: []))
        // 文字条又宽又扁（aspect 远超 3.5），必须被长宽比挡掉
        #expect(boxes.allSatisfy { $0.width / $0.height <= InkFigureDetector.maxAspect + 0.01 })
    }

    @Test("纯白页面不产生任何配图")
    func blankPageHasNoFigure() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 425), format: format)
        let blank = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 425))
        }
        let boxes = InkFigureDetector.boxes(.init(image: try #require(blank.cgImage), textBoxes: []))
        #expect(boxes.isEmpty)
    }

    @Test("已占用区域（表格 / 条码）不重复出图")
    func occupiedRegionIsSkipped() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let photo = CGRect(x: 0.45, y: 0.3, width: 0.5, height: 0.5)
        let boxes = InkFigureDetector.boxes(.init(image: image, textBoxes: [], occupied: [photo]))
        #expect(boxes.allSatisfy { $0.intersects(photo) == false })
    }

    // MARK: - 第二输出：被文字覆盖墨块（spec/layout-restore plan D4）

    /// 照片区域对应的 Vision 归一化框（pageWithPhotoDeterministic 里右侧那块噪点图）。
    private func photoBox(width: Int = 300, height: Int = 425) -> CGRect {
        CGRect(
            x: 150.0 / CGFloat(width),
            y: 1 - 250.0 / CGFloat(height),
            width: 130.0 / CGFloat(width),
            height: 190.0 / CGFloat(height)
        )
    }

    @Test("被文字盒覆盖的墨块进第二输出、不进 figures；既有入口 boxes() 行为不变")
    func textCoveredInkBlobGoesToSecondOutput() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let covered = photoBox().insetBy(dx: -0.02, dy: -0.02)
        let output = InkFigureDetector.detect(.init(image: image, textBoxes: [covered]))

        // 照片被文字盒覆盖 → 不再是配图
        #expect(
            output.figures.allSatisfy { $0.intersects(covered) == false },
            "被文字盒覆盖的墨块不应出现在 figures：\(output.figures)"
        )
        // 但要作为「被文字覆盖墨块」证据出现在第二输出里
        #expect(
            output.textCoveredInkRegions.contains { $0.intersects(covered) },
            "被文字盒覆盖的墨块没有进入第二输出：\(output.textCoveredInkRegions)"
        )
        // 既有入口只暴露 figures 通道
        #expect(InkFigureDetector.boxes(.init(image: image, textBoxes: [covered])) == output.figures)
    }

    @Test("已占用区域也不进第二输出（表格/条码已有权威表示）")
    func occupiedRegionIsSkippedInSecondOutput() throws {
        let image = try #require(pageWithPhotoDeterministic())
        let covered = photoBox().insetBy(dx: -0.02, dy: -0.02)
        let occupied = CGRect(x: 0.45, y: 0.3, width: 0.55, height: 0.55)
        let output = InkFigureDetector.detect(
            .init(image: image, textBoxes: [covered], occupied: [occupied])
        )
        #expect(output.textCoveredInkRegions.allSatisfy { $0.intersects(occupied) == false })
    }
}
