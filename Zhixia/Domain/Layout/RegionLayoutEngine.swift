import CoreGraphics
import Foundation

// MARK: - LayoutReport

/// 单次 table×figure 收缩明细（ZhixiaLog.layoutFigureShrink 逐条日志消费，T012 接线）。
struct FigureShrinkRecord: Equatable, Sendable {
    let figureID: UUID
    /// 被剔除的归一化高度（收缩前 − 收缩后）
    let clipHeight: Double
}

/// 区域布局引擎单页汇总报告（spec/layout-engine plan D1/D5/D10）。
///
/// 引擎输出的日志伴生值，不持久化（ZhixiaLog layout 类目消费）。
/// 全字段零值默认：无冲突输入（恒等映射）的报告与 `LayoutReport()` 逐字段相等——
/// 这是 RegionLayoutEngineTests 恒等性用例钉死的契约。
struct LayoutReport: Equatable, Sendable {
    /// 跨栏双峰拆分块数（拆一次 +1）
    var splitCount: Int = 0
    /// 让位次数（平移 / 收缩 / 压片各计一次）
    var yieldCount: Int = 0
    /// 让位平移总量（归一化坐标；只计平移，收缩与压片不计）
    var totalShift: Double = 0
    /// 实际发生移动的消解轮数（首輪即不动点 = 0）
    var resolveRounds: Int = 0
    /// figure 收缩明细（plan D10「figure 收缩量」逐条日志依据）
    var figureShrinks: [FigureShrinkRecord] = []
    /// figure 收缩次数（明细派生）
    var figureShrinkCount: Int { figureShrinks.count }
    // 溢出阶梯计数（plan D6，T026 起累加；装得下的块不计——恒等页报告仍全零）
    var overflowShrinkCount: Int = 0
    var overflowExpandCount: Int = 0
    var overflowExtremeCount: Int = 0

    init() {}
}

// MARK: - 块种类布局语义

extension ReconstructBlockKind {
    /// 实心块：参与让位/收缩消解（plan D5 收集规则）。
    /// figure/barcode/artwork 为透出区，不让位（FR-002 说明字例外语义）。
    var isSolidForLayout: Bool {
        switch self {
        case .heading, .paragraph, .list, .table, .checkbox, .handwrittenBlank:
            return true
        case .figure, .barcode, .artwork:
            return false
        }
    }

    /// 文本类块：跨栏双峰拆分的候选（表格行列结构不可裂，不拆）。
    var isTextualForLayout: Bool {
        switch self {
        case .heading, .paragraph, .list, .checkbox, .handwrittenBlank:
            return true
        case .table, .figure, .barcode, .artwork:
            return false
        }
    }
}

// MARK: - 引擎

/// 区域布局引擎（spec/layout-engine plan D1/D2/D5，US1 消解核心）。
///
/// 纯函数、无 I/O、无随机、无时钟——同输入必同输出（FR-010 确定性）。
///
/// 管线（顺序固定）：
/// 1. **跨栏拆分** `normalizeSplit`：跨栏宽行（块宽 > 版心 70% 且成员行 midX 双峰）
///    原位裂成左右两块（plan D2② 残余兜底）；
/// 2. **碰撞消解** `resolveCollisions`：阅读序两两消解、链式传播 ≤ `maxResolveRounds` 轮；
/// 3. **溢出阶梯** `resolveOverflowLadder`：内容装不下的文字块先等比缩行几何（字号随
///    实测行高同步缩，下限 7pt）再向下扩展吸收空白带，扩展后重入消解（plan D6）；
/// 4. **页界夹取** `clampToPage`：越界块夹回 [0,1] 页矩形。
///
/// 三条铁律（RegionLayoutEngineTests 钉死）：
/// - **零扰动**：无冲突输入 → 恒等映射（逐字段相等），报告全零；
/// - **两两不相交**：消解后实心块全对无交（FR-001）；
/// - **阅读序不变**：只动几何不动顺序，输出与输入同序同长。
enum RegionLayoutEngine {
    /// 链式消解轮数上限（plan D5④：病态输入不失控）
    static let maxResolveRounds = 4
    /// 跨栏拆分阈值：块宽 > 版心宽 × 0.70（plan D2②）
    static let splitWidthRatio = 0.70
    /// 拆分最少成员行数
    static let splitMinimumLines = 4
    /// 双峰谷宽阈值：相邻行 midX 间隙 ≥ 0.08 方视为双峰（plan D2②）
    static let splitGutterWidth = 0.08
    /// 无处容身时的边缘压片高度（归一化）——bbox 压片但文字永不截断（FR-006）
    static let degenerateSliverHeight = 0.01

