import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// T014（spec/wps-parity-layout US2 / FR-006 / plan D5）：墨迹-文本对账 ——
/// 四分类分支穷举 + 边界 + 墨迹证据源（T011 链路）冒烟。
///
/// 对账语义见 `InkTextReconciler`：先解释（文字行采样覆盖 ≥ 0.5 → 非缺口）、
/// 再归因（figure → structure → 页缘带）、最后定罪（likelyMissed）。
struct InkTextReconcilerTests {

    // MARK: - 帮手

    private func makePage(_ blocks: [ReconstructBlock]) -> ReconstructPage {
        ReconstructPage(
            pageID: UUID(),
            size: CGSize(width: 1, height: 1),
            scene: .plain,
            usedCloud: false,
            blocks: blocks
        )
    }

    private func paragraphBlock(
        bbox: CGRect,
        text: String,
        lines: [BlockLine]? = nil
    ) -> ReconstructBlock {
        ReconstructBlock(kind: .paragraph, bbox: bbox, text: text, lines: lines)
    }

    // MARK: - 四分类穷举

    @Test("四分类穷举：图形/结构/页缘/疑似漏识各归其位")
    func fourCategoriesFallIntoPlace() {
        let figure = CGRect(x: 0.05, y: 0.70, width: 0.25, height: 0.20)
        let table = CGRect(x: 0.05, y: 0.35, width: 0.55, height: 0.25)
        let page = makePage([
            ReconstructBlock(kind: .figure, bbox: figure, text: ""),
            ReconstructBlock(kind: .table, bbox: table, text: "", table: ReconstructTable(rows: [["a"]])),
        ])
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [
            CGRect(x: 0.10, y: 0.75, width: 0.10, height: 0.08),   // 图形区内 → figureOverlap
            CGRect(x: 0.10, y: 0.40, width: 0.10, height: 0.08),   // 表格区内 → structureSwallow
            CGRect(x: 0.40, y: 0.975, width: 0.20, height: 0.015), // 页顶带 → edgeBand
            CGRect(x: 0.40, y: 0.010, width: 0.20, height: 0.015), // 页底带 → edgeBand
            CGRect(x: 0.70, y: 0.55, width: 0.10, height: 0.02),   // 无归因 → likelyMissed
        ])

