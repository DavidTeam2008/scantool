import CoreGraphics
import Foundation
import os

enum ZhixiaLog {
    static let capture = Logger(subsystem: "com.david.Zhixia", category: "capture")
    static let store = Logger(subsystem: "com.david.Zhixia", category: "store")
    static let image = Logger(subsystem: "com.david.Zhixia", category: "image")
    /// 还原链路（spec/layout-restore plan D10）。真机验收（SC-001/002）与
    /// 乱码判定阈值调优依赖这些数值 —— 判定是本轮最大的启发式风险点，可观测性优先。
    /// Console.app 按 subsystem `com.david.Zhixia` + category `reconstruct` 过滤。
    static let reconstruct = Logger(subsystem: "com.david.Zhixia", category: "reconstruct")

    // MARK: - 还原链路结构化诊断（spec/layout-restore，plan D10）

    /// 档位与切换：当前档位 + 是否默认档。
    static func reconstructTier(_ tier: R2OutputTier, isDefault: Bool) {
        reconstruct.debug(
            "tier=\(tier.rawValue, privacy: .public) isDefault=\(isDefault, privacy: .public)"
        )
    }

    /// 底座：路径尾段 + 像素尺寸。nil = 无底座（画布退化白底）。
    static func reconstructBaseImage(path: String?, pixelWidth: Int, pixelHeight: Int) {
        guard let path else {
            reconstruct.debug("baseImage=missing fallback=whiteCanvas")
            return
        }
        reconstruct.debug(
            "baseImage=\(path, privacy: .public) pixels=\(pixelWidth)x\(pixelHeight)"
        )
    }

    /// 覆盖 mask：覆盖矩形数 + 首个填充色采样（RGB 0~255）。
    static func reconstructMask(rectCount: Int, sampleColorRGB: (Int, Int, Int)?) {
        guard let sampleColorRGB else {
            reconstruct.debug("mask rectCount=\(rectCount) fill=none")
            return
        }
        reconstruct.debug(
            "mask rectCount=\(rectCount) fillRGB=\(sampleColorRGB.0),\(sampleColorRGB.1),\(sampleColorRGB.2)"
        )
    }

    /// 乱码区域判定：候选行数 / 证据墨块数 / 判定成立区域数 / 双门控证据值（最小 confidence）。
    static func reconstructArtwork(candidateLines: Int, inkEvidence: Int, confirmedRegions: Int, lowestConfidence: Double) {
        reconstruct.debug(
            "artwork candidateLines=\(candidateLines) inkEvidence=\(inkEvidence) confirmed=\(confirmedRegions) lowestConfidence=\(lowestConfidence, format: .fixed(precision: 3), privacy: .public)"
        )
    }

    /// 条码去重：去重前后计数（figure / barcode / URL 降级三通道归一）。
    static func reconstructDedup(beforeFigures: Int, beforeBarcodes: Int, afterFigures: Int, afterBarcodes: Int) {
        reconstruct.debug(
            "dedup figures \(beforeFigures)→\(afterFigures) barcodes \(beforeBarcodes)→\(afterBarcodes)"
        )
    }

    // MARK: - 布局引擎结构化诊断（spec/layout-engine，plan D10 / FR-006、FR-011）
    //
    // 与 tier/baseImage/mask/artwork/dedup 并列，debug 级。让位/平移/拆分/溢出阶梯
    // 的每一次触发都必须真机现场可读 —— Console.app 过滤 subsystem
    // `com.david.Zhixia` + category `reconstruct`（需勾选 Include Debug Messages）。
    // 块 ID 用 uuidString（os.Logger 没有 UUID 的插值重载）。