    /// 消解入口（唯一调用方 = OnDeviceDocumentParser 装配点，plan D1）。
    ///
    /// - Parameters:
    ///   - blocks: 阅读序块集（引擎不重排）。
    ///   - layout: 页级版面分析产物（拆分阈值取版心宽；nil = 跳过拆分）。
    ///   - pageSize: 页物理尺寸（px——`OnDeviceDocumentParser` 传图源像素）。
    ///     pt 换算 × `LayoutTypography.ptPerPixel`（0.75），溢出阶梯估算的工作空间。
    /// - Returns: 布局后块集（写 `ReconstructPage.restoredBlocks`）+ 汇总报告。
    static func resolve(
        blocks: [ReconstructBlock],
        layout: PageLayout?,
        pageSize: CGSize
    ) -> (blocks: [ReconstructBlock], report: LayoutReport) {
        var report = LayoutReport()
        var working = blocks
        normalizeSplit(&working, layout: layout, report: &report)
        // 先落局部再写回：report 本身是 resolveCollisions 的 inout 实参，
        // 直接 `report.resolveRounds = resolveCollisions(&working, report: &report)`
        // 构成访问重叠（Swift 排他性）。
        var rounds = resolveCollisions(&working, report: &report)
        rounds += resolveOverflowLadder(&working, pageSize: pageSize, report: &report)
        report.resolveRounds = rounds
        clampToPage(&working)
        return (blocks: working, report: report)
    }

    // MARK: 管线 1：跨栏拆分（plan D2②）

    /// 宽行双峰拆分：逐块扫描，命中即原位替换为左右两块（阅读序局部性保留）。
    private static func normalizeSplit(
        _ blocks: inout [ReconstructBlock],
        layout: PageLayout?,
        report: inout LayoutReport
    ) {
        guard let layout, layout.contentBounds.width > 0 else { return }
        var usedIDs = Set(blocks.map(\.id))
        var output: [ReconstructBlock] = []
        output.reserveCapacity(blocks.count)
        for block in blocks {
            if let parts = splitIfBimodal(block, contentWidth: layout.contentBounds.width, usedIDs: &usedIDs) {
                output.append(contentsOf: parts)
                report.splitCount += 1
            } else {
                output.append(block)
            }
        }
        blocks = output
    }

