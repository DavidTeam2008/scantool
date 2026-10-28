import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// 候选择优策略（spec/scan-edge-accuracy，plan D4/D5，FR-001~003）——纯函数，
/// live（`detect(frame:)`）与 still（`detect(imageData:)`）两条路径共用，也便于单测。
///
/// 两项修复：
/// 1. **两级面积兜底**：一级维持现状上限 0.96；为空时二级放宽到 ≤1.0
///    （允许贴边/近满幅——近拍书占满画面的真实外框不再被静默过滤）。
///    混合候选池下 0.96 上限照旧生效（整幅误检防护不变）。
/// 2. **包含降权**：被另一候选高度包含（≥0.9）的内部矩形评分 ×0.35，
///    使外框候选在同一候选集内必胜（封面设计框/文字块不再反超）。
enum DetectionStrategy {
    /// 一级面积上限（现状值，过滤整幅误检）。
    static let primaryMaxArea: Double = 0.96
    /// 二级面积上限（一级为空时放宽到近满幅）。
    static let fallbackMaxArea: Double = 1.0
    /// 触发包含降权的包含度阈值。
    static let containmentThreshold: Double = 0.9
    /// 被包含候选的评分乘数（plan D5：约 0.35）。
    static let containmentPenalty: Double = 0.35
    /// 候选面积下限（现状值；视频 FOV 归一化面积）。
    static let minArea: Double = 0.08
    /// 「页面档」面积下限（spec/frame-truth FR-002，视频 FOV 归一化面积）：
    /// 只有页面尺度的矩形才有资格否决文档分割/放宽档。0.08–0.24 的文字带/
    /// 折痕条不再让两级恢复通道同时关闭（真机证据：0.08–0.093 带子一票否决）。
    /// 与 `minArea` 解耦是刻意的——保留远摄检测能力与「太远」引导语义。
    static let pageLikeMinArea: Double = 0.25

    struct Selection: Equatable {
        var quad: Quad
        /// 1 = 常规 0.96 上限；2 = 放宽 ≤1.0 兜底（经 `ZhixiaLog.detectionTier` 记录）。
        var tier: Int
    }

    /// 候选池单一真源（spec/frame-truth FR-001）：非退化 + 面积下限过滤。
    ///
    /// `select` 与 live 粘滞调用点**必须**共用本函数——上一周期的缺陷正是
    /// sticky 分支④从**未过滤**的 rawCandidates 改选，能把 select 已淘汰的
    /// 亚 minArea/退化候选重新推上屏（真机 selectedArea 0.056–0.077 的来源）。
    /// 注意：本函数不按两级面积 tier 截断（调用点需要完整 viable 集合）。
    static func viablePool(_ rawCandidates: [Quad]) -> [Quad] {
        rawCandidates.filter { !$0.isDegenerate && $0.area > minArea }
    }

    /// 对原始候选集执行「非退化/面积下限过滤 → 两级面积兜底 → 包含降权择优」。
    /// 证件窗口（比例窗）路径保持现状语义：IoU 匹配优先，无匹配返回窗口本身（FR-013）。
    static func select(rawCandidates: [Quad], idCardWindow: Quad?) -> Selection? {
        let viable = viablePool(rawCandidates)
        let (pool, tier) = twoTierPool(viable)

        if let window = idCardWindow {
            if let match = pool
                .filter({ $0.iou(with: window) > 0.45 })
                .max(by: { $0.score() < $1.score() })
            {
                return Selection(quad: match, tier: tier)
            }
            return Selection(quad: window, tier: tier)
        }

        guard let best = bestCandidate(in: pool) else { return nil }
        return Selection(quad: best, tier: tier)
    }

    /// 两级面积兜底（plan D4）：一级 0.96 上限过滤；为空时二级放宽至 ≤1.0。
    private static func twoTierPool(_ viable: [Quad]) -> (pool: [Quad], tier: Int) {
        let tier1 = viable.filter { $0.area < primaryMaxArea }
        if !tier1.isEmpty {
            return (tier1, 1)
        }
        return (viable.filter { $0.area <= fallbackMaxArea }, 2)
    }

