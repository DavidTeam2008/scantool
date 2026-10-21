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
        reconstruct.notice(
            "tier=\(tier.rawValue, privacy: .public) isDefault=\(isDefault, privacy: .public)"
        )
    }

    /// 底座：路径尾段 + 像素尺寸。nil = 无底座（画布退化白底）。
    static func reconstructBaseImage(path: String?, pixelWidth: Int, pixelHeight: Int) {
        guard let path else {
            reconstruct.notice("baseImage=missing fallback=whiteCanvas")
            return
        }
        reconstruct.notice(
            "baseImage=\(path, privacy: .public) pixels=\(pixelWidth)x\(pixelHeight)"
        )
    }

    /// 覆盖 mask：覆盖矩形数 + 首个填充色采样（RGB 0~255）。
    static func reconstructMask(rectCount: Int, sampleColorRGB: (Int, Int, Int)?) {
        guard let sampleColorRGB else {
            reconstruct.notice("mask rectCount=\(rectCount) fill=none")
            return
        }
        reconstruct.notice(
            "mask rectCount=\(rectCount) fillRGB=\(sampleColorRGB.0),\(sampleColorRGB.1),\(sampleColorRGB.2)"
        )
    }

    /// 乱码区域判定：候选行数 / 证据墨块数 / 判定成立区域数 / 双门控证据值（最小 confidence）。
    static func reconstructArtwork(candidateLines: Int, inkEvidence: Int, confirmedRegions: Int, lowestConfidence: Double) {
        reconstruct.notice(
            "artwork candidateLines=\(candidateLines) inkEvidence=\(inkEvidence) confirmed=\(confirmedRegions) lowestConfidence=\(lowestConfidence, format: .fixed(precision: 3), privacy: .public)"
        )
    }

    /// 条码去重：去重前后计数（figure / barcode / URL 降级三通道归一）。
    static func reconstructDedup(beforeFigures: Int, beforeBarcodes: Int, afterFigures: Int, afterBarcodes: Int) {
        reconstruct.notice(
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
        reconstruct.notice(
            "layout yield count=\(count) totalShift=\(totalShift, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 跨栏宽行拆分：本页拆分的块数。
    static func layoutSplit(count: Int) {
        reconstruct.notice("layout split count=\(count)")
    }

    /// 溢出阶梯①缩放：块内文字按实测行高放不下，字号缩到能容纳为止
    /// （estimated ≤ available 后才走这条；estimated/available 为归一化页高）。
    static func layoutOverflowShrink(blockID: UUID, estimated: Double, available: Double) {
        reconstruct.notice(
            "layout overflowShrink block=\(blockID.uuidString, privacy: .public) estimated=\(estimated, format: .fixed(precision: 4), privacy: .public) available=\(available, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 溢出阶梯②扩展：缩放后仍溢出，bbox 向下扩展（expandBy = Δ 高度，归一化页高；
    /// 以页尾空白间隙封顶）。
    static func layoutOverflowExpand(blockID: UUID, expandBy: Double) {
        reconstruct.notice(
            "layout overflowExpand block=\(blockID.uuidString, privacy: .public) expandBy=\(expandBy, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 溢出阶梯③极端：扩展到空白上限仍放不下 —— 文字永不截断的保底路径
    /// （estimated/available 为归一化页高）。
    static func layoutOverflowExtreme(blockID: UUID, estimated: Double, available: Double) {
        reconstruct.notice(
            "layout overflowExtreme block=\(blockID.uuidString, privacy: .public) estimated=\(estimated, format: .fixed(precision: 4), privacy: .public) available=\(available, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 表格行高策略升级：exact → atLeast（某行内容放不下，整表行高转增长；
    /// triggeredByRow = 触发升级的行下标）。
    static func layoutTableGrowthUpgrade(blockID: UUID, triggeredByRow: Int) {
        reconstruct.notice(
            "layout tableGrowthUpgrade block=\(blockID.uuidString, privacy: .public) row=\(triggeredByRow)"
        )
    }

    /// figure 收缩：与 table 相让时 figure 被裁掉的高度（归一化页高；
    /// 收缩 = 裁剪保原像素比例，不缩放图像）。
    static func layoutFigureShrink(figureID: UUID, clipHeight: Double) {
        reconstruct.notice(
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
        capture.notice(
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
        capture.notice(
            "overlayProbeAnalytic viewSize=\(width, format: .fixed(precision: 1), privacy: .public)x\(height, format: .fixed(precision: 1), privacy: .public) scaleX=\(scaleX, format: .fixed(precision: 2), privacy: .public) scaleY=\(scaleY, format: .fixed(precision: 2), privacy: .public) offsetX=\(offsetX, format: .fixed(precision: 2), privacy: .public) offsetY=\(offsetY, format: .fixed(precision: 2), privacy: .public)"
        )
        guard let probe else {
            capture.notice("overlayProbeDelta probe=unavailable")
            return
        }
        let dScaleX = Double(analytic.scaleX - probe.scaleX)
        let dScaleY = Double(analytic.scaleY - probe.scaleY)
        let dOffsetX = Double(analytic.offsetX - probe.offsetX)
        let dOffsetY = Double(analytic.offsetY - probe.offsetY)
        capture.notice(
            "overlayProbeDelta dScaleX=\(dScaleX, format: .fixed(precision: 2), privacy: .public) dScaleY=\(dScaleY, format: .fixed(precision: 2), privacy: .public) dOffsetX=\(dOffsetX, format: .fixed(precision: 2), privacy: .public) dOffsetY=\(dOffsetY, format: .fixed(precision: 2), privacy: .public)"
        )
    }

    /// 候选择优：两级面积兜底触发层级（1 = 常规 0.96 上限；2 = 放宽 ≤1.0 兜底）。
    static func detectionTier(still: Bool, tier: Int, candidates: Int, selectedArea: Double) {
        capture.notice(
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
        capture.notice(
            "relaxedLiveProbe triggered=\(triggered, privacy: .public) candidates=\(candidates)"
        )
    }

    /// 可疑锁定判定：自动快门被抑制时的原因数值（面积 / 最小边距）。
    static func suspiciousLock(area: Double, minMargin: Double) {
        capture.notice(
            "suspiciousLock area=\(area, format: .fixed(precision: 4), privacy: .public) minMargin=\(minMargin, format: .fixed(precision: 4), privacy: .public) autoCapture=suppressed"
        )
    }

    // MARK: - 所见即所得裁切结构化诊断（spec/wysiwyg-crop，plan D4 / FR-009）
    //
    // 门禁与止跳的决策证据链：门禁决策每次文档模式快门一条（采纳/弃用静帧 +
    // 一致性度量值），粘滞仅在改写逐帧择优时一条。Console.app 按 subsystem
    // `com.david.Zhixia` + category `capture` 过滤（需勾选 Include Debug Messages），
    // 验收期间**实时抓取**（SC-005，上轮事后取证丢失 debug 日志的教训固化为流程）。

    /// 快门裁切一致性门禁决策：呈现框/静帧框面积 + 一致性 IoU + 静帧是否被采纳。
    /// `iou` 为 -1 表示无可度量对（呈现框或静帧框缺失，门禁走了直通分支）。
    /// 文档模式每次快门一条，摊开书/折页书验收时与成片对照读。
    static func cropGate(displayedArea: Double, stillArea: Double, iou: Double, acceptedStill: Bool) {
        capture.notice(
            "cropGate displayedArea=\(displayedArea, format: .fixed(precision: 4), privacy: .public) stillArea=\(stillArea, format: .fixed(precision: 4), privacy: .public) iou=\(iou, format: .fixed(precision: 4), privacy: .public) acceptedStill=\(acceptedStill, privacy: .public)"
        )
    }

    /// 整理页拍后增强诊断（spec/scan-enhance FR-001/002）：每页一行。
    /// `iou` = 静帧候选 vs 拍摄框（-1 = 无静帧候选）；`acceptedStill` =
    /// 身份锚定是否采纳；`aspect` = 四边形像素宽高比；`spineU/prominence/
    /// continuity` = 书脊谷（-1/0/0 = 未找到）；`splitApplied` = 是否拆为右页。
    static func refineStage(
        capturedArea: Double, stillArea: Double, iou: Double, acceptedStill: Bool,
        aspect: Double, reason: String, trimU: Double, trimDepth: Double,
        spineU: Double, prominence: Double, continuity: Double, splitApplied: Bool
    ) {
        capture.notice(
            "refineStage capturedArea=\(capturedArea, format: .fixed(precision: 4), privacy: .public) stillArea=\(stillArea, format: .fixed(precision: 4), privacy: .public) iou=\(iou, format: .fixed(precision: 4), privacy: .public) acceptedStill=\(acceptedStill, privacy: .public) aspect=\(aspect, format: .fixed(precision: 3), privacy: .public) reason=\(reason, privacy: .public) trimU=\(trimU, format: .fixed(precision: 4), privacy: .public) trimDepth=\(trimDepth, format: .fixed(precision: 3), privacy: .public) spineU=\(spineU, format: .fixed(precision: 4), privacy: .public) prominence=\(prominence, format: .fixed(precision: 3), privacy: .public) continuity=\(continuity, format: .fixed(precision: 3), privacy: .public) splitApplied=\(splitApplied, privacy: .public)"
        )
    }

    /// 候选粘滞改写逐帧择优（spec/frame-truth FR-008 增记面积）：
    /// `iou` = 改选框与当帧原始择优的 bbox IoU；`heldArea` = 改写后的框面积；
    /// `selectionArea` = 被拦截的原始择优面积。判读重点从 iou 移到面积比：
    /// 改写框面积 ≪ 择优面积（如 0.08 vs 0.45）＝ 小候选替换页面（病态）；
    /// 近似同档（Case B 右页/整书外轮廓）＝ 正常止跳。
    static func stickyOverride(iou: Double, heldArea: Double, selectionArea: Double) {
        capture.notice(
            "stickyOverride iou=\(iou, format: .fixed(precision: 4), privacy: .public) heldArea=\(heldArea, format: .fixed(precision: 4), privacy: .public) selectionArea=\(selectionArea, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 候选粘滞 hold-through-miss 维持帧（spec/case-b-sticky-v2，plan D1/D3）：
    /// 存在性交替（帧间候选池互斥）场景 miss 窗口内维持锚点的证据——
    /// `missCount` 当前连续 miss 计数、`heldArea` 被维持的锚点面积、
    /// `selectionArea` 被拦截的本帧择优面积。摊开书中线取景判读：hold 行与
    /// `detectionTier` 的 selectedArea 交替节奏互补出现（交替帧被锚住）；
    /// 连续 hold 后接 `stickyEscape` = 用户真移场；hold 行整段缺失而框仍跳
    /// = v2 未生效（对照 CandidateStickyV2Tests 是否绿）。上轮复测
    /// stickyOverride 整段缺失即 miss 路径零遥测所致，本通道补缺。
    static func stickyHold(missCount: Int, heldArea: Double, selectionArea: Double) {
        capture.notice(
            "stickyHold miss=\(missCount) heldArea=\(heldArea, format: .fixed(precision: 4), privacy: .public) selectionArea=\(selectionArea, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 候选粘滞达限逃逸：连续 miss 达上限清空锚点、透传新择优（FR-007
    /// 不粘死证据）；`afterMisses` = 触发清空时的连续 miss 计数（= missLimit）。
    /// 每次锚点放弃仅发射一条——锚点已弃的持续检测间隙不再重发
    /// （CandidateSticky 分支① `lastPick != nil` 守卫，审查 confirmed C1）；
    /// 判读：取景期短暂失焦/遮挡（≥3 连续零候选帧）会产生一条
    /// afterMisses=3 属设计内间隙逃逸，连发或 afterMisses≠3 才是异常。
    static func stickyEscape(afterMisses: Int) {
        capture.notice(
            "stickyEscape afterMisses=\(afterMisses)"
        )
    }

    /// 逐边吸附诊断（spec/frame-truth FR-004/008）：每次 EdgeSnapper.snap 每边
    /// 一行。`g0` = 边当前位置的对称梯度（双线性）；`outward`/`inward` = 两相
    /// 最强峰；`shift` = 实际位移（正=外推，负=内拉，0=不动）。
    /// 判读：左缘 `g0` 强且 shift=0 = s=0 守卫阻止了折脊外拉（预期新行为）；
    /// 左缘 shift 为负 = 内拉修正；shifts 全 0 = 该帧无有效梯度。
    static func snapEdge(edge: Int, g0: Double, outward: Double, inward: Double, shift: Double) {
        capture.notice(
            "snapEdge edge=\(edge) g0=\(g0, format: .fixed(precision: 3), privacy: .public) outward=\(outward, format: .fixed(precision: 3), privacy: .public) inward=\(inward, format: .fixed(precision: 3), privacy: .public) shift=\(shift, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 锁定吸附（spec/frame-truth FR-005：精修上屏）：锁定瞬间以当前帧检测为
    /// 种子做一次有界吸附，结果冻结为呈现框。记录修正前后面积与四角，
    /// 真机判读「锁定时的可见一跳」与「成片四角 = 冻结框四角」。
    static func snapOnLock(seedArea: Double, postArea: Double, seed: [Double], post: [Double]) {
        let seedCorners = seed.map { String(format: "%.4f", $0) }.joined(separator: ",")
        let postCorners = post.map { String(format: "%.4f", $0) }.joined(separator: ",")
        capture.notice(
            "snapOnLock seedArea=\(seedArea, format: .fixed(precision: 4), privacy: .public) postArea=\(postArea, format: .fixed(precision: 4), privacy: .public) seed=[\(seedCorners, privacy: .public)] post=[\(postCorners, privacy: .public)]"
        )
    }

    /// 快门四角快照（spec/frame-truth FR-008）：`tag` = "displayed" / "still"；
    /// 四个角按 TL,TR,BR,BL 顺序展开（照片空间归一化坐标）。
    static func cropQuad(tag: String, quad: Quad?) {
        guard let quad else {
            capture.notice("cropQuad tag=\(tag, privacy: .public) quad=nil")
            return
        }
        let values = [quad.topLeft.x, quad.topLeft.y,
                      quad.topRight.x, quad.topRight.y,
                      quad.bottomRight.x, quad.bottomRight.y,
                      quad.bottomLeft.x, quad.bottomLeft.y]
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        capture.notice("cropQuad tag=\(tag, privacy: .public) corners=[\(values, privacy: .public)]")
    }

    /// 候选来源遥测（spec/frame-truth FR-008）：live 每帧一行——上一周期的
    /// 两轮复盘最大的盲区就是「池里有没有页面、门控是否触发」只能靠猜。
    /// 面积均为视频 FOV 归一化空间；`preStickySelectionArea` 是粘滞前择优。
    static func candidateProvenance(
        strictCount: Int, strictMaxArea: Double,
        segArea: Double, relaxedCount: Int, relaxedMaxArea: Double,
        viableCount: Int, viableMaxArea: Double,
        gateSeg: Bool, gateRelaxed: Bool,
        preStickySelectionArea: Double, disposition: String, heldArea: Double
    ) {
        capture.notice(
            "candidateProvenance strictCount=\(strictCount, privacy: .public) strictMaxArea=\(strictMaxArea, format: .fixed(precision: 4), privacy: .public) segArea=\(segArea, format: .fixed(precision: 4), privacy: .public) relaxedCount=\(relaxedCount, privacy: .public) relaxedMaxArea=\(relaxedMaxArea, format: .fixed(precision: 4), privacy: .public) viableCount=\(viableCount, privacy: .public) viableMaxArea=\(viableMaxArea, format: .fixed(precision: 4), privacy: .public) gateSeg=\(gateSeg, privacy: .public) gateRelaxed=\(gateRelaxed, privacy: .public) preStickySelectionArea=\(preStickySelectionArea, format: .fixed(precision: 4), privacy: .public) disposition=\(disposition, privacy: .public) heldArea=\(heldArea, format: .fixed(precision: 4), privacy: .public)"
        )
    }

    /// 候选快照摘要（spec/guided-capture T002 / FR-007）：**每帧一条** debug 行——
    /// 与 `candidateProvenance` 正交：那条记「候选从哪来、门控是否触发」，这条记
    /// 「池里留下了什么、丢了多少、谁在生效」。判读要点：
    /// - `viable=0` → 本帧池里没有页面尺度候选（检测问题）；
    /// - `viable>0` 且 `selectionArea` ≫ 单页面积 → 整书赢下择优（评分/意图问题）；
    /// - `dropped>0` → 候选多于硬上限 16，细节看诊断包 JSON。
    static func candidateDump(
        path: String,
        rawCount: Int,
        viableCount: Int,
        droppedCount: Int,
        topArea: Double,
        selectionArea: Double,
        disposition: String?
    ) {
        capture.debug(
            "candidateDump path=\(path, privacy: .public) raw=\(rawCount) viable=\(viableCount) dropped=\(droppedCount) topArea=\(topArea, format: .fixed(precision: 4), privacy: .public) selectionArea=\(selectionArea, format: .fixed(precision: 4), privacy: .public) disposition=\(disposition ?? "none", privacy: .public)"
        )
    }

    // MARK: - 版面还原对标 WPS 结构化诊断（spec/wps-parity-layout，plan D5/D9 / FR-002、FR-006）    //
    // 两个可观测通道，真机验收（SC-002/SC-006）用 Console.app 检索：
    // - `reconstructPath`：每页解析的通路决策（结构化 vs 几何回退 + 原因分类）；
    // - `textSentinel`：导出前墨迹-文本对账的缺口汇总（四分类计数，只记不阻断）。
    // 均为 debug 级 + privacy.public，与 `detectionTier`/`cropGate` 模式一致
    // （需勾选 Include Debug Messages）。

    /// 每页解析的通路决策结果（plan D9）。
    enum ReconstructPath: String, Sendable {
        /// iOS 26 `RecognizeDocumentsRequest` 结构化识别生效
        case structured
        /// Vision OCR + 几何管线回退
        case geometric
    }

    /// 通路决策原因分类（plan D9：API 不可用/请求异常/结果无效/结构化成功/低版本回退）。
    enum ReconstructPathReason: String, Sendable {
        /// 结构化识别成功生效（structured 通路）
        case structuredSuccess
        /// 结构化识别器未注入（这条通路在当前构建/环境里不存在）
        case apiUnavailable
        /// `RecognizeDocumentsRequest` 请求抛错
        case requestFailed
        /// 识别返回但结果无效（无 container / 无可用内容）
        case invalidResult
        /// iOS < 26，`RecognizeDocumentsRequest` 不存在，直接走几何回退
        case lowVersionFallback
    }

    /// 通路决策日志：每页解析恰一条。发射点 = `OnDeviceDocumentParser.resolveInputs`
    /// 决策出口与 `VisionDocumentStructureRecognizer` 失败捕获点。
    /// 页标识用 pageID（`DocumentParsing` 协议签名冻结，解析层拿不到页索引；
    /// 与 `reconstructBaseImage` 的像素尺寸行按 pageID 对账）。
    static func reconstructPath(pageID: UUID, path: ReconstructPath, reason: ReconstructPathReason) {
        reconstruct.notice(
            "reconstructPath page=\(pageID.uuidString, privacy: .public) path=\(path.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
    }

    /// 丢字哨兵日志（FR-006）：导出前墨迹-文本对账汇总，每页一条。
    /// 四分类计数来自 `MissingTextReport`：figureOverlap（图形区属预期）/
    /// structureSwallow（结构吞噬违规）/ edgeBand（页缘带）/ likelyMissed（疑似
    /// OCR 漏识）。只记日志不阻断导出；gaps = 总缺口数（四分类之和）。
    static func textSentinel(
        page: Int,
        gaps: Int,
        figureOverlap: Int,
        structureSwallow: Int,
        edgeBand: Int,
        likelyMissed: Int
    ) {
        reconstruct.notice(
            "textSentinel page=\(page) gaps=\(gaps) figureOverlap=\(figureOverlap) structureSwallow=\(structureSwallow) edgeBand=\(edgeBand) likelyMissed=\(likelyMissed)"
        )
    }

    /// containment 不变量（FR-004）：本页被表格/条码 bbox 剔除的行数（removed）
    /// 与其中「结构未携带其文字、保留回文字层」的救回数（rescued）。
    /// rescued > 0 = 有行的文字不在结构输出里 —— 静默丢字被拦截的第一手计数，
    /// 真机排查丢字时先看这条。
    static func reconstructContainment(removed: Int, rescued: Int) {
        reconstruct.notice(
            "containment removed=\(removed) rescued=\(rescued, privacy: .public)"
        )
    }
}
