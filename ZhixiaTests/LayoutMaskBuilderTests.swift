import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// 覆盖矩形 + 环带 median 填充色（`LayoutMaskBuilder`，spec/layout-restore plan D3）。
///
/// 版面还原档的净化覆盖：文字/表格块先盖一层「和周围底色一致」的矩形（外扩 1~2%
/// 防止字迹缝隙残留），再在元素层原位重排干净文本。填充色取 bbox **环带**（四周条带）
/// 像素的逐通道 median —— median 抗噪（字迹像素不主导），逐通道保留底色色相
/// （彩色海报不退化成灰块）。
struct LayoutMaskBuilderTests {

    private let colorTolerance: UInt8 = 10

    // MARK: - 合成图

    /// 整页纯色 + 中间一条黑「文字」带。
    private func solidPage(
        width: Int = 300,
        height: Int = 425,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        textBand: Bool = true
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        if textBand {
            // 中部一条黑带（像素坐标 y 向下）
            for y in 200..<210 {
                for x in 30..<270 {
                    let index = (y * width + x) * 4
                    pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
                }
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

    private func textBlock(_ bbox: CGRect, kind: ReconstructBlockKind = .paragraph) -> ReconstructBlock {
        ReconstructBlock(kind: kind, bbox: bbox, text: "文本")
    }

    /// 白纸页中央那条黑带对应的 Vision 归一化 bbox（300×425，带在 y∈[200,210)）。
    private let bandBox = CGRect(
        x: 30.0 / 300.0,
        y: 1 - 210.0 / 425.0,
        width: 240.0 / 300.0,
        height: 10.0 / 425.0
    )

    // MARK: - 覆盖矩形（外扩 + 数量）

    @Test("文本与表格块各产生一个外扩 1~2% 的覆盖矩形")
    func textAndTableBlocksProduceExpandedRects() throws {
        let image = try #require(solidPage(red: 255, green: 255, blue: 255))
        let paragraph = bandBox
        let table = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3)
        let mask = LayoutMaskBuilder.build(
            blocks: [textBlock(paragraph), textBlock(table, kind: .table)],
            baseImage: image
        )
        #expect(mask.fills.count == 2, "文本/表格块各应有一个覆盖矩形：\(mask.fills)")

        let paragraphFill = try #require(mask.fills.first { $0.rect.contains(paragraph) })
        // 外扩 1~2%（页宽/页高单位，每侧）：
        let widthGrowth = paragraphFill.rect.width - paragraph.width
        let heightGrowth = paragraphFill.rect.height - paragraph.height
        #expect(widthGrowth >= 2 * 0.01 - 0.001, "外扩不足 1%：\(paragraphFill.rect)")
        #expect(widthGrowth <= 2 * 0.02 + 0.001, "外扩超过 2%：\(paragraphFill.rect)")
        #expect(heightGrowth >= 2 * 0.01 - 0.001, "外扩不足 1%：\(paragraphFill.rect)")
        #expect(heightGrowth <= 2 * 0.02 + 0.001, "外扩超过 2%：\(paragraphFill.rect)")
        // 外扩是四周的：中心基本不动（矩形对称生长）
        #expect(abs(paragraphFill.rect.midX - paragraph.midX) < 0.005)
        #expect(abs(paragraphFill.rect.midY - paragraph.midY) < 0.005)
    }

    @Test("figure / barcode / artwork 不进 mask（底座原像素透出，不覆盖）")
    func passthroughKindsAreNotMasked() throws {
        let image = try #require(solidPage(red: 255, green: 255, blue: 255))
        let mask = LayoutMaskBuilder.build(
            blocks: [
                textBlock(bandBox, kind: .figure),
                textBlock(bandBox, kind: .barcode),
                textBlock(bandBox, kind: .artwork)
            ],
            baseImage: image
        )
        #expect(mask.fills.isEmpty, "透出底座的块不应产生覆盖矩形：\(mask.fills)")
    }

    @Test("覆盖矩形不越页界（贴边块夹在 [0,1] 内）")
    func rectsAreClampedToPage() throws {
        let image = try #require(solidPage(red: 255, green: 255, blue: 255))
        // 顶到页面上缘（Vision maxY = 1）与左缘的块
        let corner = CGRect(x: 0, y: 0.97, width: 0.2, height: 0.03)
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(corner)], baseImage: image)
        let fill = try #require(mask.fills.first)
        #expect(fill.rect.minX >= 0)
        #expect(fill.rect.minY >= 0)
        #expect(fill.rect.maxX <= 1)
        #expect(fill.rect.maxY <= 1)
        #expect(fill.rect.width > 0 && fill.rect.height > 0)
    }