    /// 单块双峰判定与拆分。返回 nil = 不拆（种类/行数/宽度阈值/谷宽/几何退化任一不满足）。
    private static func splitIfBimodal(
        _ block: ReconstructBlock,
        contentWidth: Double,
        usedIDs: inout Set<UUID>
    ) -> [ReconstructBlock]? {
        guard block.kind.isTextualForLayout,
              let lines = block.lines,
              lines.count >= splitMinimumLines,
              block.bbox.width > 0,
              block.bbox.width > splitWidthRatio * contentWidth
        else { return nil }

        // 行水平中点（归一化）：块 minX + 行首偏移 + 行宽一半
        let midXs = lines.map { block.bbox.minX + $0.leadingOffset + $0.width / 2 }
        let ordered = midXs.enumerated().sorted { $0.element < $1.element }

        // 最大中点间隙（严格大于 → 并列取首个；全平则 bestGap = 0 不过谷宽门槛）
        var bestSplit = 0
        var bestGap = 0.0
        for position in 0..<(ordered.count - 1) {
            let gap = ordered[position + 1].element - ordered[position].element
            if gap > bestGap {
                bestGap = gap
                bestSplit = position + 1
            }
        }
        // 谷宽达标且两侧各 ≥ 2 行
        guard bestGap >= splitGutterWidth,
              bestSplit >= 2,
              ordered.count - bestSplit >= 2
        else { return nil }

        let leftMembers = Set(ordered[0..<bestSplit].map { $0.offset })
        let rightMembers = Set(ordered[bestSplit...].map { $0.offset })

        // 成员行保持原阅读序（行序 = 采集时自上而下，T005 约定）
        let leftLines = lines.enumerated().filter { leftMembers.contains($0.offset) }.map { $0.element }
        let rightLines = lines.enumerated().filter { rightMembers.contains($0.offset) }.map { $0.element }

        // 侧块 bbox：x = 成员行绝对帧并集；y = 块内累积行几何
        guard let leftFrame = sideFrame(of: lines, members: leftMembers, blockBBox: block.bbox),
              let rightFrame = sideFrame(of: lines, members: rightMembers, blockBBox: block.bbox)
        else { return nil }

        // 值拷贝继承 kind/style/measuredLineHeight/semantic/anchors/confidence，只改身份与几何。
        // 行首偏移重定基（D3 定义 lead = 行 minX − 块 minX）：侧块 minX = 原块 minX +
        // 成员最小 lead，不重定基的右块 lead 会越出块宽——溢出阶梯的换行估算按可用宽
        // 1pt 兜底爆出多倍换行行数（误触阶梯），逐行渲染定位也会贴到块右缘。
        let leftLeadDelta = leftFrame.minX - block.bbox.minX
        let rightLeadDelta = rightFrame.minX - block.bbox.minX

        var left = block
        left.id = derivedID(from: block.id, avoiding: usedIDs, salt: 1)
        usedIDs.insert(left.id)
        left.text = leftLines.map(\.text).joined(separator: "\n")
        left.lines = leftLines.map { line in
            BlockLine(
                text: line.text,
                height: line.height,
                gapToPrevious: line.gapToPrevious,
                leadingOffset: max(0, line.leadingOffset - leftLeadDelta),
                width: line.width
            )
        }
        left.bbox = leftFrame

        var right = block
        right.id = derivedID(from: block.id, avoiding: usedIDs, salt: 2)
        usedIDs.insert(right.id)
        right.text = rightLines.map(\.text).joined(separator: "\n")
        right.lines = rightLines.map { line in
            BlockLine(
                text: line.text,
                height: line.height,
                gapToPrevious: line.gapToPrevious,
                leadingOffset: max(0, line.leadingOffset - rightLeadDelta),
                width: line.width
            )
        }
        right.bbox = rightFrame

        return [left, right]
    }

