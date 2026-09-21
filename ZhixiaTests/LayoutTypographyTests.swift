import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// `LayoutTypography`（spec/layout-engine plan D4）的纯函数契约：
/// 实测行高 → 字号/行距推导、无实测兜底（页高 1.8% 现状公式）、钳制基准统一、
/// 宽度封顶字号（fittedFontPT）、溢出估算保守性。
///
/// **钳制基准统一**的落点（诊断根因 6 / FR-004）：字号 pt 在**文档页 pt 空间**
/// 一次算定并夹 [7,28]；预览按画布映射比例换算（`canvasFontPT`）——同一产物
/// 双端「字号 / 页高」比例恒等，钳制不再一端触发另一端不触发。
///
/// 数值全部手算钉死（改公式必红）：页高 pt 取自 DOCX 动态页
/// （`PageLayoutMapper.emuPageSize` ÷ 12700）。
struct LayoutTypographyTests {

    // MARK: - 实测行高 → 字号（吸收系数 1.05）

    @Test("fontPT = 实测行高 × 页高pt × 1.05（未触钳制区间时）")
    func fontPTFollowsMeasuredLineHeight() {
        // 0.02 × 1000 × 1.05 = 21
        #expect(isClose(LayoutTypography.fontPT(measuredLineHeight: 0.02, pageHeightPT: 1000), 21))
        // 吸收系数成比例：0.02 × 1200 × 1.05 = 25.2（仍在区间内）
        #expect(isClose(LayoutTypography.fontPT(measuredLineHeight: 0.02, pageHeightPT: 1200), 25.2))
    }

    @Test("字号钳制区间 [7, 28] 文档页 pt")
    func fontPTClampBounds() {
        // 0.03 × 1000 × 1.05 = 31.5 → 上限 28
        #expect(LayoutTypography.fontPT(measuredLineHeight: 0.03, pageHeightPT: 1000) == 28)
        // 0.001 × 1000 × 1.05 = 1.05 → 下限 7
        #expect(LayoutTypography.fontPT(measuredLineHeight: 0.001, pageHeightPT: 1000) == 7)
        // 大照片页（22in 封顶后 ≈ 1584pt）同区间
        #expect(LayoutTypography.fontPT(measuredLineHeight: 0.05, pageHeightPT: 1584) == 28)
        #expect(LayoutTypography.fontPT(measuredLineHeight: 0.0004, pageHeightPT: 1584) == 7)
    }