        #expect(report.count(of: .figureOverlap) == 1)
        #expect(report.count(of: .structureSwallow) == 1)
        #expect(report.count(of: .edgeBand) == 2)
        #expect(report.count(of: .likelyMissed) == 1)
        #expect(report.gaps.count == 5, "未解释墨迹全部产出缺口")
    }

    @Test("条码区墨迹归 structureSwallow，且优先于页缘带")
    func barcodeInkIsStructureNotEdgeBand() {
        // ReconstructPage.hasLocalFigure 把 barcode 也算「图形类」，但对账刻意
        // 分家：条码的墨由 payload 携带 → 结构归因；即便区域贴页底也先归结构。
        let page = makePage([
            ReconstructBlock(
                kind: .barcode,
                bbox: CGRect(x: 0.30, y: 0.02, width: 0.40, height: 0.10),
                text: "",
                barcodePayload: "ZHIXIA-2026-001"
            ),
        ])
        let report = InkTextReconciler.reconcile(
            page: page,
            inkRegions: [CGRect(x: 0.40, y: 0.025, width: 0.10, height: 0.04)] // minY 0.025 也在底带
        )
        #expect(report.count(of: .structureSwallow) == 1)
        #expect(report.count(of: .edgeBand) == 0)
    }

    // MARK: - 文字覆盖（行级语义）

    @Test("被文字行覆盖的墨迹不是缺口；行级覆盖防「块内丢行」")
    func textCoveredInkIsNotAGap() {
        // 块 bbox 有两行的体量（高 0.2），但 lines 只有顶上一行 —— 行级覆盖
        // 只认顶行：块内下半的墨迹必须暴露为 likelyMissed（块级覆盖会整个藏住，
        // 这正是哨兵要防的「块还在、块内某行被漏」）。
        let block = paragraphBlock(
            bbox: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.20),
            text: "顶行",
            lines: [BlockLine(text: "顶行", height: 0.05, gapToPrevious: 0, leadingOffset: 0, width: 0.80)]
        )
        let page = makePage([block])
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [
            // 重建行框（含 0.003 padding）：y ≈ 0.647…0.703
            CGRect(x: 0.20, y: 0.655, width: 0.10, height: 0.02),  // 顶行带内 → 已解释
            CGRect(x: 0.20, y: 0.52, width: 0.10, height: 0.02),   // 块内、行外 → likelyMissed
        ])

        #expect(report.gaps.count == 1, "顶行墨迹不应产出缺口")
        #expect(report.gaps.first?.category == .likelyMissed)
    }

    @Test("行几何重建：多行块的行框自块顶逐行下移（gapToPrevious 口径）")
    func lineGeometryReconstructionStacksFromBlockTop() {
        // 两行块：行0 顶 = 块顶（块 bbox = 行并集），行1 顶 = 行0 底 − gap。
        let block = paragraphBlock(
            bbox: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.16),
            text: "上\n下",
            lines: [
                BlockLine(text: "上", height: 0.06, gapToPrevious: 0, leadingOffset: 0, width: 0.80),
                BlockLine(text: "下", height: 0.06, gapToPrevious: 0.04, leadingOffset: 0.02, width: 0.60),
            ]
        )
        let page = makePage([block])
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [
            CGRect(x: 0.12, y: 0.61, width: 0.10, height: 0.03),  // 行0（y 0.60…0.66）内
            CGRect(x: 0.12, y: 0.51, width: 0.10, height: 0.03),  // 行1（y 0.50…0.56）内
            CGRect(x: 0.12, y: 0.57, width: 0.10, height: 0.02),  // 行间空隙 → likelyMissed
        ])

        #expect(report.count(of: .likelyMissed) == 1, "两行墨迹都应被各自行框解释")
    }

    @Test("lines 缺失的旧块回退块 bbox 做文字覆盖")
    func missingLinesFallBackToBlockBBox() {
        let block = paragraphBlock(bbox: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.20), text: "整块文本")
        let page = makePage([block])
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [
            CGRect(x: 0.20, y: 0.52, width: 0.10, height: 0.02), // 块内 → 覆盖（回退路径）
            CGRect(x: 0.20, y: 0.20, width: 0.10, height: 0.02), // 块外 → likelyMissed
        ])

        #expect(report.gaps.count == 1)
        #expect(report.gaps.first?.category == .likelyMissed)
    }

    @Test("优先级：文字覆盖先于图形归因（图内文字行的墨不算 figureOverlap）")
    func textCoverageBeatsFigureAttribution() {
        // 金标准页的真实形态：大 figure 区覆盖故事区，故事文本行嵌在其间 ——
        // 识别到的文本墨必须先被文字解释，不因落在 figure bbox 内而误报。
        let figure = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.80)
        let page = makePage([
            ReconstructBlock(kind: .figure, bbox: figure, text: ""),
            paragraphBlock(
                bbox: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.06),
                text: "图内文字行",
                lines: [BlockLine(text: "图内文字行", height: 0.06, gapToPrevious: 0, leadingOffset: 0, width: 0.80)]
            ),
        ])
        let report = InkTextReconciler.reconcile(
            page: page,
            inkRegions: [CGRect(x: 0.20, y: 0.50, width: 0.10, height: 0.02)]
        )
        #expect(report.isEmpty)
    }

    // MARK: - 阈值与边界

    @Test("覆盖阈值：一半采样点命中算解释，更少不算")
    func coverageThresholdIsHalf() {
        // 墨迹 x ∈ [0.30, 0.50]，8 列采样点在 0.3125…0.4875。
        let ink = CGRect(x: 0.30, y: 0.50, width: 0.20, height: 0.04)

        // 文字行盖住左半（x ∈ [0.29, 0.41]）→ 恰好 4/8 列命中 = 32/64 = 0.5 ≥ 阈值。
        let halfCovered = InkTextReconciler.reconcile(
            inkRegions: [ink],
            textRegions: [CGRect(x: 0.29, y: 0.48, width: 0.12, height: 0.08)],
            figureRegions: [],
            structureRegions: []
        )
        #expect(halfCovered.isEmpty, "50% 采样覆盖应判已解释")

        // 只盖住左侧 2 列（x ∈ [0.29, 0.35]）→ 16/64 = 0.25 < 阈值 → 缺口。
        let barelyCovered = InkTextReconciler.reconcile(
            inkRegions: [ink],
            textRegions: [CGRect(x: 0.29, y: 0.48, width: 0.06, height: 0.08)],
            figureRegions: [],
            structureRegions: []
        )
        #expect(barelyCovered.count(of: .likelyMissed) == 1, "25% 采样覆盖不足以解释墨迹")
    }

    @Test("页缘带：贴页顶 / 贴页底的墨迹归 edgeBand，带外不归")
    func edgeBandClassification() {
        let page = makePage([])
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [
            CGRect(x: 0.40, y: 0.760, width: 0.20, height: 0.20),  // maxY = 0.96 < 0.965 → 带外
            CGRect(x: 0.40, y: 0.780, width: 0.20, height: 0.20),  // maxY = 0.98 > 0.965 → 顶带
            CGRect(x: 0.40, y: 0.040, width: 0.20, height: 0.02),  // minY = 0.04 > 0.035 → 带外
            CGRect(x: 0.40, y: 0.030, width: 0.20, height: 0.02),  // minY = 0.03 < 0.035 → 底带
        ])
        #expect(report.count(of: .edgeBand) == 2)
        #expect(report.count(of: .likelyMissed) == 2)
    }

    @Test("空墨迹与零尺寸墨迹：报告为空、不产出缺口")
    func emptyAndDegenerateInputs() {
        let page = makePage([])
        #expect(InkTextReconciler.reconcile(page: page, inkRegions: []).isEmpty)

        let degenerate = InkTextReconciler.reconcile(
            inkRegions: [CGRect(x: 0.50, y: 0.50, width: 0, height: 0.02)],
            textRegions: [],
            figureRegions: [],
            structureRegions: []
        )
        #expect(degenerate.isEmpty, "零宽墨迹不是证据")
    }

    @Test("areaFraction = 宽×高；likelyMissedGaps 按面积降序")
    func areaFractionAndOrdering() {
        let page = makePage([])
        let small = CGRect(x: 0.30, y: 0.50, width: 0.05, height: 0.01)
        let large = CGRect(x: 0.30, y: 0.60, width: 0.20, height: 0.02)
        let report = InkTextReconciler.reconcile(page: page, inkRegions: [small, large])

        let areas = report.likelyMissedGaps.map(\.areaFraction)
        #expect(areas.count == 2)
        #expect(abs(areas[0] - 0.20 * 0.02) < 1e-9, "最大缺口应排最前")
        #expect(abs(areas[1] - 0.05 * 0.01) < 1e-9)

        let smallGap = report.gaps.first { $0.frame == small }
        #expect(smallGap != nil)
        #expect(abs((smallGap?.areaFraction ?? 0) - 0.05 * 0.01) < 1e-9)
    }

    // MARK: - 墨迹证据源（T011 链路冒烟）

    @Test("墨迹证据源：合成页图解码 → 原始连通域（大墨块保留、微噪点滤除）")
    func inkRegionProviderSmoke() throws {
        let url = try #require(InkBlobImageFixture.write())
        defer { try? FileManager.default.removeItem(at: url) }

        let regions = InkRegionProvider().inkRegions(imageURL: url)

        // 60×60px 大墨块（600×600 页的 10%）→ 保留；位置 ≈ (0.2, 0.7, 0.1×0.1)
        // （网格 120 量化 + Vision 翻转，0.03 容差）；4×4px 微噪点 < 4 墨格 → 滤除。
        #expect(regions.count == 1, "大墨块保留、微噪点滤除，实际 \(regions)")
        let region = try #require(regions.first)
        #expect(abs(region.minX - 0.20) < 0.03)
        #expect(abs(region.minY - 0.70) < 0.03)
        #expect(abs(region.width - 0.10) < 0.03)
        #expect(abs(region.height - 0.10) < 0.03)
    }

    @Test("图片不可解码：空墨迹集（哨兵不阻断的契约）")
    func undecodableImageYieldsEmptyInk() {
        let regions = InkRegionProvider().inkRegions(imageURL: URL(fileURLWithPath: "/dev/null"))
        #expect(regions.isEmpty)
    }
}