    /// live 条件性文档分割门控（plan D6 / FR-004；spec/frame-truth FR-002 改口径）：
    /// 仅当矩形检测**无页面档候选**（无非退化且 area ≥ `pageLikeMinArea` 的候选）
    /// 时才补跑 `VNDetectDocumentSegmentationRequest`。
    ///
    /// 文档分割是神经网络请求，逐帧必跑在部分设备上会压帧率；矩形检测「找不到
    /// 页面」恰是书类目标（圆角/低对比度）的失效信号——条件触发把算力花在
    /// 需要的帧上。上一周期用 minArea(0.08) 作口径，一个 0.08–0.09 的文字带
    /// 就能把两级恢复通道同时关闭（真机 candidates 常=1 的成因）——改为页面
    /// 先验后，带子不再有一票否决权，页面每帧都有机会进入候选池。
    /// 检测器 actor 忙时丢帧机制（ViewModel 侧 `isDetecting`）不受影响。
    static func needsDocumentSegmentation(rectangles: [Quad]) -> Bool {
        !rectangles.contains { !$0.isDegenerate && $0.area >= pageLikeMinArea }
    }

    /// live 第三级「放宽矩形」门控（spec/live-edge-crop，plan D2 / FR-001~002）：
    /// 仅当严格矩形无可信候选（复用 `needsDocumentSegmentation` 的判定口径）
    /// **且**文档分割也无结果（`segmented == nil`）时返回 true。
    ///
    /// 折页厚书的曲面页边缘不满足矩形检测的直线假设——前两级长期落空正是
    /// 该场景的失效信号；把放宽参数的重跑算力只花在两级都失败的帧上，
    /// 不得逐帧常开（FR-002）。与 `needsDocumentSegmentation` 同风格、同位置，
    /// 触发组合可穷举单测（见 `EdgeDetectionStrategyTests`）。
    static func needsRelaxedRectangles(rectangles: [Quad], segmented: Quad?) -> Bool {
        needsDocumentSegmentation(rectangles: rectangles) && segmented == nil
    }

    /// 择优：`score = 面积 × 居中 × 方正`（评分函数不动），叠加包含降权。
    ///
    /// - 近重复候选（互包含 ≥0.9，如矩形检测与文档分割命中同一外框）不互相压分。
    /// - FR-003 保障：降权不得让结果退化到比「未降权最优」更小的框——
    ///   未降权最优被降权、且降权后赢家反而更小时，改选其最大容器（外框必胜）。
    static func bestCandidate(in pool: [Quad]) -> Quad? {
        guard let plainBest = pool.max(by: { $0.score() < $1.score() }) else { return nil }

        func isPenalized(_ candidate: Quad) -> Bool {
            pool.contains { other in
                other != candidate
                    && candidate.containment(in: other) >= containmentThreshold
                    && other.containment(in: candidate) < containmentThreshold
            }
        }

        let adjusted = pool.map { candidate -> (quad: Quad, score: Double) in
            var score = candidate.score()
            if isPenalized(candidate) {
                score *= containmentPenalty
            }
            return (candidate, score)
        }
        guard let winner = adjusted.max(by: { $0.score < $1.score })?.quad else { return nil }

        if isPenalized(plainBest), winner.area < plainBest.area {
            let containers = pool.filter {
                $0 != plainBest
                    && plainBest.containment(in: $0) >= containmentThreshold
                    && $0.containment(in: plainBest) < containmentThreshold
            }
            if let largestContainer = containers.max(by: { $0.area < $1.area }) {
                return largestContainer
            }
        }
        return winner
    }

