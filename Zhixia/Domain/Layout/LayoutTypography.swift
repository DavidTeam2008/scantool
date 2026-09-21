import CoreGraphics
import Foundation

/// 共享排版度量（spec/layout-engine plan D4）：实测行高 → 字号/行距的**唯一**推导处，
/// 预览（LayoutCanvas）与 DOCX（DocxExportService）共同消费——两处分散的本地公式
/// （0.018 常数 × 各自空间的本地钳制）是「钳制基准不一致」的结构性缺陷（诊断根因 1/6），
/// 收敛为单一可测试函数。
///
/// ## 单位约定
/// - `measuredLineHeight` / `BlockLine.height` / `gapToPrevious`：**归一化页高比例**
///   （Vision bbox 的 y 轴单位）；
/// - `BlockLine.leadingOffset` / `width` / `blockWidth`：**归一化页宽比例**（x 轴单位）；
/// - `pageHeightPT` / `pageWidthPT`：**文档页 pt**（DOCX 动态页 = `PageLayoutMapper.emuPageSize`
///   ÷ 12700；字号钳制基准统一于此空间）。
///
/// ## 钳制基准统一（FR-004）
/// 字号 pt 在文档页 pt 空间一次算定并夹 `[7, 28]`；预览经 `canvasFontPT` 按画布映射
/// 比例换算——同一产物双端「字号 / 页高」比例恒等，钳制不再一端触发另一端不触发。
///
/// 纯函数、无状态、无 I/O；同输入同输出。
enum LayoutTypography {
    /// 吸收系数：OCR 行框含上下伸部（ascent/descent），字号 ≈ 行高 × 1.05。
    static let absorption: Double = 1.05
    /// 字号下限（文档页 pt，与既有 7pt 下限一致）。
    static let minFontPT: Double = 7
    /// 字号上限（文档页 pt）。
    static let maxFontPT: Double = 28
    /// 无实测数据兜底：页高 1.8%（现状公式，仅在无 lines/实测行高时使用）。
    static let fallbackRatio: Double = 0.018
    /// 字号标称行高系数（系统字体默认行高 ≈ 1.2 × 字号）。
    static let nominalLineHeightFactor: Double = 1.2
    /// 换行估算安全系数（保守放大估算宽度，防漏算换行）。
    static let wrapSafetyFactor: Double = 1.05
    /// 拉丁/半角字符宽度单位（em，保守偏高估防漏算换行）。
    static let latinCharUnit: Double = 0.6
    /// 兜底路径的 `relativeFontSize` 下限（既有两渲染器的 0.1 语义）。
    static let legacyRelativeFontSizeFloor: Double = 0.1
    /// 1 px @96dpi = 0.75 pt（= `PageLayoutMapper.emuPerPixel` 9525 ÷ 12700 EMU/pt）。
    /// 文档页 pt 与 DOCX 动态页（`emuPageSize` ÷ 12700）是同一数值空间。
    static let ptPerPixel: Double = 9525 / 12_700

    // MARK: - 字号

    /// 实测行高（归一化页高比例）→ 文档页 pt 字号：
    /// `clamp(实测行高 × 页高pt × 吸收系数, 7, 28)`。
    /// 密集页（SC-003）：字号 ≤ 实测行高 × 1.2（吸收系数 1.05 < 1.2，未触钳制时成立）。
    static func fontPT(measuredLineHeight: Double, pageHeightPT: Double) -> Double {
        guard measuredLineHeight > 0, pageHeightPT > 0 else {
            return fallbackFontPT(pageHeightPT: pageHeightPT)
        }
        return clampToFontRange(measuredLineHeight * pageHeightPT * absorption)
    }

    /// 块级字号（文档页 pt）—— 预览（LayoutCanvas）与 DOCX（DocxExportService）的
    /// **唯一**推导入口（plan D4 / FR-004）：实测行高优先（块级精化
    /// `measuredLineHeight`，缺省回退首行实测），无实测数据走兜底公式（页高 1.8% ×
    /// relativeFontSize——heading 档位常数的语义仅存于此路径）。两端共用本入口是
    /// 「字号 / 页高」比例恒等的前提。
    static func fontPT(for block: ReconstructBlock, pageHeightPT: Double) -> Double {
        let measured = block.measuredLineHeight ?? block.lines?.first?.height
        if let measured, measured > 0 {
            return fontPT(measuredLineHeight: measured, pageHeightPT: pageHeightPT)
        }
        return fallbackFontPT(pageHeightPT: pageHeightPT, relativeFontSize: block.style.relativeFontSize)
    }