/// 合成墨迹页（600×600）：白底 + 一个 60×60px 大墨块（视觉左上区）+
/// 一个 4×4px 微噪点。Vision 归一化下大墨块 ≈ (0.2, 0.7, 0.1×0.1)。
///
/// 坐标约定（与 `InkFigureDetectorTests.photoBox()` 同款）：**像素阵行 0 =
/// 视觉底部**（CG 位图约定：数据首行 = 原点行 = 底部；JPEG 扫描线 0 = 顶部，
/// `jpegData` 负责两者间的翻转）。因此视觉左上 20%~30% 的墨块要画在数组行
/// 420..480，`rawInkRegions` 的 Vision 翻转输出 minY ≈ 0.70 —— 这正是
/// 本冒烟要钉住的「墨迹坐标与 Vision OCR 同约定」契约。
private enum InkBlobImageFixture {
    static func write() -> URL? {
        let width = 600
        let height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) {
            for y in y0..<(y0 + h) {
                for x in x0..<(x0 + w) {
                    let index = (y * width + x) * 4
                    pixels[index] = 0
                    pixels[index + 1] = 0
                    pixels[index + 2] = 0
                    pixels[index + 3] = 255
                }
            }
        }
        // 大墨块：视觉左上区 = 数组行 420..480（底部起 70%~80%）
        paint(120, 420, 60, 60)
        // 微噪点：4×4px 恰好落进 1 个网格格（600/120=5px 每格），< 4 墨格被滤
        paint(400, 300, 4, 4)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zhixia-ink-blob-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }
}