    /// 静帧路径的**页面判定**（spec/word-fidelity T001）——纯函数，可单测。
    ///
    /// 返回 `nil` = **不裁**（整幅照片就是页面；调用方回退 `.fullImage`）。
    ///
    /// ## 背景（实证：`docs/media/IMG_7544.jpg`，2026-10-22 取证）
    /// 教科书页的照片里，页面**外框检不出**：
    /// 1. 矩形检测（宽松档：置信 0.35 / 最小边 0.08 / 最多 8 个）只找到页面
    ///    **里面**的表格框（0.098）、照片区（0.133）、色块（0.081）、底边条
    ///    （0.250）——**整页框一次都没出现**（书页边缘不直 + 透视 + 页面
    ///    充满取景 → 没有可检出的矩形边缘）；
    /// 2. 文档分割在部分运行里只给出**底边一条**（0.248）而不是整页（0.978）。
    /// 于是「两级面积兜底 + 评分」必然落到页面里的某个子框 → **整页被裁成
    /// 一小块**（用户实测「程序只识别了右页的一部分」）。
    ///
    /// ## 判据（按优先级）
    /// 1. **大候选**（面积 ≥ `areaFloor` = 0.5）：它就是页面 → 用它；
    /// 2. **候选铺满整幅**（候选并集外接框面积 ≥ `spreadFloor` = 0.6）：内容
    ///    铺满画面（页面充满取景），任何子框都是错的 → **不裁**（整图当页面；
    ///    精确裁切交给用户：Review 拖角 / 引导取景框）；
    /// 3. 否则：文档是画面里的**子区域**（桌面上的票据/收据）→ 取面积最大的候选。
    ///
    /// ## 为什么「宁可不裁」
    /// 裁错 = **内容丢失**（不可逆）；不裁 = 画面里多了背景（可逆，用户随时
    /// 手动裁 / 用引导框）。判据 2 优先于判据 1 的理由同此：子框永远不是页面。
    static func stillPageCandidate(
        viable: [Quad],
        areaFloor: Double = 0.5,
        spreadFloor: Double = 0.6
    ) -> Quad? {
        guard !viable.isEmpty else { return nil }
        let largest = viable.max { $0.area < $1.area }
        guard let largest else { return nil }
        // ① 大候选 = 页面。
        if largest.area >= areaFloor {
            return largest
        }
        // ② 候选铺满整幅 → 整幅就是页面 → 不裁。
        let spread = viable.reduce(CGRect.null) { $0.union($1.boundingRect) }
        if !spread.isNull, spread.width * spread.height >= spreadFloor {
            return nil
        }
        // ③ 文档是子区域 → 取最大候选。
        return largest
    }
}