    /// 未钳制实测字号（文档页 pt）：`实测行高 × 页高pt × 吸收系数`（`fontPT(for:)`
    /// 的钳制前原值）。引擎溢出阶梯（plan D6）的缩放下限当量依据：
    /// `s_floor = minFontPT ÷ unclampedFontPT`（字号随行高等比缩，7pt 处触底）。
    /// 无实测（行高 ≤ 0 或页高退化）返回 0——阶梯缩放步不受下限约束。
    static func unclampedFontPT(for block: ReconstructBlock, pageHeightPT: Double) -> Double {
        let measured = block.measuredLineHeight ?? block.lines?.first?.height ?? 0
        guard measured > 0, pageHeightPT > 0 else { return 0 }
        return measured * pageHeightPT * absorption
    }

    /// 无实测数据兜底（现状公式）：`clamp(页高pt × 1.8% × relativeFontSize, 7, 28)`。
    /// heading 档位常数 {1, 1.4} 的语义**仅存于此路径**——有实测数据的块字号始终走实测。
    static func fallbackFontPT(pageHeightPT: Double, relativeFontSize: Double = 1) -> Double {
        guard pageHeightPT > 0 else { return minFontPT }
        let scale = max(relativeFontSize, legacyRelativeFontSizeFloor)
        return clampToFontRange(pageHeightPT * fallbackRatio * scale)
    }

    /// 文档页 pt 字号 → 画布 pt 字号（预览侧换算：同一 pt 值 ÷ 画布相对文档页的缩放）。
    /// `fontPT / pageHeightPT` 是双端恒等的「字号 / 页高」比例（钳制基准统一的落点）。
    /// 退化输入（页高 pt ≤ 0 或画布映射退化）直接透传字号，不产生 NaN。
    static func canvasFontPT(fontPT: Double, pageHeightPT: Double, map: PageLayoutMap) -> Double {
        let canvasPageHeight = Double(map.pageSize.height) * Double(map.scale)
        guard pageHeightPT > 0, canvasPageHeight > 0 else { return fontPT }
        return fontPT / pageHeightPT * canvasPageHeight
    }

    // MARK: - 行级字号与空隙占位（spec/scan-fidelity T003 / FR-002 / FR-005）

    /// 行级字号（文档页 pt）：`line.height × pageHeightPT × 吸收系数`，钳制 [7, 28]
    /// —— 与 `fontPT(measuredLineHeight:)` 同式，但基准换成**该行实测高**。
    /// 行高退化（≤ 0 / 页高非法）→ 回退块级 `fontPT(for:)`（块级实测中位行高 →
    /// 兜底公式），与整块路径同源，不产生第二套字号语义。
    /// 消费方：DOCX 逐行 w:sz（T007）、预览逐行字号（T008）、溢出估算行级基准（T006）。
    static func lineFontPT(line: BlockLine, block: ReconstructBlock, pageHeightPT: Double) -> Double {
        guard line.height > 0, pageHeightPT > 0 else {
            return fontPT(for: block, pageHeightPT: pageHeightPT)
        }
        return clampToFontRange(line.height * pageHeightPT * absorption)
    }

    /// 空隙占位换算（spec/scan-fidelity T003 / FR-005）：行内分段间空隙（归一化
    /// 页宽）≥ 0.6 字符宽 → 占位空格数 `round(空隙pt ÷ 0.25 × 字号)`，钳制 [2, 60]；
    /// 否则 nil（普通空格连接）。字符宽 = `latinCharUnit × 字号`（文档页 pt 空间，
    /// 与宽度封顶/换行估算同一保守基准）。
    /// 消费方：DOCX 下划线空格 run（T012）、预览下划线矩形判定（T013）。
    static func gapPlaceholderSpaces(gapWidthNormalized: Double, fontPT: Double, pageWidthPT: Double) -> Int? {
        guard gapWidthNormalized > 0, fontPT > 0, pageWidthPT > 0 else {
            return nil
        }
        let gapPT = gapWidthNormalized * pageWidthPT
        let charWidthPT = latinCharUnit * fontPT
        guard gapPT >= 0.6 * charWidthPT else {
            return nil
        }
        let spaces = Int((gapPT / (0.25 * fontPT)).rounded())
        return min(max(spaces, 2), 60)
    }

    // MARK: - 表格几何（plan D8：实测列宽 + 行高封顶，Word/预览共享）

    /// 表格单元格水平内边距估算（文档页 pt）：Word 默认 `tblCellMar` 左右各
    /// 108 dxa ≈ 5.4pt；预览 `.padding(2)` 略小——双端共用本估算，小差异由
    /// `wrapSafetyFactor` 的保守余量吸收。
    static let tableCellHInsetPT: Double = 10
    /// 表格单元格字号自适应的迭代上限（与 `preScaledFontSizeHalfPoints` 同型）。
    static let tableFontMaxIterations: Int = 8