    @Test("密集页字号 ≤ 实测行高 × 1.2（SC-003）")
    func densePageFontStaysWithinMeasured() {
        let pageHeightPT = 1584.0
        // 密集试卷页：实测行高 ≈ 页高 1.0%
        let measured = 0.01
        let font = LayoutTypography.fontPT(measuredLineHeight: measured, pageHeightPT: pageHeightPT)
        #expect(isClose(font, 16.632), "0.01 × 1584 × 1.05")
        #expect(font <= measured * pageHeightPT * 1.2, "SC-003：字号不得放大超过实测行高的 1.2 倍")
        // 更密（0.8%）也不破界
        let denser = LayoutTypography.fontPT(measuredLineHeight: 0.008, pageHeightPT: pageHeightPT)
        #expect(denser <= 0.008 * pageHeightPT * 1.2)
        // 对照：旧 1.8% 常数公式在同一页给 28pt > 19.008 —— 正是本轮修复的放大症状
        #expect(LayoutTypography.fallbackFontPT(pageHeightPT: pageHeightPT) == 28)
        #expect(
            LayoutTypography.fallbackFontPT(pageHeightPT: pageHeightPT) > measured * pageHeightPT * 1.2,
            "旧公式违反 SC-003，实测推导必须接管有数据块"
        )
    }

    // MARK: - 无实测兜底（现状公式：页高 1.8%）

    @Test("无实测兜底 = 页高 1.8% × relativeFontSize（现状公式），同一钳制")
    func fallbackFontPTKeepsLegacyFormula() {
        #expect(isClose(LayoutTypography.fallbackFontPT(pageHeightPT: 1000), 18))
        // heading 档位常数 1.4 只在兜底路径保留语义（有实测数据时字号始终走实测）
        #expect(isClose(LayoutTypography.fallbackFontPT(pageHeightPT: 1000, relativeFontSize: 1.4), 25.2))
        // 钳制：0.018 × 2000 × 1.4 = 50.4 → 28；0.018 × 300 = 5.4 → 7
        #expect(LayoutTypography.fallbackFontPT(pageHeightPT: 2000, relativeFontSize: 1.4) == 28)
        #expect(LayoutTypography.fallbackFontPT(pageHeightPT: 300) == 7)
        // 既有 relativeFontSize 下限 0.1 语义保留（0.018 × 1000 × 0.1 = 1.8 → 7）
        #expect(LayoutTypography.fallbackFontPT(pageHeightPT: 1000, relativeFontSize: 0.05) == 7)
    }

    // MARK: - 钳制基准统一（预览换算 ÷ 画布缩放）

    @Test("钳制基准统一：预览换算与 DOCX 相对页高比例相等")
    func canvasConversionPreservesFontRatio() {
        // 源页 1000×2000px → 画布 500×1000（同比例纯线性缩放，scale = 0.5）
        let map = PageLayoutMapper.map(
            pageSize: CGSize(width: 1000, height: 2000),
            targetSize: CGSize(width: 500, height: 1000)
        )
        let pageHeightPT = 1500.0
        let font = 21.0
        let canvasFont = LayoutTypography.canvasFontPT(fontPT: font, pageHeightPT: pageHeightPT, map: map)
        // 21 / 1500 × (2000 × 0.5) = 14
        #expect(isClose(canvasFont, 14))
        // 双端比例恒等：canvasFont / 画布页高 == fontPT / 文档页高
        let canvasPageHeight = Double(map.pageSize.height * map.scale)
        #expect(isClose(canvasFont / canvasPageHeight, font / pageHeightPT))
        // 现状公式比例复现：兜底字号（未触钳制）在画布上仍占画布页高 1.8%
        let fallbackCanvas = LayoutTypography.canvasFontPT(
            fontPT: LayoutTypography.fallbackFontPT(pageHeightPT: 1000),
            pageHeightPT: 1000,
            map: map
        )
        #expect(isClose(fallbackCanvas / canvasPageHeight, 0.018))
        // 退化输入（页高 pt ≤ 0）直接透传字号，不产生 NaN
        #expect(LayoutTypography.canvasFontPT(fontPT: font, pageHeightPT: 0, map: map) == font)
    }

    // MARK: - 行距补偿

    @Test("行距补偿非负：实测行距 − 字号标称行高，负值取 0")
    func lineSpacingNeverNegative() {
        // 0.03 × 1000 = 30pt 实测行距；21pt 字号标称行高 25.2 → 补偿 4.8
        #expect(isClose(LayoutTypography.lineSpacing(measuredLineHeight: 0.03, pageHeightPT: 1000, fontPT: 21), 4.8))
        // 字号标称行高超过实测 → 负值取 0
        #expect(LayoutTypography.lineSpacing(measuredLineHeight: 0.02, pageHeightPT: 1000, fontPT: 21) == 0)
        #expect(LayoutTypography.lineSpacing(measuredLineHeight: 0.03, pageHeightPT: 1000, fontPT: 28) == 0)
    }

    // MARK: - 宽度封顶字号（防 Word txbx 换行 / 预览截断）

    @Test("字符宽度单位：全宽 1.0、拉丁 0.6（偏高估防漏算换行）")
    func charUnitsClassification() {
        #expect(LayoutTypography.charUnits(of: "十个汉字") == 4)
        #expect(isClose(LayoutTypography.charUnits(of: "ABC"), 1.8))
        #expect(LayoutTypography.charUnits(of: "") == 0)
        // 全角数字按全宽计
        #expect(LayoutTypography.charUnits(of: "１２３") == 3)
    }

    @Test("fittedFontPT：放得下不缩、放不下按可用宽缩、下限 7pt、绝不放大")
    func fittedFontCapsByAvailableWidth() {
        // 6 个全宽字符 42pt → 恰好 7pt/字
        #expect(isClose(LayoutTypography.fittedFontPT(text: "十个汉字十个", availableWidthPT: 42, baseFontPT: 21), 7))
        // 宽度更紧时下限 7pt（残余溢出交给换行估算与渲染期兜底）
        #expect(LayoutTypography.fittedFontPT(text: "十个汉字十个", availableWidthPT: 20, baseFontPT: 21) == 7)
        // 放得下不缩、也绝不放大
        #expect(LayoutTypography.fittedFontPT(text: "甲", availableWidthPT: 500, baseFontPT: 8) == 8)
        // 拉丁 10 字符 × 0.6 × 10pt = 60pt 恰好
        #expect(isClose(LayoutTypography.fittedFontPT(text: "ABCDEFGHIJ", availableWidthPT: 60, baseFontPT: 21), 10))
        // 空文本不缩
        #expect(LayoutTypography.fittedFontPT(text: "", availableWidthPT: 100, baseFontPT: 21) == 21)
    }

    // MARK: - 溢出估算（保守性，供引擎溢出阶梯）

    @Test("溢出估算：不换行时 = Σ实测行高 + Σ行距（无假阳性垂直溢出）")
    func estimateMatchesGeometricHeightWhenNoWrap() {
        let lines = [
            BlockLine(text: "甲", height: 0.02, gapToPrevious: 0, leadingOffset: 0, width: 0.01),
            BlockLine(text: "乙", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0, width: 0.01),
            BlockLine(text: "丙", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0, width: 0.01),
        ]
        // 块宽 0.5（页宽 700pt → 可用 350pt），基础字号 21pt —— 单行远放得下
        let estimate = LayoutTypography.estimatedRenderHeight(
            lines: lines,
            blockWidth: 0.5,
            pageWidthPT: 700,
            pageHeightPT: 1000,
            baseFontPT: 21
        )
        // 3 × 20pt 实测行高 + 2 × 10pt 行距 = 80pt = 几何内容高度
        #expect(isClose(estimate, 80))
        // 块高 0.08 × 1000 = 80pt：放得下的块不得被误判溢出（零扰动前提）
        #expect(estimate <= 0.08 * 1000)
    }

    @Test("溢出估算：宽度耗尽按换行行数放大（保守 ≥ 2× 行高）")
    func estimateCountsWrappedLines() {
        // 10 个全宽字符挤在 21pt 可用宽里：即使 7pt 下限也需 ~73.5pt → ≥ 4 行
        let line = BlockLine(
            text: "一二三四五六七八九十",
            height: 0.02,
            gapToPrevious: 0,
            leadingOffset: 0,
            width: 0.03
        )
        let estimate = LayoutTypography.estimatedRenderHeight(
            lines: [line],
            blockWidth: 0.03,
            pageWidthPT: 700,
            pageHeightPT: 1000,
            baseFontPT: 21
        )
        #expect(estimate >= 2 * 0.02 * 1000, "换行必须被计入估算（保守放大），实际 \(estimate)")
    }

    @Test("溢出估算：行首偏移收窄可用宽（换行更多 → 估算更高）")
    func estimateRespectsLeadingOffset() {
        let text = "一二三四五六七八九十"
        let withOffset = BlockLine(text: text, height: 0.02, gapToPrevious: 0, leadingOffset: 0.02, width: 0.03)
        let withoutOffset = BlockLine(text: text, height: 0.02, gapToPrevious: 0, leadingOffset: 0, width: 0.03)
        // 块宽 0.05：有偏移可用 0.03 × 700 = 21pt；无偏移 35pt → 前者换行更多
        let tighter = LayoutTypography.estimatedRenderHeight(
            lines: [withOffset], blockWidth: 0.05, pageWidthPT: 700, pageHeightPT: 1000, baseFontPT: 21
        )
        let looser = LayoutTypography.estimatedRenderHeight(
            lines: [withoutOffset], blockWidth: 0.05, pageWidthPT: 700, pageHeightPT: 1000, baseFontPT: 21
        )
        #expect(tighter > looser, "行首偏移必须收窄可用宽：\(tighter) vs \(looser)")
    }

    // MARK: - 行帧计算（plan D7：预览逐行定位与断言共用）

    @Test("resolvedLineFrames：逐行 y 累积、x 行首偏移（首行顶贴块顶）")
    func resolvedLineFramesAccumulateMeasuredGeometry() {
        // 块 (0.1, 0.5, 0.6, 0.3) → 块顶（Vision y-up）= 0.8；三行：
        // L1 h0.04 gap0 lead0 w0.5 → (0.1, 0.76, 0.5, 0.04)
        // L2 h0.05 gap0.02 lead0.05 w0.4 → top = 0.76 − 0.02 = 0.74 → (0.15, 0.69, 0.4, 0.05)
        // L3 h0.03 gap0.01 lead0.1 w0.45 → top = 0.69 − 0.01 = 0.68 → (0.2, 0.65, 0.45, 0.03)
        let block = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.3)
        let lines = [
            BlockLine(text: "一", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.5),
            BlockLine(text: "二", height: 0.05, gapToPrevious: 0.02, leadingOffset: 0.05, width: 0.4),
            BlockLine(text: "三", height: 0.03, gapToPrevious: 0.01, leadingOffset: 0.1, width: 0.45),
        ]
        let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block)
        #expect(frames.count == 3)
        #expect(rectClose(frames[0], CGRect(x: 0.1, y: 0.76, width: 0.5, height: 0.04)))
        #expect(rectClose(frames[1], CGRect(x: 0.15, y: 0.69, width: 0.4, height: 0.05)))
        #expect(rectClose(frames[2], CGRect(x: 0.2, y: 0.65, width: 0.45, height: 0.03)))
    }

    @Test("resolvedLineFrames：越界行夹回块内（宽度截断、深度钉底不越界）")
    func resolvedLineFramesClampInsideBlock() {
        // 块 (0.1, 0.5, 0.6, 0.1) → 顶 0.6、底 0.5：
        // L1 lead0.5 w0.5 → x = 0.6 越近右缘（block.maxX = 0.7）→ 宽截为 0.1；
        //    frame (0.6, 0.54, 0.1, 0.06)
        // L2 h0.2 → rawBottom = 0.54 − 0.2 = 0.34 越块底 → 底钉 0.5、高夹 0.04
        //    frame (0.1, 0.5, 0.3, 0.04)
        let block = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.1)
        let lines = [
            BlockLine(text: "宽行", height: 0.06, gapToPrevious: 0, leadingOffset: 0.5, width: 0.5),
            BlockLine(text: "深行", height: 0.2, gapToPrevious: 0, leadingOffset: 0, width: 0.3),
        ]
        let frames = LayoutTypography.resolvedLineFrames(lines: lines, block: block)
        #expect(frames.count == 2)
        #expect(rectClose(frames[0], CGRect(x: 0.6, y: 0.54, width: 0.1, height: 0.06)))
        #expect(rectClose(frames[1], CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04)))
    }

    @Test("resolvedLineFrames：无 lines 退化为整块单帧")
    func resolvedLineFramesFallbackToWholeBlock() {
        let block = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.3)
        #expect(LayoutTypography.resolvedLineFrames(lines: nil, block: block) == [block])
        #expect(LayoutTypography.resolvedLineFrames(lines: [], block: block) == [block])
    }

    // MARK: - 辅助

    private func isClose(_ a: Double, _ b: Double, epsilon: Double = 1e-9) -> Bool {
        abs(a - b) <= epsilon
    }

    /// CGRect 分量级近似比较（行帧由浮点累积而来，1 ulp 差异不应判败）。
    private func rectClose(_ a: CGRect, _ b: CGRect, epsilon: Double = 1e-12) -> Bool {
        isClose(a.minX, b.minX, epsilon: epsilon)
            && isClose(a.minY, b.minY, epsilon: epsilon)
            && isClose(a.width, b.width, epsilon: epsilon)
            && isClose(a.height, b.height, epsilon: epsilon)
    }
}
