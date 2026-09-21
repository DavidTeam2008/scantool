import Foundation

/// 归一化坐标 ↔ 目标空间（画布像素 / DOCX EMU）的线性映射参数（spec/layout-restore plan D6/D7）。
///
/// 纯值类型、可逆；Vision 的 **y 翻转收敛在此** —— 预览（LayoutCanvas）与 DOCX 导出
/// （动态 sectPr + 浮动定位）共用同一套换算。此前 y 翻转 / 单位换算散落在 view 与导出
/// 各自实现里（`1 px @96dpi = 9525 EMU`、posOffset 误用 twips 的教训见 `DocxExportService.emus`）。
struct PageLayoutMap: Equatable, Sendable {
    /// 源页像素尺寸（归一化坐标的参照系，aspect-fit 的比例来源）。
    let pageSize: CGSize
    /// 目标空间尺寸（目标单位：画布 px 或 EMU）。
    let targetSize: CGSize
    /// 统一缩放：目标单位 / 源像素（aspect-fit ⇒ 取两轴较小比例）。
    let scale: CGFloat
    /// aspect-fit 留白居中偏移（目标单位）。目标与源同比例时为 0 —— DOCX 动态页即此情形。
    let offset: CGPoint
    /// Vision 归一化 y 向上 → 目标 y 向下（画布 / EMU 均为左上原点）。
    let flipsY: Bool

    /// 归一化点 → 目标点。
    func point(_ normalized: CGPoint) -> CGPoint {
        let x = offset.x + normalized.x * pageSize.width * scale
        let y = flipsY
            ? offset.y + (1 - normalized.y) * pageSize.height * scale
            : offset.y + normalized.y * pageSize.height * scale
        return CGPoint(x: x, y: y)
    }

    /// Vision 归一化框（左下原点、y 向上）→ 目标框（左上原点、y 向下）。
    func rect(_ normalized: CGRect) -> CGRect {
        let x = offset.x + normalized.minX * pageSize.width * scale
        let y = flipsY
            ? offset.y + (1 - normalized.maxY) * pageSize.height * scale
            : offset.y + normalized.minY * pageSize.height * scale
        return CGRect(
            x: x,
            y: y,
            width: normalized.width * pageSize.width * scale,
            height: normalized.height * pageSize.height * scale
        )
    }

    /// 逆映射：目标点 → 归一化点（与 `point` 互逆）。
    func normalizedPoint(_ target: CGPoint) -> CGPoint {
        let unitWidth = max(pageSize.width * scale, 1e-12)
        let unitHeight = max(pageSize.height * scale, 1e-12)
        let x = (target.x - offset.x) / unitWidth
        let y = flipsY
            ? 1 - (target.y - offset.y) / unitHeight
            : (target.y - offset.y) / unitHeight
        return CGPoint(x: x, y: y)
    }

    /// 逆映射：目标框 → Vision 归一化框（与 `rect` 互逆）。
    func normalizedRect(_ target: CGRect) -> CGRect {
        let unitWidth = max(pageSize.width * scale, 1e-12)
        let unitHeight = max(pageSize.height * scale, 1e-12)
        let y = flipsY
            ? 1 - (target.maxY - offset.y) / unitHeight
            : (target.minY - offset.y) / unitHeight
        return CGRect(
            x: (target.minX - offset.x) / unitWidth,
            y: y,
            width: target.width / unitWidth,
            height: target.height / unitHeight
        )
    }
}

/// 归一化 bbox ↔ 画布像素 / DOCX EMU 的纯映射（spec/layout-restore plan D6/D7）。
///
/// 预览与 DOCX 导出共用：给定源页（像素）与目标空间，产出一个可逆的 `PageLayoutMap`。
enum PageLayoutMapper {
    /// Word 最大页尺寸：22in = 20_116_800 EMU（OOXML `w:pgSz` 上限）。
    static let wordMaximumPageEMU: CGFloat = 20_116_800
    /// 1 px @96dpi = 9525 EMU（914400 / 96），与 `DocxExportService.emus` 既有约定一致。
    static let emuPerPixel: CGFloat = 9525

    /// aspect-fit 映射：源页等比适配进 `targetSize`，留白居中（`offset`）。
    /// 目标与源同比例时退化为纯线性缩放（offset = 0）—— DOCX 动态页（sectPr 随原图比例）即此情形。
    /// 退化输入（任一边 ≤ 0）返回全零映射，保证任何变换结果有限（不产生 NaN/Inf）。
    static func map(pageSize: CGSize, targetSize: CGSize, flipsY: Bool = true) -> PageLayoutMap {
        guard pageSize.width > 0, pageSize.height > 0,
              targetSize.width > 0, targetSize.height > 0
        else {
            return PageLayoutMap(
                pageSize: pageSize,
                targetSize: targetSize,
                scale: 0,
                offset: .zero,
                flipsY: flipsY
            )
        }
        let scale = min(targetSize.width / pageSize.width, targetSize.height / pageSize.height)
        return PageLayoutMap(
            pageSize: pageSize,
            targetSize: targetSize,
            scale: scale,
            offset: CGPoint(
                x: (targetSize.width - pageSize.width * scale) / 2,
                y: (targetSize.height - pageSize.height * scale) / 2
            ),
            flipsY: flipsY
        )
    }

    /// 源页像素 → DOCX 动态页 EMU（plan D7：每页独立 sectPr，页面宽高比随原图）。
    /// 整页夹在 Word 最大页尺寸内并**保比例** —— 超大照片等比缩小，版面还原档的
    /// 页面比例始终与原图一致（映射退化为纯线性缩放，保真最优）。
    static func emuPageSize(for pageSize: CGSize) -> CGSize {
        let raw = CGSize(
            width: max(pageSize.width, 0) * emuPerPixel,
            height: max(pageSize.height, 0) * emuPerPixel
        )
        let longest = max(raw.width, raw.height)
        guard longest > wordMaximumPageEMU, longest > 0 else {
            return CGSize(width: raw.width.rounded(), height: raw.height.rounded())
        }
        let downscale = wordMaximumPageEMU / longest
        return CGSize(
            width: (raw.width * downscale).rounded(),
            height: (raw.height * downscale).rounded()
        )
    }
}