    /// 单元格内容高度估算（文档页 pt）：换行行数 `ceil(宽度单位 × 字号 ×
    /// wrapSafety ÷ 可用宽)`（≥ 1）× 字号 × 1.2（Word 单元格默认单倍行距）。
    /// 空文本 = 0（空格不参与放不下判定）。Word atLeast 升级判定与预览行高
    /// 增长（FR-008 同构）共用本函数——两端「放不下」必须同判。
    static func tableCellHeightPT(text: String, columnWidthPT: Double, fontPT: Double) -> Double {
        guard !text.isEmpty, fontPT > 0 else { return 0 }
        let available = max(columnWidthPT - tableCellHInsetPT, 1)
        let estimatedWidth = charUnits(of: text) * fontPT * wrapSafetyFactor
        let rows = max(1, Int(ceil(estimatedWidth / available)))
        return Double(rows) * fontPT * nominalLineHeightFactor
    }

    /// 单元格字号自适应（plan D8，Word/预览共享）：基础字号在「列宽换行 ×
    /// 行高」约束内**只缩不放**，下限 7pt；与 `preScaledFontSizeHalfPoints`
    /// 同型迭代（≤ `tableFontMaxIterations` 步，每步从原字号起算不累积）。
    /// 返回值已到 7pt 仍放不下 → 调用方判整表行高升级（`tableCellHeightPT`
    /// 复核，Word 转 atLeast / 预览增长行高）。
    static func tableCellFontPT(
        text: String,
        columnWidthPT: Double,
        rowHeightPT: Double,
        baseFontPT: Double
    ) -> Double {
        guard !text.isEmpty, columnWidthPT > 0, rowHeightPT > 0, baseFontPT > 0 else {
            return baseFontPT
        }
        let epsilon = 1e-6
        var estimated = tableCellHeightPT(text: text, columnWidthPT: columnWidthPT, fontPT: baseFontPT)
        guard estimated > rowHeightPT + epsilon else { return baseFontPT }
        let floorScale = baseFontPT > minFontPT ? minFontPT / baseFontPT : 1
        var scale = 1.0
        for _ in 0..<tableFontMaxIterations where estimated > rowHeightPT + epsilon {
            let next = max(floorScale, scale * rowHeightPT / estimated)
            guard next < scale else { break } // 触 7pt 下限或已收敛——无进展即止
            scale = next
            estimated = tableCellHeightPT(text: text, columnWidthPT: columnWidthPT, fontPT: baseFontPT * scale)
        }
        return baseFontPT * scale
    }

    // MARK: - 行距

    /// 行距补偿（整块单 Text 渲染路径）：实测行距 − 字号标称行高，负值取 0。
    /// 有 lines 数据的块走逐行定位渲染（行距由行几何直接给出），不经过这里。
    static func lineSpacing(measuredLineHeight: Double, pageHeightPT: Double, fontPT: Double) -> Double {
        max(0, measuredLineHeight * pageHeightPT - fontPT * nominalLineHeightFactor)
    }

    // MARK: - 宽度封顶字号（防 Word txbx 换行 / 预览单行截断）

    /// 文本宽度单位（em 数）：全宽字符（CJK/全角/谚文等）计 1.0，其余计 `latinCharUnit`。
    /// 偏高估（拉丁 0.6 > 实际均值 ~0.5）——宽度估算宁可多算不可少算（少算 = 漏换行 = 溢出）。
    static func charUnits(of text: String) -> Double {
        var units: Double = 0
        for scalar in text.unicodeScalars {
            units += isFullWidth(scalar) ? 1 : latinCharUnit
        }
        return units
    }

    /// 宽度封顶字号：以 `baseFontPT` 渲染 `text` 若超出可用宽，则按比例下调至恰好单行放满；
    /// 下限 7pt（更低交给换行估算与渲染期兜底）。**只缩不放**，空文本不缩。
    /// 渲染端（w:sz / 预览字号）与溢出估算（`estimatedRenderHeight`）共用——
    /// 估算与实际渲染用同一字号，估算不失真。
    static func fittedFontPT(text: String, availableWidthPT: Double, baseFontPT: Double) -> Double {
        let units = charUnits(of: text)
        guard units > 0, availableWidthPT > 0 else { return baseFontPT }
        return max(minFontPT, min(baseFontPT, availableWidthPT / units))
    }

    // MARK: - 溢出估算（保守，供引擎溢出阶梯 plan D6）