    @Test("栅格坐标方向：上半页块取上半页底色，不被垂直镜像到下半页")
    func rasterSamplesTopBlockFromTopHalf() throws {
        // 上半页红、下半页蓝；顶部块的环带仍落在红半页。
        let width = 300
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let isTop = y < height / 2
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = isTop ? 220 : 40
                pixels[index + 1] = 40
                pixels[index + 2] = isTop ? 40 : 220
                pixels[index + 3] = 255
            }
        }
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
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
        // Vision 左下原点：顶部块 y ∈ [0.92, 0.98]。
        let topBlock = CGRect(x: 0.2, y: 0.92, width: 0.5, height: 0.06)
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(topBlock)], baseImage: image)
        let fill = try #require(mask.fills.first)
        #expect(
            abs(Int(fill.red) - 220) <= Int(colorTolerance),
            "顶部块应取红半页，实际 R=\(fill.red) G=\(fill.green) B=\(fill.blue)"
        )
        #expect(abs(Int(fill.blue) - 40) <= Int(colorTolerance), "顶部块不应被镜像到蓝半页")
    }

    // MARK: - 填充色（环带 median）

    @Test("白纸页 → 白填充（环带是白纸）")
    func whitePageFillsWithWhite() throws {
        let image = try #require(solidPage(red: 255, green: 255, blue: 255))
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(bandBox)], baseImage: image)
        let fill = try #require(mask.fills.first)
        #expect(abs(Int(fill.red) - 255) <= Int(colorTolerance))
        #expect(abs(Int(fill.green) - 255) <= Int(colorTolerance))
        #expect(abs(Int(fill.blue) - 255) <= Int(colorTolerance))
    }

    @Test("带色底 → 环带 median RGB 近似底色（色相保留，不退化为灰）")
    func coloredBackgroundFillsWithRingMedian() throws {
        // 红底 (255,40,40) + 黑文字带：环带几乎全是红底 → median ≈ 红底
        let image = try #require(solidPage(red: 255, green: 40, blue: 40))
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(bandBox)], baseImage: image)
        let fill = try #require(mask.fills.first)
        #expect(abs(Int(fill.red) - 255) <= Int(colorTolerance), "R=\(fill.red)")
        #expect(abs(Int(fill.green) - 40) <= Int(colorTolerance), "G=\(fill.green)")
        #expect(abs(Int(fill.blue) - 40) <= Int(colorTolerance), "B=\(fill.blue)")
        // 色相保留：G/B 通道不该被拉到 R 的一半以上（灰化）
        #expect(fill.green < 150 && fill.blue < 150)
    }

    @Test("环带被墨迹污染时 median 抗噪（黑带只占环带少数 → 填充色仍近底色）")
    func medianResistsInkContamination() throws {
        // 黑带只有 10px 高，外扩 1.5% ≈ 6px，环带厚 1.5% ≈ 6px：
        // 环带主体仍是白纸，个别行蹭到黑带的边缘 → median 仍应接近白。
        let image = try #require(solidPage(red: 250, green: 250, blue: 250))
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(bandBox)], baseImage: image)
        let fill = try #require(mask.fills.first)
        #expect(abs(Int(fill.red) - 250) <= Int(colorTolerance), "R=\(fill.red)")
        #expect(abs(Int(fill.green) - 250) <= Int(colorTolerance), "G=\(fill.green)")
        #expect(abs(Int(fill.blue) - 250) <= Int(colorTolerance), "B=\(fill.blue)")
    }

    @Test("整页块（环带出页）仍产出填充，退化为白")
    func fullPageBlockStillProducesFill() throws {
        let image = try #require(solidPage(red: 255, green: 255, blue: 255, textBand: false))
        let mask = LayoutMaskBuilder.build(blocks: [textBlock(CGRect(x: 0, y: 0, width: 1, height: 1))], baseImage: image)
        #expect(mask.fills.count == 1)
        let fill = try #require(mask.fills.first)
        #expect(abs(Int(fill.red) - 255) <= Int(colorTolerance))
    }

    // MARK: - 值类型契约

    @Test("LayoutMask 值类型：Sendable + Equatable（预览与 DOCX 共用的稳定产物）")
    func layoutMaskIsValueSemantics() {
        let a = LayoutMask(fills: [
            LayoutMask.Fill(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.1), red: 255, green: 255, blue: 255)
        ])
        let b = LayoutMask(fills: [
            LayoutMask.Fill(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.1), red: 255, green: 255, blue: 255)
        ])
        #expect(a == b)
        #expect(a != LayoutMask(fills: []))
    }
}