    /// 碰撞消解：本轮让位块数与总平移量（平移量为归一化页高单位，一轮消解一条）。
    static func layoutYield(count: Int, totalShift: Double) {
        reconstruct.debug(
            "layout yield count=\(count) totalShift=\(totalShift, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 跨栏宽行拆分：本页拆分的块数。
    static func layoutSplit(count: Int) {
        reconstruct.debug("layout split count=\(count)")
    }

    /// 溢出阶梯①缩放：块内文字按实测行高放不下，字号缩到能容纳为止
    /// （estimated ≤ available 后才走这条；estimated/available 为归一化页高）。
    static func layoutOverflowShrink(blockID: UUID, estimated: Double, available: Double) {
        reconstruct.debug(
            "layout overflowShrink block=\(blockID.uuidString, privacy: .public) estimated=\(estimated, format: .fixed(precision: 4), privacy: .public) available=\(available, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 溢出阶梯②扩展：缩放后仍溢出，bbox 向下扩展（expandBy = Δ 高度，归一化页高；
    /// 以页尾空白间隙封顶）。
    static func layoutOverflowExpand(blockID: UUID, expandBy: Double) {
        reconstruct.debug(
            "layout overflowExpand block=\(blockID.uuidString, privacy: .public) expandBy=\(expandBy, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 溢出阶梯③极端：扩展到空白上限仍放不下 —— 文字永不截断的保底路径
    /// （estimated/available 为归一化页高）。
    static func layoutOverflowExtreme(blockID: UUID, estimated: Double, available: Double) {
        reconstruct.debug(
            "layout overflowExtreme block=\(blockID.uuidString, privacy: .public) estimated=\(estimated, format: .fixed(precision: 4), privacy: .public) available=\(available, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 表格行高策略升级：exact → atLeast（某行内容放不下，整表行高转增长；
    /// triggeredByRow = 触发升级的行下标）。
    static func layoutTableGrowthUpgrade(blockID: UUID, triggeredByRow: Int) {
        reconstruct.debug(
            "layout tableGrowthUpgrade block=\(blockID.uuidString, privacy: .public) row=\(triggeredByRow)"
        )
    }

    /// figure 收缩：与 table 相让时 figure 被裁掉的高度（归一化页高；
    /// 收缩 = 裁剪保原像素比例，不缩放图像）。
    static func layoutFigureShrink(figureID: UUID, clipHeight: Double) {
        reconstruct.debug(
            "layout figureShrink figure=\(figureID.uuidString, privacy: .public) clipHeight=\(clipHeight, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    // MARK: - 扫描框边精度结构化诊断（spec/scan-edge-accuracy，plan D10 / FR-007）
    //
    // 仅调试日志，无行为分支依赖。真机现场排障依赖这些数值——上两轮问题
    // （虚线框 3.86× 拉伸 / 框系统性偏窄）的定位成本主要耗在猜测设备行为上，
    // 这些条目让「视频帧宽高比 / 照片宽高比 / 探针映射参数 / 候选层级 / 可疑判定」
    // 在真机上全部可读（Console.app 按 subsystem `com.david.Zhixia` 过滤）。

    /// 取景几何：视频流帧与照片输出的竖屏宽高比（运行时实测，不硬编码）。
    static func geometry(video: Double, photo: Double) {
        capture.debug(
            "geometry videoAspect=\(video, format: .fixed(precision: 4), privacy: .public) photoAspect=\(photo, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// overlay 映射诊断对照（T019/T022，FR-007 / SC-004 证据链）：`analytic` 是
    /// 渲染真值（照片→视频→屏幕解析链的仿射参数，`OverlaySpaceMap` 推导）；
    /// `probe` 是退役探针（`layerRectConverted`）的实测值，nil = 探针不可用。
    /// delta 行为两者逐轴偏差 —— 真机验收直接读数比对；探针再失效也只影响
    /// 对照行，不影响边框渲染（探针已降级为诊断源）。
    static func overlayProbeAnalytic(viewSize: CGSize, analytic: QuadSpaceTransform, probe: QuadSpaceTransform?) {
        let width = Double(viewSize.width)
        let height = Double(viewSize.height)
        let scaleX = Double(analytic.scaleX)
        let scaleY = Double(analytic.scaleY)
        let offsetX = Double(analytic.offsetX)
        let offsetY = Double(analytic.offsetY)
        capture.debug(
            "overlayProbeAnalytic viewSize=\(width, format: .fixed(precision: 1), privacy: .public)x\(height, format: .fixed(precision: 1), privacy: .public) scaleX=\(scaleX, format: .fixed(precision: 2), privacy: .public) scaleY=\(scaleY, format: .fixed(precision: 2), privacy: .public) offsetX=\(offsetX, format: .fixed(precision: 2), privacy: .public) offsetY=\(offsetY, format: .fixed(precision: 2), privacy: .public)"
        )
        guard let probe else {
            capture.debug("overlayProbeDelta probe=unavailable")
            return
        }
        let dScaleX = Double(analytic.scaleX - probe.scaleX)
        let dScaleY = Double(analytic.scaleY - probe.scaleY)
        let dOffsetX = Double(analytic.offsetX - probe.offsetX)
        let dOffsetY = Double(analytic.offsetY - probe.offsetY)
        capture.debug(
            "overlayProbeDelta dScaleX=\(dScaleX, format: .fixed(precision: 2), privacy: .public) dScaleY=\(dScaleY, format: .fixed(precision: 2), privacy: .public) dOffsetX=\(dOffsetX, format: .fixed(precision: 2), privacy: .public) dOffsetY=\(dOffsetY, format: .fixed(precision: 2), privacy: .public)"
        )
    }

    /// 候选择优：两级面积兜底触发层级（1 = 常规 0.96 上限；2 = 放宽 ≤1.0 兜底）。
    static func detectionTier(still: Bool, tier: Int, candidates: Int, selectedArea: Double) {
        capture.debug(
            "detectionTier path=\(still ? "still" : "live", privacy: .public) tier=\(tier) candidates=\(candidates) selectedArea=\(selectedArea, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    // MARK: - live 三级检测兜底结构化诊断（spec/live-edge-crop，plan D3 / FR-007）
    //
    // 与 `detectionTier` 语义正交：tier 是「两级面积兜底」的档位，本通道是
    // 「第三级放宽矩形」的触发探针——两者不得合并（复用会污染既有验收对照口径）。
    // Console.app 检索 `relaxedLiveProbe`：触发率 = triggered=true 行数 ÷ 本日志
    // 总行数（live 每帧一行，含未触发帧），命中质量看 candidates 数（SC-005）。

    /// live 放宽矩形档探针：`triggered` = 本帧是否触发放宽重跑（严格矩形 +
    /// 文档分割双落空），`candidates` = 放宽档命中候选数（未触发恒 0）。
    /// still 路径不记录（首跑已是放宽参数，无第三级概念）。
    static func relaxedLiveProbe(triggered: Bool, candidates: Int) {
        capture.debug(
            "relaxedLiveProbe triggered=\(triggered, privacy: .public) candidates=\(candidates)"
        )
    }

    /// 可疑锁定判定：自动快门被抑制时的原因数值（面积 / 最小边距）。
    static func suspiciousLock(area: Double, minMargin: Double) {
        capture.debug(
            "suspiciousLock area=\(area, format: .fixed(precision: 4), privacy: .public) minMargin=\(minMargin, format: .fixed(precision: 4), privacy: .public) autoCapture=suppressed"
        )
    }
}