actor VisionEdgeDetector: EdgeDetecting, EnvelopeDetecting, CandidateSnapshotReporting {
    /// 候选粘滞状态（仅 live 文档路径使用；actor 串行访问保证状态安全）。
    private var sticky = CandidateSticky()
    /// 页面意图解析的透视矫正上下文（仅左/右页意图需要，actor 串行持有）。
    private let intentCIContext = CIContext(options: [.useSoftwareRenderer: false])

    #if DEBUG
    /// 候选快照回调（spec/guided-capture T002 / FR-007）：默认 nil = **零开销**
    /// （不构造快照、不排序、不分配）。订阅后才逐帧发出。
    private var candidateSnapshotHandler: (@Sendable (CandidateSnapshot) -> Void)?
    /// 最近一次已发出的快照（供调用方按帧取用）。
    private var lastCandidateSnapshot: CandidateSnapshot?
    #endif

    // MARK: - 候选快照订阅（T002 / FR-007）

    func setCandidateSnapshotHandler(_ handler: (@Sendable (CandidateSnapshot) -> Void)?) async {
        #if DEBUG
        candidateSnapshotHandler = handler
        #endif
    }

    func latestCandidateSnapshot() async -> CandidateSnapshot? {
        #if DEBUG
        return lastCandidateSnapshot
        #else
        return nil
        #endif
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        detect(
            cgImage: frame.cgImage,
            orientation: .up,
            idCardWindow: idCardWindow,
            stillImage: false,
            intent: .wholePage
        )
    }

    /// P0.2 / CU-T003：带页面意图的 live 检测。整页路径完全沿用旧语义；
    /// 左/右页路径会在候选池里生成书脊拆分/左折条裁切目标。
    func detect(
        frame: VideoFrame,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> Quad? {
        detect(
            cgImage: frame.cgImage,
            orientation: .up,
            idCardWindow: idCardWindow,
            stillImage: false,
            intent: intent
        )
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? {
        await detect(imageData: imageData, idCardWindow: idCardWindow, intent: .wholePage)
    }

    func detect(
        imageData: Data,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> Quad? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return detect(
            cgImage: image,
            orientation: imageOrientation(from: source),
            idCardWindow: idCardWindow,
            stillImage: true,
            intent: intent
        )
    }

    func resetLiveTracking() async {
        sticky.reset()
    }

    // MARK: - CF-T002/CF-T003：实时包络观测

    /// 每帧只做一次低成本观测，返回：
    /// - `envelope`：整摊/书/单页外轮廓，供 overlay 持续显示；
    /// - `target`：左/右页输出目标（找不到时 nil，但 envelope 仍然存在）。
    ///
    /// 这里不使用 `CandidateSticky`：粘滞是单 quad 选择器，而包络跟踪由
    /// `CaptureEnvelopeTracker` 做时域融合；检测器只负责给当前帧的原始观测，
    /// 避免“目标页缺失 → detect 返回 nil → 屏幕无框”的旧链路。
    func observeEnvelope(
        frame: VideoFrame,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> CaptureEnvelopeObservation? {
        guard idCardWindow == nil else { return nil }
        let cgImage = frame.cgImage
        let orientation: CGImagePropertyOrientation = .up
        let rectangles = detectRectangles(
            cgImage: cgImage,
            orientation: orientation,
            relaxed: false
        )
        // 页面意图需要整摊外框来拆左右页；即使矩形检测已经给出一个单页，
        // 也补一次文档分割。整页路径沿用现有“无页面候选才补分割”的门控。
        let needsSpreadForIntent = intent != .wholePage
            && !rectangles.contains(where: PageIntentResolver.isSpreadLike)
        let gateSeg = DetectionStrategy.needsDocumentSegmentation(rectangles: rectangles)
            || needsSpreadForIntent
        let segmented: Quad? = gateSeg
            ? detectDocumentQuad(cgImage: cgImage, orientation: orientation)
            : nil

        var relaxedRectangles: [Quad] = []
        if DetectionStrategy.needsRelaxedRectangles(rectangles: rectangles, segmented: segmented) {
            relaxedRectangles = detectRectangles(
                cgImage: cgImage,
                orientation: orientation,
                relaxed: true
            )
        }
        let rawCandidates = [segmented].compactMap { $0 } + rectangles + relaxedRectangles
        let selection = DetectionStrategy.select(rawCandidates: rawCandidates, idCardWindow: nil)
        guard let envelope = PageIntentResolver.envelope(
            selection: selection?.quad,
            candidates: rawCandidates
        ) else { return nil }

        var target: Quad? = envelope
        var intentSatisfied = true
        if intent != .wholePage {
            let resolution = PageIntentResolver.resolve(
                selection: selection?.quad,
                candidates: rawCandidates,
                intent: intent,
                image: cgImage,
                ciContext: intentCIContext
            )
            target = resolution?.quad
            intentSatisfied = resolution != nil
        }

        // 面积给出保守置信度；真正的连续/锁定状态由 tracker 决定。
        let confidence = min(1, max(0.2, envelope.area * 1.5))
        return CaptureEnvelopeObservation(
            envelope: envelope,
            target: target,
            confidence: confidence,
            intentSatisfied: intentSatisfied
        )
    }

    func resetEnvelopeTracking() async {
        sticky.reset()
    }

    private func detect(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        idCardWindow: Quad?,
        stillImage: Bool,
        intent: CaptureIntent
    ) -> Quad? {
        let rectangles = detectRectangles(
            cgImage: cgImage,
            orientation: orientation,
            relaxed: stillImage
        )
        // 分割来源：still 必跑；live 仅在矩形检测无页面档候选时条件触发（plan D6；
        // spec/frame-truth FR-002 页面先验口径），两条路径的结果并入同一
        // `DetectionStrategy.select` 统一择优。`gateSeg` 留存供遥测。
        // 页面意图（左/右页）需要整书外框才能按书脊拆分。矩形检测若只给出
        // 右页内框，常规门控不会跑文档分割——这里显式补一次；整页路径保持
        // 既有门控不变。
        let needsSpreadForIntent = intent != .wholePage
            && !rectangles.contains {
                PageIntentResolver.isSpreadLike($0)
                    || (PageIntentResolver.isPageLike($0)
                        && $0.area >= PageIntentResolver.minimumTargetArea
                        && PageIntentResolver.matchesSide($0, intent: intent))
            }
        let gateSeg = stillImage
            || DetectionStrategy.needsDocumentSegmentation(rectangles: rectangles)
            || needsSpreadForIntent
        let segmented: Quad?
        if gateSeg {
            segmented = detectDocumentQuad(cgImage: cgImage, orientation: orientation)
        } else {
            segmented = nil
        }
        // 三级兜底（spec/live-edge-crop，plan D1 / FR-001~002）：live 文档模式在
        // 「严格矩形无可信候选 ∧ 文档分割无结果」时（needsRelaxedRectangles 门控），
        // 以 still 路径同源的放宽参数集再跑一次矩形检测（置信度 0.35 / 最小尺寸
        // 0.08 / 直角容差 28° / 候选上限 8——`detectRectangles(relaxed:)` 单一参数源，
        // 零新参数）；候选并入同一池统一择优——折页厚书的曲面页不满足直线假设，
        // 前两级长期落空的场景由此兜底出框。放宽档不做贴边吸附（still 专属）；
        // 证件模式（idCardWindow）不参与第三级，检测路径保持不变。
        var relaxedRectangles: [Quad] = []
        var gateRelaxed = false
        if !stillImage, idCardWindow == nil {
            gateRelaxed = DetectionStrategy.needsRelaxedRectangles(
                rectangles: rectangles,
                segmented: segmented
            )
            if gateRelaxed {
                relaxedRectangles = detectRectangles(
                    cgImage: cgImage,
                    orientation: orientation,
                    relaxed: true
                )
            }
            ZhixiaLog.relaxedLiveProbe(
                triggered: gateRelaxed,
                candidates: relaxedRectangles.count
            )
        }
        let rawCandidates = [segmented].compactMap { $0 } + rectangles + relaxedRectangles
        let selection = DetectionStrategy.select(rawCandidates: rawCandidates, idCardWindow: idCardWindow)
        // P0.2 / CU-T003：页面意图解析。只在 live/静帧文档路径生效；证件
        // 窗口路径保持比例窗语义。选择目标页时宁可返回 nil（搜索态），
        // 也不把整书外框当作“右页”交给快门。
        let intentImage: CGImage? = {
            guard intent != .wholePage else { return nil }
            if orientation == .up { return cgImage }
            return uprightThumbnail(of: cgImage, orientation: orientation)
        }()
        let intentResolution: PageIntentResolver.Resolution? = {
            guard intent != .wholePage, idCardWindow == nil, let intentImage else { return nil }
            return PageIntentResolver.resolve(
                selection: selection?.quad,
                candidates: rawCandidates,
                intent: intent,
                image: intentImage,
                ciContext: intentCIContext
            )
        }()
        let intentSelection = intentResolution.map {
            DetectionStrategy.Selection(quad: $0.quad, tier: max(1, selection?.tier ?? 1))
        }
        let selectionForSticky: DetectionStrategy.Selection? = intent == .wholePage
            ? selection
            : intentSelection
        // US3 候选粘滞（spec/wysiwyg-crop，plan D3，FR-006~007；v2 见
        // spec/case-b-sticky-v2，plan D1）：仅 live 文档路径
        // （`!stillImage && idCardWindow == nil`）在逐帧独立择优后应用——
        // 摊开书从中线取景时右页与整书外轮廓逐帧交替胜出（面积比 ≈2:1，超
        // smoother 的 areaJump 重置阈值），取景框因此持续跳动、永不锁定；
        // 且三级检测门控使两候选常以**存在性交替**出现（一帧池里只有右页、
        // 下一帧只有整书分割），v1 同池续锚分支结构性不触发——v2
        // hold-through-miss 在 miss 窗口内维持锚点（与 QuadSmoother miss
        // 语义对齐），连续 5 帧无相似候选仍逃逸清锚（不粘死）。still（快门
        // 重检）与证件模式路径不参与——still 是单帧无振荡问题，证件有比例
        // 窗语义。sticky 锚点在快门/still 路径不复位（plan D2：避免恢复后
        // 首帧重掷锚点抽签）。
        // spec/folded-page-capture（FR-004）调用点覆盖两个参数（默认常量
        // 不动——v1/v2 测试钉住默认语义，铁律 2）：
        // - similarityThreshold 0.60→0.70：近摄制式下右页与整书外轮廓的
        //   bbox IoU ∈ [0.60, 0.70)，0.60 阈值让分支③「相似跟随」吞掉
        //   存在性交替——锚点在右页/整书之间逐帧棘轮，框永不锁定（regime
        //   c）。0.70 之上：同候选跨帧抖动 IoU ≥0.85（跟随不受影响），
        //   异候选 ≤0.426（远摄）/0.60~0.70（近摄）均判跳变走 hold。
        // - missLimit 3→5：与 QuadSmoother(missLimit: 5) 对齐（检测间隙
        //   呈现框不中途消失）；真机实测 ~29.5fps，5 帧 ≈0.17s < 0.5s
        //   移场接受上限。
        // spec/frame-truth（FR-001/003）调用点追加（默认语义由单测钉住）：
        // - pool 改用 `viablePool`（与 select 同口径单一真源）——修复分支④
        //   从未过滤原始池改选亚 minArea/退化框（真机 0.056–0.077 的来源）；
        // - anchorMinArea 0.12（视频空间，≈照片 0.09）：文字带可显示但不得
        //   起锚；reanchorConfirmFrames 3：escape/初锁后连续 3 帧相似才起锚
        //   （消灭"escape 帧恰好是带子→单帧抽签"）；followMinAreaRatio 0.8：
        //   分支③跟随限制 ≤20%/帧面积变化，堵包含链棘轮。
        let effective: DetectionStrategy.Selection?
        if !stillImage, idCardWindow == nil {
            let stickyPool = DetectionStrategy.viablePool(
                rawCandidates + (intentResolution.map { [$0.quad] } ?? [])
            )
            let gated = sticky.apply(
                selection: selectionForSticky,
                pool: stickyPool,
                similarityThreshold: 0.70,
                // CU-T004：3→5 帧的旧窗口在真机候选存在性交替下仍会周期性
                // 逃逸；页面意图明确时使用 ~0.4–0.5s 的稳定窗（30fps≈15帧），
                // 整页路径保持既有 5 帧语义。
                missLimit: intent == .wholePage ? 5 : 15,
                holdThroughMiss: true,
                anchorMinArea: 0.12,
                reanchorConfirmFrames: 3,
                followMinAreaRatio: 0.8
            )
            switch sticky.lastDisposition {
            case .override:
                // 同池共存交替：粘滞改选锚点相似候选（先稳者胜止跳证据）。
                if let selection, let gated {
                    ZhixiaLog.stickyOverride(
                        iou: gated.quad.iou(with: selection.quad),
                        heldArea: gated.quad.area,
                        selectionArea: selection.quad.area
                    )
                }
            case .hold:
                // 存在性交替：miss 窗口内维持锚点（v2 止跳证据——上轮复测
                // stickyOverride 整段缺失正因 miss 路径零遥测，此通道补缺）。
                if let selection, let gated {
                    ZhixiaLog.stickyHold(
                        missCount: sticky.missCount,
                        heldArea: gated.quad.area,
                        selectionArea: selection.quad.area
                    )
                }
            case .escape:
                // 达限清锚（FR-007 不粘死证据；用户真移场后应可见）。
                ZhixiaLog.stickyEscape(afterMisses: sticky.missCount)
            default:
                break
            }
            effective = gated
        } else {
            effective = intent == .wholePage ? selection : intentSelection
        }
        // spec/guided-capture T002 / FR-007：候选快照落盘——**订阅时才构造**
        // （默认 nil = 零开销：不排序、不分配）。载荷含全部 viable + top 8、
        // 硬上限 16、droppedCount；V2 验证（docs/15 §九）据此判断
        // 「右页在不在池」——在池但输给整书 = 评分/意图问题，不在池 = 检测问题。
        #if DEBUG
        if let handler = candidateSnapshotHandler {
            let snapshot = CandidateSnapshotBuilder.build(
                rawCandidates: rawCandidates,
                selection: selection,
                effective: effective,
                disposition: stillImage ? nil : sticky.lastDisposition?.rawValue,
                stickyMissCount: stillImage ? 0 : sticky.missCount,
                path: stillImage ? .still : .live,
                idCardMode: idCardWindow != nil,
                timestamp: Date()
            )
            lastCandidateSnapshot = snapshot
            ZhixiaLog.candidateDump(
                path: snapshot.path.rawValue,
                rawCount: snapshot.rawCount,
                viableCount: snapshot.viableCount,
                droppedCount: snapshot.droppedCount,
                topArea: snapshot.maxArea,
                selectionArea: snapshot.selectionArea,
                disposition: snapshot.disposition
            )
            handler(snapshot)
        }
        #endif
        ZhixiaLog.detectionTier(
            still: stillImage,
            tier: effective?.tier ?? 0,
            candidates: rawCandidates.count,
            selectedArea: effective?.quad.area ?? 0
        )
        // spec/frame-truth FR-008：live 每帧候选来源遥测——上一周期两轮复盘
        // 的最大盲区（池里有没有页面/门控是否触发只能猜）由此终结。
        if !stillImage, idCardWindow == nil {
            let viable = DetectionStrategy.viablePool(rawCandidates)
            let strictMax = rectangles.map(\.area).max() ?? 0
            let relaxedMax = relaxedRectangles.map(\.area).max() ?? 0
            let viableMax = viable.map(\.area).max() ?? 0
            ZhixiaLog.candidateProvenance(
                strictCount: rectangles.count,
                strictMaxArea: strictMax,
                segArea: segmented?.area ?? -1,
                relaxedCount: relaxedRectangles.count,
                relaxedMaxArea: relaxedMax,
                viableCount: viable.count,
                viableMaxArea: viableMax,
                gateSeg: gateSeg,
                gateRelaxed: gateRelaxed,
                preStickySelectionArea: selection?.quad.area ?? 0,
                disposition: sticky.lastDisposition?.rawValue ?? "none",
                heldArea: effective?.quad.area ?? 0
            )
        }
        guard var quad = effective?.quad else { return nil }
        // 页面意图的最终守卫：左/右页意图绝不能返回整书外框。sticky 可能在
        // 短检测间隙里 hold 旧目标（已通过 page-like 校验）；若旧锚点是整书
        // 或新目标退化，则回到搜索态，由下一帧重新解析。
        if intent != .wholePage, !PageIntentResolver.isPageLike(quad) {
            return nil
        }
        // spec/word-fidelity T001：静帧路径的**页面判定**——页面外框常常检不出
        // （书页边缘不直/充满取景），此时绝不能裁到页面里的子框（表格/色块/
        // 底边条），否则整页被裁成一小块（用户实测「只识别了右页的一部分」）。
        // 判据见 `DetectionStrategy.stillPageCandidate`：大候选 = 页面；候选铺满
        // 整幅 = 整幅就是页面（**不裁**）；否则文档是画面里的子区域。
        if stillImage, idCardWindow == nil {
            if intent != .wholePage {
                // 静帧意图路径已经由 PageIntentResolver 选出单页目标；不再让
                // stillPageCandidate 把整书外框覆盖回来。
                guard intentResolution != nil else { return nil }
            } else {
                let viable = DetectionStrategy.viablePool(rawCandidates)
                guard let page = DetectionStrategy.stillPageCandidate(viable: viable) else {
                    // 认不出页面 → 不裁（调用方回退整图），绝不裁到子框。
                    return nil
                }
                quad = page
            }
        }
        // US6（plan D7）：still 路径择优后贴边吸附——检出框普遍内缩 1~3%，
        // 沿外法线恢复真实边缘。证件模式比例窗保持语义不变；live 路径不动。
        // 快门检测与整理页 refine 都经由本方法，单点接入全部受益。
        if stillImage, idCardWindow == nil, intent == .wholePage {
            quad = snapped(quad, cgImage: cgImage, orientation: orientation)
        }
        return quad
    }

    /// still 吸附：quad 是 EXIF 校正后的直立归一化空间，像素采样需要「直立」光栅
    /// （与 `ImagePipeline.loadUpright` 同语义）。非 up 方向先做小尺寸直立缩略，
    /// 失败则放弃吸附——宁可不修，不可错修。
    private func snapped(
        _ quad: Quad,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Quad {
        let logEdge: (EdgeSnapper.EdgeDiagnostic) -> Void = { diagnostic in
            ZhixiaLog.snapEdge(
                edge: diagnostic.edge,
                g0: diagnostic.g0,
                outward: diagnostic.outward,
                inward: diagnostic.inward,
                shift: diagnostic.shift
            )
        }
        if orientation == .up {
            return EdgeSnapper.snap(
                quad: quad, image: cgImage, maxShiftRatio: 0.05, diagnostics: logEdge
            )
        }
        guard let upright = uprightThumbnail(of: cgImage, orientation: orientation) else {
            return quad
        }
        return EdgeSnapper.snap(
            quad: quad, image: upright, maxShiftRatio: 0.05, diagnostics: logEdge
        )
    }

    /// EXIF 直立化的小尺寸缩略图（吸附栅格只要 ~160 列，无需全分辨率）。
    private func uprightThumbnail(
        of image: CGImage,
        orientation: CGImagePropertyOrientation,
        maxDimension: CGFloat = 480
    ) -> CGImage? {
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    private func detectRectangles(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        relaxed: Bool
    ) -> [Quad] {
        // spec/folded-page-capture（FR-003）：live 严格档（relaxed=false）
        // 最小尺寸 0.25→0.15、直角容差 20°→26°——折页书曲面页的角点常出画/
        // 微弯，原参数下正确候选结构性不存在（池里只剩整书分割 blob 与放宽
        // 档假矩形），稳定层只能在「稳定地错」与「抖动着错」之间二选一。
        // 取严格档与放宽档（0.08/28°）之间的中间值，避免一步跳到放宽档的
        // 噪声水平；still 路径首跑即放宽档、live 第三级放宽档均不动。
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = relaxed ? 0.35 : 0.6
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = relaxed ? 0.08 : 0.15
        request.maximumObservations = relaxed ? 8 : 4
        request.quadratureTolerance = relaxed ? 28 : 26

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.debug("Vision rectangle failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).map(observationToQuad)
    }

    private func detectDocumentQuad(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.error("Document segmentation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let quad = observationToQuad(observation)
        // 上限交给 DetectionStrategy 的两级兜底：近满幅的文档分割结果
        // （近拍书占满画面）必须能进入二级候选池，而非在此被静默丢弃。
        guard !quad.isDegenerate, quad.area > DetectionStrategy.minArea else {
            return nil
        }
        return quad
    }

    private func observationToQuad(_ observation: VNRectangleObservation) -> Quad {
        Quad(
            topLeft: flipY(observation.topLeft),
            topRight: flipY(observation.topRight),
            bottomRight: flipY(observation.bottomRight),
            bottomLeft: flipY(observation.bottomLeft)
        )
    }

    private func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    private func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }
}
