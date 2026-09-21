import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// 乱码区域双门控判定（`GarbledRegionDetector`，spec/layout-restore plan D4）。
///
/// 双门控缺一不可：
/// 1. **信号门控**（行级）：Vision confidence 低 **且** OCRTextQuality 分数低。
///    识别正确的文字质量分天然为正（CJK ×8 / 字母 +1），所以生僻字、模糊小字
///    只要认对了就不会被剔除 —— 这是 FR-004「误杀率趋零优先于乱码清除率」的实现；
/// 2. **墨块门控**（区域级）：低信号行空间聚类后，与 `InkFigureDetector`
///    「被文字覆盖墨块」区域的重叠率达到阈值。
///
/// 保守性由本套件钉死：高置信行永不剔除；识别正确的文本行永不剔除。
struct GarbledRegionDetectorTests {

    /// 一块「艺术字」的墨块证据（Vision 归一化，左下原点）。
    private let artworkRegion = CGRect(x: 0.10, y: 0.50, width: 0.35, height: 0.20)

    /// 艺术字区域里被 OCR 读出的典型乱码行（符号汤 → OCRTextQuality 分为负）。
    private func garbageLine(
        text: String = "Ж&M], MN&R&ŒZ1‡Л",
        confidence: Double = 0.12,
        x: CGFloat = 0.12,
        y: CGFloat,
        width: CGFloat = 0.30,
        height: CGFloat = 0.035
    ) -> OCRLine {
        OCRLine(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence
        )
    }

    // MARK: - 双门控矩阵

    @Test("低置信乱码行 + 墨块重叠 → 判定 artwork（两门全开）")
    func lowConfidenceGarbageOverlappingInkBecomesArtwork() {
        let lines = [
            garbageLine(y: 0.62),
            garbageLine(text: "„Ë‡Л ÷×÷", confidence: 0.08, y: 0.58)
        ]
        let judgement = GarbledRegionDetector.detect(lines: lines, inkRegions: [artworkRegion])

        #expect(judgement.regions.count == 1)
        #expect(judgement.removedLineCount == 2)
        #expect(judgement.isGarbled(0))
        #expect(judgement.isGarbled(1))
        // 区域矩形 = 成员乱码行的并集（Vision 归一化）—— 不吞并墨块证据区域，
        // 避免把邻近正常文本的覆盖区一并划进 artwork。
        let union = lines[0].boundingBox.union(lines[1].boundingBox)
        #expect(judgement.regions[0].rect == union)
    }

    @Test("仅低置信、无墨块证据（生僻小字）→ 保留文本")
    func lowConfidenceWithoutInkStaysText() {
        let lines = [garbageLine(y: 0.62), garbageLine(y: 0.58)]
        let judgement = GarbledRegionDetector.detect(lines: lines, inkRegions: [])

        #expect(judgement.isEmpty)
        #expect(judgement.removedLineCount == 0)
        // 候选统计仍要可见（供日志观测信号门控的触达面）
        #expect(judgement.candidateLineCount == 2)
    }

    @Test("仅墨块证据、行高置信（图上说明文字）→ 保留文本")
    func highConfidenceCaptionOverlappingInkStaysText() {
        let caption = OCRLine(
            text: "扫码查看商品详情",
            boundingBox: CGRect(x: 0.12, y: 0.60, width: 0.30, height: 0.035),
            confidence: 0.93
        )
        let judgement = GarbledRegionDetector.detect(lines: [caption], inkRegions: [artworkRegion])

        #expect(judgement.isEmpty)
    }

    // MARK: - 保守性钉死（FR-004）

    @Test("高置信行永不剔除（即便文字是符号汤且落在墨块上）")
    func highConfidenceLineIsNeverRemoved() {
        let line = garbageLine(text: "÷×÷×÷×", confidence: 0.95, y: 0.60)
        let judgement = GarbledRegionDetector.detect(lines: [line], inkRegions: [artworkRegion])

        #expect(judgement.isEmpty)
        #expect(judgement.candidateLineCount == 0)
    }

    @Test("识别正确的文本行永不剔除（低置信但质量分为正 —— 模糊小字防误杀）")
    func correctlyRecognizedTextIsNeverRemoved() {
        let blurry = OCRLine(
            text: "饕餮玊尐", // 生僻字，但识别正确 → CJK 质量分为正
            boundingBox: CGRect(x: 0.12, y: 0.60, width: 0.30, height: 0.035),
            confidence: 0.18
        )
        let judgement = GarbledRegionDetector.detect(lines: [blurry], inkRegions: [artworkRegion])

        #expect(judgement.isEmpty)
        #expect(judgement.candidateLineCount == 0)
    }