    /// 侧块包围盒：遍历全部行累积绝对 y 几何（块 maxY 起自上而下：行 maxY = top − gap，
    /// 行 minY = maxY − height），只对成员行取 x/y 并集。
    /// 返回 nil = 并集退化（宽或高 ≤ 0）——宁可不拆也不产废块。
    private static func sideFrame(
        of lines: [BlockLine],
        members: Set<Int>,
        blockBBox: CGRect
    ) -> CGRect? {
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var top = blockBBox.maxY
        for index in lines.indices {
            let line = lines[index]
            let lineMaxY = top - line.gapToPrevious
            let lineMinY = lineMaxY - line.height
            if members.contains(index) {
                let lineMinX = blockBBox.minX + line.leadingOffset
                let lineMaxX = lineMinX + line.width
                minX = min(minX, lineMinX)
                maxX = max(maxX, lineMaxX)
                minY = min(minY, lineMinY)
                maxY = max(maxY, lineMaxY)
            }
            top = lineMinY
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 拆分块派生 id：基 id 尾字节 XOR 盐值；与页内既有 id 冲突时盐值确定性自增
    /// （256 耗尽后进位翻 byte14）。非零 XOR 必改变尾字节 → 派生 id ≠ 基 id；
    /// 全程纯函数 → FR-010 确定性成立。
    private static func derivedID(from base: UUID, avoiding used: Set<UUID>, salt: UInt8) -> UUID {
        var counter = UInt16(salt)
        var candidate = flipTail(of: base, salt: UInt8(counter &  0xFF), carry: UInt8(counter >> 8))
        while used.contains(candidate) {
            counter &+= 1
            candidate = flipTail(of: base, salt: UInt8(counter &  0xFF), carry: UInt8(counter >> 8))
        }
        return candidate
    }

    private static func flipTail(of base: UUID, salt: UInt8, carry: UInt8) -> UUID {
        var bytes = base.uuid
        bytes.14 ^= carry
        bytes.15 ^= salt
        return UUID(uuid: bytes)
    }

    // MARK: 管线 2：碰撞消解（plan D5）

    /// 两两消解至不动点或轮数上限。返回实际发生移动的轮数。
    /// 轮内即时生效：同一轮里让位后的新几何对后续冲突对立即可见（链式传播）。
    private static func resolveCollisions(
        _ blocks: inout [ReconstructBlock],
        report: inout LayoutReport
    ) -> Int {
        var roundsWithMoves = 0
        for _ in 0..<maxResolveRounds {
            var movedInRound = false
            for i in blocks.indices {
                for j in blocks.indices where j > i {
                    // 实心×实心让位；table×figure 收缩 figure；其余（含 text×figure）保留
                    let pairRelevant =
                        (blocks[i].kind.isSolidForLayout && blocks[j].kind.isSolidForLayout)
                        || (blocks[i].kind == .table && blocks[j].kind == .figure)
                        || (blocks[i].kind == .figure && blocks[j].kind == .table)
                    guard pairRelevant, intersects(blocks[i].bbox, blocks[j].bbox) else { continue }
                    if resolvePair(&blocks, i, j, report: &report) {
                        movedInRound = true
                    }
                }
            }
            if movedInRound {
                roundsWithMoves += 1
            } else {
                break
            }
        }
        return roundsWithMoves
    }

    /// 消解单对相交块。返回是否发生移动（不动点检测用）。
    private static func resolvePair(
        _ blocks: inout [ReconstructBlock],
        _ i: Int,
        _ j: Int,
        report: inout LayoutReport
    ) -> Bool {
        // table×figure：figure 收缩剔除相交带，table 原地（plan D5③）
        if blocks[i].kind == .table, blocks[j].kind == .figure {
            let stay = blocks[i]
            return clipFigure(&blocks, figureIndex: j, awayFrom: stay, report: &report)
        }
        if blocks[j].kind == .table, blocks[i].kind == .figure {
            let stay = blocks[j]
            return clipFigure(&blocks, figureIndex: i, awayFrom: stay, report: &report)
        }

        // 实心×实心：选让位方——text×table 时 text 让位（表格 bbox 来自结构化识别，
        // 可信度高），其余后序让位（plan D5③）
        let secondYields: Bool
        if blocks[i].kind == .table, blocks[j].kind != .table {
            secondYields = true
        } else if blocks[j].kind == .table, blocks[i].kind != .table {
            secondYields = false
        } else {
            secondYields = true
        }
        let yieldIndex = secondYields ? j : i
        let stayIndex = secondYields ? i : j
        // 先拷贝再传参：awayFrom 直接取 blocks[stayIndex] 会与 &blocks 访问重叠（排他性）
        let stay = blocks[stayIndex]
        let (moved, shift) = yield(&blocks, yieldIndex, awayFrom: stay)
        if moved {
            report.yieldCount += 1
            report.totalShift += abs(shift)
        }
        return moved
    }

    /// 让位：沿 Y 轴向与 stay 相反一侧移动最小距离。
    /// 平移越页界 → 收缩自身高度（保远离 stay 一侧的边）→ 仍无处容身 → 边缘压片。
    /// 只改 bbox，文字/行数据永不丢弃（FR-006）。
    /// 返回 (是否移动, 平移量)——newRect == 原样 = 无进展（不动点候选）。
    private static func yield(
        _ blocks: inout [ReconstructBlock],
        _ index: Int,
        awayFrom stay: ReconstructBlock
    ) -> (moved: Bool, shift: Double) {
        let rect = blocks[index].bbox
        let height = rect.height
        let newRect: CGRect
        var shift = 0.0
        if rect.midY > stay.bbox.midY {
            // 让位块在 stay 下方 → 向下平移：顶边贴齐 stay 底边
            if stay.bbox.maxY + height <= 1 {
                newRect = CGRect(x: rect.minX, y: stay.bbox.maxY, width: rect.width, height: height)
                shift = stay.bbox.maxY - rect.minY
            } else if rect.maxY > stay.bbox.maxY {
                // 平移越页界 → 收缩：保底边，裁掉与 stay 相交的顶带
                newRect = CGRect(x: rect.minX, y: stay.bbox.maxY, width: rect.width, height: rect.maxY - stay.bbox.maxY)
            } else {
                // 极端：贴到页底压片
                newRect = CGRect(x: rect.minX, y: 1 - degenerateSliverHeight, width: rect.width, height: degenerateSliverHeight)
            }
        } else {
            // 让位块在 stay 上方 → 向上平移：底边贴齐 stay 顶边
            if stay.bbox.minY - height >= 0 {
                newRect = CGRect(x: rect.minX, y: stay.bbox.minY - height, width: rect.width, height: height)
                shift = rect.maxY - stay.bbox.minY
            } else if stay.bbox.minY > rect.minY {
                // 平移越页界 → 收缩：保顶边，裁掉与 stay 相交的底带
                newRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: stay.bbox.minY - rect.minY)
            } else {
                // 极端：贴到页顶压片
                newRect = CGRect(x: rect.minX, y: 0, width: rect.width, height: degenerateSliverHeight)
            }
        }
        guard newRect != rect else { return (false, 0) }
        blocks[index].bbox = newRect
        return (true, shift)
    }

    /// table×figure 相交：figure 收缩剔除相交带（保留远离 table 一侧，按中线判定）。
    private static func clipFigure(
        _ blocks: inout [ReconstructBlock],
        figureIndex: Int,
        awayFrom stay: ReconstructBlock,
        report: inout LayoutReport
    ) -> Bool {
        let figure = blocks[figureIndex].bbox
        let clipped: CGRect
        if figure.midY > stay.bbox.midY {
            // figure 主体在 table 下方 → 保下侧
            clipped = CGRect(x: figure.minX, y: stay.bbox.maxY, width: figure.width, height: figure.maxY - stay.bbox.maxY)
        } else {
            // figure 主体在 table 上方 → 保上侧
            clipped = CGRect(x: figure.minX, y: figure.minY, width: figure.width, height: stay.bbox.minY - figure.minY)
        }
        // 相交带吞没 figure 全高（无正余量）→ 不动，交由轮数上限兜底
        guard clipped.width > 0, clipped.height > 0, clipped != figure else { return false }
        let figureID = blocks[figureIndex].id
        blocks[figureIndex].bbox = clipped
        report.figureShrinks.append(FigureShrinkRecord(
            figureID: figureID,
            clipHeight: figure.height - clipped.height
        ))
        return true
    }

    // MARK: 管线 3：溢出阶梯（plan D6 / FR-006）

    /// 阶梯拟合容差（pt）：估算与区域的浮点尘埃不触发下一级阶梯。
    private static let overflowFitEpsilon: Double = 1e-6
    /// 比例缩放迭代上限：估算含换行分段（分段数随缩放单调不增），逐次逼近必收敛。
    private static let overflowShrinkMaxIterations = 8

    /// 溢出阶梯：内容装不下的文字块依序（plan D6）
    /// ① 等比缩行几何（字号随 `measuredLineHeight` 同步缩，下限 7pt 当量触底）
    /// ② 仍不足 → 区域向下扩展吸收空白带（不侵入下方任何块、不越页底）
    /// ③ 仍不足 → 极端路径：保持 ①② 后几何，文字永不截断，计入 overflowExtreme。
    ///
    /// 只作用于有实测行数据的文字块——表格行高是 US5 表格域（exact→atLeast 升级链），
    /// figure 非文本，无 lines 块交由渲染期兜底（T027）。
    /// 返回扩展后重入碰撞消解的轮数（无扩展 = 0）。
    private static func resolveOverflowLadder(
        _ blocks: inout [ReconstructBlock],
        pageSize: CGSize,
        report: inout LayoutReport
    ) -> Int {
        let pageHeightPT = Double(pageSize.height) * LayoutTypography.ptPerPixel
        let pageWidthPT = Double(pageSize.width) * LayoutTypography.ptPerPixel
        guard pageHeightPT > 0, pageWidthPT > 0 else { return 0 }

        var expandedAny = false
        for index in blocks.indices {
            // 拷出改回：inout 元素与数组快照不可同时持有（Swift 排他性）。
            // 快照取当下几何——阅读序先处理者的扩展对后续块的空白带判定立即可见。
            var block = blocks[index]
            let neighbors = blocks
            if applyOverflowLadder(
                &block,
                neighbors: neighbors,
                pageHeightPT: pageHeightPT,
                pageWidthPT: pageWidthPT,
                report: &report
            ) {
                expandedAny = true
            }
            blocks[index] = block
        }
        guard expandedAny else { return 0 }
        // 扩展后重入消解管线（plan D6）：扩展以「下方最近遮挡顶边」为界，理论只贴边
        // 不相交；贴边浮点尘埃若形成正相交，此处兜底消解。
        return resolveCollisions(&blocks, report: &report)
    }

    /// 单块溢出阶梯。返回是否发生区域扩展（触发重入消解）。
    /// 零扰动契约：装得下的块逐字段不动（含报告计数）。
    private static func applyOverflowLadder(
        _ block: inout ReconstructBlock,
        neighbors: [ReconstructBlock],
        pageHeightPT: Double,
        pageWidthPT: Double,
        report: inout LayoutReport
    ) -> Bool {
        guard block.kind.isTextualForLayout,
              let lines = block.lines, !lines.isEmpty,
              block.bbox.height > 0, block.bbox.width > 0
        else { return false }

        let regionPT = block.bbox.height * pageHeightPT
        var estimate = estimatedContentHeight(block, pageWidthPT: pageWidthPT, pageHeightPT: pageHeightPT)
        guard estimate > regionPT + overflowFitEpsilon else { return false }

        // ① 等比缩行几何：只缩垂直节拍（height/gapToPrevious/measuredLineHeight），
        //    横向几何不动（区域横向不扩）。字号由 measuredLineHeight 链条同步缩。
        //    s_floor = 7pt ÷ 未钳制实测字号——比例触底即止（更小违反可读性下限）。
        let originalLines = lines
        let originalMeasured = block.measuredLineHeight
        let rawFontPT = LayoutTypography.unclampedFontPT(for: block, pageHeightPT: pageHeightPT)
        let floorScale = rawFontPT > LayoutTypography.minFontPT
            ? LayoutTypography.minFontPT / rawFontPT
            : 1
        var scale = 1.0
        for _ in 0..<overflowShrinkMaxIterations where estimate > regionPT + overflowFitEpsilon {
            let next = max(floorScale, scale * regionPT / estimate)
            guard next < scale else { break } // 已触下限或已收敛——无进展即止
            scale = next
            block.lines = originalLines.map { line in
                BlockLine(
                    text: line.text,
                    height: line.height * scale,
                    gapToPrevious: line.gapToPrevious * scale,
                    leadingOffset: line.leadingOffset,
                    width: line.width
                )
            }
            block.measuredLineHeight = originalMeasured.map { $0 * scale }
            estimate = estimatedContentHeight(block, pageWidthPT: pageWidthPT, pageHeightPT: pageHeightPT)
        }
        if scale < 1 {
            report.overflowShrinkCount += 1
        }
        guard estimate > regionPT + overflowFitEpsilon else { return false }

        // ② 区域向下扩展吸收空白带：扩展量 = min(需求, 到底边下方最近遮挡/页底的空隙)
        let needPT = estimate - regionPT
        let available = downwardBlankBand(of: block.bbox, neighbors: neighbors)
        let expandBy = min(needPT / pageHeightPT, available)
        guard expandBy > 0 else {
            // ③ 无空白可吸收 → 极端路径（文字完整不截断，FR-006）
            report.overflowExtremeCount += 1
            return false
        }
        block.bbox = CGRect(
            x: block.bbox.minX,
            y: block.bbox.minY - expandBy,
            width: block.bbox.width,
            height: block.bbox.height + expandBy
        )
        report.overflowExpandCount += 1
        if estimate > block.bbox.height * pageHeightPT + overflowFitEpsilon {
            // ③ 下限 + 空白带耗尽仍不足 → 极端路径：保持 ①② 几何，文字不截断
            report.overflowExtremeCount += 1
        }
        return true
    }

    /// bbox 底边下方的空白带（归一化）：到「水平正重叠的下方最近块顶边」与页底（y=0）的较近者。
    /// 遮挡不限种类——figure 也不可侵入（mask 按块 bbox 构建，扩进图区会压图产生双影；
    /// plan D6 原文「实心块」在此收紧为「任意块」，差异已记入实施报告）。
    /// 自身与垂直相交块因顶边 ≥ 本块底边天然不计入。
    private static func downwardBlankBand(of rect: CGRect, neighbors: [ReconstructBlock]) -> Double {
        var floorY = 0.0
        for neighbor in neighbors {
            let other = neighbor.bbox
            guard other.maxX > rect.minX, other.minX < rect.maxX, // 水平正重叠
                  other.maxY <= rect.minY // 顶边在本块底边下方（贴边 = 空隙 0）
            else { continue }
            floorY = max(floorY, other.maxY)
        }
        return max(0, rect.minY - floorY)
    }

    /// 块内容渲染高度估算（委托 LayoutTypography——与双端渲染同一度量，估算不失真）。
    private static func estimatedContentHeight(
        _ block: ReconstructBlock,
        pageWidthPT: Double,
        pageHeightPT: Double
    ) -> Double {
        LayoutTypography.estimatedRenderHeight(
            lines: block.lines ?? [],
            blockWidth: block.bbox.width,
            pageWidthPT: pageWidthPT,
            pageHeightPT: pageHeightPT,
            baseFontPT: LayoutTypography.fontPT(for: block, pageHeightPT: pageHeightPT)
        )
    }

    // MARK: 管线 4：页界夹取（plan D5⑤）

    /// 越界块夹回 [0,1] 页矩形；页内块原样跳过（零扰动：结构体逐位不动）。
    private static func clampToPage(_ blocks: inout [ReconstructBlock]) {
        for index in blocks.indices {
            let rect = blocks[index].bbox
            guard rect.minX < 0 || rect.minY < 0 || rect.maxX > 1 || rect.maxY > 1 else { continue }
            let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            // 完全出页的退化块保持原样（无信息可夹）
            if !clamped.isNull {
                blocks[index].bbox = clamped
            }
        }
    }

    // MARK: 工具

    /// 正面积相交判定：贴边（宽或高为 0）不算相交——消解后允许精确堆叠。
    private static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }
}