    /// 块渲染高度估算（文档页 pt）：逐行按 `fittedFontPT`（与渲染端同一字号）估算换行行数，
    /// 行距走实测（`k × 行高 + 行距` 累积，与逐行定位渲染模型一致）。
    ///
    /// 保守性来源：换行安全系数 `wrapSafetyFactor`、`ceil` 取整、宽度单位偏高估、
    /// 退化行高（≤ 0）回退字号标称行高。不换行时估算 = Σ实测行高 + Σ行距
    /// （无假阳性垂直溢出——零扰动不变量的前提）。
    ///
    /// - `gapToPrevious` 保留符号：行框垂直重叠（负行距）时与渲染模型同样累积。
    static func estimatedRenderHeight(
        lines: [BlockLine],
        blockWidth: Double,
        pageWidthPT: Double,
        pageHeightPT: Double,
        baseFontPT: Double
    ) -> Double {
        guard !lines.isEmpty else { return 0 }
        var total: Double = 0
        for (index, line) in lines.enumerated() {
            // 可用宽 = 块宽 − 行首偏移；退化（行首越出块界）时按 1pt 兜底，不产生发散值
            let available = max((blockWidth - line.leadingOffset) * pageWidthPT, 1)
            // T006（spec/scan-fidelity US1）：基准字号行级化 —— 有实测行高的行以该行
            // 行高推导字号（与渲染端 `lineFontPT` 同式同源：h × 页高pt × 1.05 钳制），
            // 无实测行高（合成行 height=0）回退调用方传入的块级 baseFontPT。
            // 估算与渲染同字号，异构行高块的换行估算不再系统性偏离实际渲染。
            let lineBase: Double
            if line.height > 0, pageHeightPT > 0 {
                lineBase = clampToFontRange(line.height * pageHeightPT * absorption)
            } else {
                lineBase = baseFontPT
            }
            let fitted = fittedFontPT(text: line.text, availableWidthPT: available, baseFontPT: lineBase)
            let estimatedWidth = charUnits(of: line.text) * fitted * wrapSafetyFactor
            let wrappedRows = max(1, Int(ceil(estimatedWidth / available)))
            let measuredPitch = line.height * pageHeightPT
            let pitch = measuredPitch > 0 ? measuredPitch : fitted * nominalLineHeightFactor
            total += Double(wrappedRows) * pitch
            if index > 0 {
                total += line.gapToPrevious * pageHeightPT
            }
        }
        return total
    }

    // MARK: - 行帧计算（plan D7：预览逐行定位渲染与断言共用）

    /// 块内行帧（归一化，与 bbox 同基准的 Vision y-up 矩形）：
    /// 首行顶贴块顶（`maxY == block.maxY`，T005 行采集约定），此后
    /// `top = 前行 rawBottom − gapToPrevious`（gap 保留符号——行框重叠为负）；
    /// `x = block.minX + leadingOffset`。**块内不越界**：行宽截到块右缘、
    /// 行底钉在块底（越界部分交由引擎溢出阶梯扩块，此处只保证几何不越界）；
    /// 累积游标用未夹取值——夹取只作用于输出，行间相对几何不失真。
    /// `lines` 为 nil/空 → 退化为整块单帧（调用方回退整块渲染的数据载体）。
    static func resolvedLineFrames(lines: [BlockLine]?, block: CGRect) -> [CGRect] {
        guard let lines, !lines.isEmpty else { return [block] }
        var frames: [CGRect] = []
        frames.reserveCapacity(lines.count)
        var cursorTop = block.maxY
        for (index, line) in lines.enumerated() {
            // gapToPrevious 属于当前行（前行底 → 本行顶的间距），在算本行帧之前扣除
            if index > 0 {
                cursorTop -= line.gapToPrevious
            }
            let height = max(0, line.height)
            let rawBottom = cursorTop - height
            // 垂直夹取：顶不超块顶（负 gap 上冲）、底不越块底
            let top = min(cursorTop, block.maxY)
            let bottom = max(rawBottom, block.minY)
            // 水平夹取：行首不越块左/右缘，行宽截到块右缘
            let x = min(max(block.minX + line.leadingOffset, block.minX), block.maxX)
            let width = max(0, min(line.width, block.maxX - x))
            frames.append(CGRect(x: x, y: bottom, width: width, height: max(0, top - bottom)))
            cursorTop = rawBottom
        }
        return frames
    }

    // MARK: - 私有

    private static func clampToFontRange(_ fontPT: Double) -> Double {
        min(max(fontPT, minFontPT), maxFontPT)
    }

    /// 全宽字符判定（CJK / 全角 / 谚文 / 假名等，宽度 ≈ 1 em）。
    private static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, // 谚文字母
             0x2E80...0xA4CF, // CJK 部首 / 汉字（含 ExtA）/ 注音 / 假名
             0xAC00...0xD7A3, // 谚文音节
             0xF900...0xFAFF, // CJK 兼容表意
             0xFE30...0xFE4F, // CJK 兼容形式
             0xFF00...0xFF60, // 全角形式（全角字母/数字/标点）
             0xFFE0...0xFFE6: // 全角符号
            return true
        default:
            return false
        }
    }
}