    // MARK: - 空间聚类

    @Test("低信号行空间聚类合并为一个区域")
    func adjacentLowSignalLinesClusterIntoOneRegion() {
        // 三行相邻乱码（行距 0.01 < 聚类间隙默认 0.02）
        let lines = [
            garbageLine(y: 0.64),
            garbageLine(confidence: 0.09, y: 0.595),
            garbageLine(confidence: 0.15, y: 0.55)
        ]
        let judgement = GarbledRegionDetector.detect(lines: lines, inkRegions: [artworkRegion])

        #expect(judgement.regions.count == 1, "相邻乱码行应合并为一个 artwork 区域：\(judgement.regions)")
        #expect(judgement.regions[0].lineIndices == [0, 1, 2])
        #expect(judgement.removedLineCount == 3)
    }

    @Test("相距远的低信号行不合并（各自独立判定）")
    func distantLowSignalLinesStaySeparate() {
        let inkA = CGRect(x: 0.05, y: 0.70, width: 0.25, height: 0.12)
        let inkB = CGRect(x: 0.60, y: 0.15, width: 0.25, height: 0.12)
        let lines = [
            garbageLine(x: 0.08, y: 0.73, width: 0.20),
            garbageLine(x: 0.63, y: 0.18, width: 0.20)
        ]
        let judgement = GarbledRegionDetector.detect(lines: lines, inkRegions: [inkA, inkB])

        #expect(judgement.regions.count == 2)
        #expect(judgement.isGarbled(0) && judgement.isGarbled(1))
    }

    // MARK: - 证据值（供日志与调参，plan D10）

    @Test("GarbledRegionJudgement 携带双门控证据值")
    func judgementCarriesDualGateEvidence() throws {
        let lines = [
            garbageLine(text: "Ж&M], MN&R&ŒZ1‡Л", confidence: 0.12, y: 0.62),
            garbageLine(text: "„Ë‡Л ÷×÷", confidence: 0.08, y: 0.58)
        ]
        let judgement = GarbledRegionDetector.detect(lines: lines, inkRegions: [artworkRegion])

        #expect(judgement.candidateLineCount == 2)
        let region = try #require(judgement.regions.first)
        // 信号门控证据：逐行置信度 + 质量分（都应不高于阈值）
        #expect(region.confidences == [0.12, 0.08])
        #expect(region.qualityScores.allSatisfy { $0 <= 0 })
        // 墨块门控证据：区域被墨块覆盖的比例 + 相交墨块数
        #expect(region.inkOverlap > 0.9)
        #expect(region.inkRegionCount == 1)
        #expect(judgement.lowestConfidence == 0.08)
    }

    @Test("墨块只轻微擦过的低信号行不判定（重叠率不足）")
    func grazingInkOverlapDoesNotConfirm() {
        // 行 [0.32, 0.42] 只与墨块 [0.40, 0.70] 左缘重叠 ~20%（< 默认 0.3 阈值）
        let ink = CGRect(x: 0.40, y: 0.55, width: 0.30, height: 0.20)
        let line = garbageLine(x: 0.32, y: 0.62, width: 0.10)
        let judgement = GarbledRegionDetector.detect(lines: [line], inkRegions: [ink])

        #expect(judgement.isEmpty)
    }

    // MARK: - 参数化与退化输入

    @Test("阈值参数化：收紧置信度门限后，边界行不再判定")
    func thresholdsAreParameterized() {
        let line = garbageLine(confidence: 0.40, y: 0.62)
        let byDefault = GarbledRegionDetector.detect(lines: [line], inkRegions: [artworkRegion])
        #expect(!byDefault.isEmpty, "默认门限 0.5 下 0.40 应是候选")

        let strict = GarbledRegionDetector.detect(
            lines: [line],
            inkRegions: [artworkRegion],
            thresholds: GarbledRegionDetector.Thresholds(maxConfidence: 0.3)
        )
        #expect(strict.isEmpty)
    }

    @Test("空输入与零尺寸行安全返回空判定")
    func degenerateInputsAreSafe() {
        #expect(GarbledRegionDetector.detect(lines: [], inkRegions: [artworkRegion]).isEmpty)
        let zero = OCRLine(text: "÷×÷", boundingBox: .zero, confidence: 0.1)
        #expect(GarbledRegionDetector.detect(lines: [zero], inkRegions: [artworkRegion]).isEmpty)
    }
}
