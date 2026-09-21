import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// US1 区域布局消解（spec/layout-engine plan D1/D2/D5）。
///
/// 引擎契约的三条铁律在这里钉死：
/// 1. **零扰动**：无冲突输入 → 恒等映射（既有观感与数值断言零变化的前提）；
/// 2. **两两不相交**：合成冲突夹具消解后实心块全对无交（FR-001）；
/// 3. **确定性**：同输入同输出——无随机、无时钟（FR-010）。
///
/// 让位规则速查（plan D5）：
/// - 后序块让位；text×table 相交 **text 让位**；table×table 后序让位；
/// - 方向 = 沿 Y 轴向「与相交块相反一侧」平移最小距离（上块向上、下块向下）；
/// - table×figure 相交 → figure 收缩剔除相交部分（说明字例外：text×figure 保留）；
/// - 平移越页界 → 收缩自身高度；链式传播 ≤ 4 轮；最后页界夹取。
struct RegionLayoutEngineTests {

    // 页尺寸只在 US4/US5 的 pt 换算里起作用，US1 全程归一化坐标。
    private let pageSize = CGSize(width: 800, height: 1000)

    /// 版心宽 0.9 —— 跨栏拆分阈值 70% 版心 = 0.63。
    private let layout = PageLayout(
        contentBounds: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
        medianLineHeight: 0.02,
        medianGap: 0.01,
        bands: [],
        regions: [],
        columns: [],
        anchors: [],
        lineSemantics: []
    )

    private let solidKinds: Set<ReconstructBlockKind> = [
        .heading, .paragraph, .list, .table, .checkbox, .handwrittenBlank
    ]

    // MARK: - ① 恒等性（零扰动不变量）

    @Test("无冲突输入恒等映射：块集与报告全零")
    func identityOnNoConflict() {
        let paragraph = text(
            "11111111-1111-1111-1111-111111111101",
            CGRect(x: 0.05, y: 0.60, width: 0.90, height: 0.30)
        )
        let tableBlock = table(
            "11111111-1111-1111-1111-111111111102",
            CGRect(x: 0.05, y: 0.30, width: 0.90, height: 0.25),
            rows: [["项目", "NRV%"], ["能量", "17%"]]
        )
        let figureBlock = figure(
            "11111111-1111-1111-1111-111111111103",
            CGRect(x: 0.10, y: 0.03, width: 0.80, height: 0.22)
        )
        let barcodeBlock = ReconstructBlock(
            kind: .barcode,
            bbox: CGRect(x: 0.40, y: 0.85, width: 0.20, height: 0.08),
            text: "https://example.com"
        )
        let artworkBlock = ReconstructBlock(
            kind: .artwork,
            bbox: CGRect(x: 0.35, y: 0.05, width: 0.30, height: 0.15),
            text: ""
        )
        let blocks = [paragraph, tableBlock, figureBlock, barcodeBlock, artworkBlock]

        let result = resolve(blocks)

        #expect(result.blocks == blocks, "无冲突输入必须是恒等映射（逐字段相等）")
        #expect(result.report == LayoutReport(), "无冲突输入的报告必须全零")
    }

    // MARK: - ② 两两不相交

    @Test("合成冲突夹具消解后实心块两两不相交，先序块原地")
    func allSolidPairsResolved() {
        let a = text("22222222-2222-2222-2222-222222222201", CGRect(x: 0.05, y: 0.75, width: 0.90, height: 0.20))
        let b = text("22222222-2222-2222-2222-222222222202", CGRect(x: 0.05, y: 0.60, width: 0.90, height: 0.20))
        let c = text("22222222-2222-2222-2222-222222222203", CGRect(x: 0.05, y: 0.40, width: 0.90, height: 0.20))

        let result = resolve([a, b, c])

        assertAllSolidPairsClear(result.blocks)
        #expect(result.blocks[0].bbox == a.bbox, "先序块（阅读序最前）必须原地不动")
        #expect(abs(result.blocks[1].bbox.minY - 0.55) < 1e-9)
        #expect(abs(result.blocks[2].bbox.minY - 0.35) < 1e-9)
        #expect(result.report.yieldCount == 2)
        #expect(abs(result.report.totalShift - 0.10) < 1e-9)
    }

    // MARK: - ③ 阅读顺序不变

    @Test("消解只动几何不动顺序：输出 id 序列与输入一致")
    func readingOrderPreserved() {
        let a = text("33333333-3333-3333-3333-333333333301", CGRect(x: 0.05, y: 0.70, width: 0.40, height: 0.20))
        let b = text("33333333-3333-3333-3333-333333333302", CGRect(x: 0.55, y: 0.60, width: 0.40, height: 0.25))
        let c = text("33333333-3333-3333-3333-333333333303", CGRect(x: 0.05, y: 0.55, width: 0.90, height: 0.15))

        let result = resolve([a, b, c])

        #expect(result.blocks.map(\.id) == [a.id, b.id, c.id])
    }

    // MARK: - ④ 让位方向

    @Test("让位方向：下块下移清上块底边，上块上移清下块顶边")
    func yieldDirection() {
        // (a) 先序在上、后序在下 → 后序下移，maxY 精确收齐到上块 minY
        let upper = text("44444444-4444-4444-4444-444444444401", CGRect(x: 0.05, y: 0.70, width: 0.90, height: 0.20))
        let lower = text("44444444-4444-4444-4444-444444444402", CGRect(x: 0.05, y: 0.55, width: 0.90, height: 0.20))
        let down = resolve([upper, lower])

        #expect(down.blocks[0].bbox == upper.bbox, "被让位方原地不动")
        let moved = down.blocks[1].bbox
        // maxY = (stay.minY − h) + h 为浮点合成值（非直接拷贝），容 1e-12 合成误差
        #expect(abs(moved.maxY - upper.bbox.minY) < 1e-12, "让位块底边贴齐先序块顶边（最小平移）")
        #expect(moved.minY == upper.bbox.minY - lower.bbox.height)

        // (b) 先序在下、后序在上（跨栏阅读序的正常产物）→ 后序上移，minY 抬到下块 maxY
        let bottom = text("44444444-4444-4444-4444-444444444403", CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.20))
        let top = text("44444444-4444-4444-4444-444444444404", CGRect(x: 0.05, y: 0.25, width: 0.90, height: 0.20))
        let up = resolve([bottom, top])

        #expect(up.blocks[0].bbox == bottom.bbox)
        let lifted = up.blocks[1].bbox
        #expect(lifted.minY == bottom.bbox.maxY, "上移块底边精确贴齐下块顶边")
        #expect(lifted.maxY == bottom.bbox.maxY + top.bbox.height)
    }

    // MARK: - ⑤ 链式传播收敛

    @Test("链式传播：让位引发的新相交继续消解至不动点")
    func chainPropagationConverges() {
        let a = text("55555555-5555-5555-5555-555555555501", CGRect(x: 0.05, y: 0.65, width: 0.90, height: 0.20))
        let b = text("55555555-5555-5555-5555-555555555502", CGRect(x: 0.05, y: 0.55, width: 0.90, height: 0.20))
        let c = text("55555555-5555-5555-5555-555555555503", CGRect(x: 0.05, y: 0.45, width: 0.90, height: 0.20))
        let d = text("55555555-5555-5555-5555-555555555504", CGRect(x: 0.05, y: 0.35, width: 0.90, height: 0.20))

        let result = resolve([a, b, c, d])

        assertAllSolidPairsClear(result.blocks)
        #expect(result.blocks[0].bbox == a.bbox)
        // b 压 c、c 压 d 一路传播：最终四块精确堆叠互不相交
        #expect(abs(result.blocks[1].bbox.minY - 0.45) < 1e-9)
        #expect(abs(result.blocks[2].bbox.minY - 0.25) < 1e-9)
        #expect(abs(result.blocks[3].bbox.minY - 0.05) < 1e-9)
        #expect(result.report.yieldCount == 4)
        // 平移量：b 上移 0.10 → c 上移 0.20 → d 上移 0.10 → d 再上移 0.20 = 0.60
        #expect(abs(result.report.totalShift - 0.60) < 1e-9)
    }

    // MARK: - ⑥ 页界夹取

    @Test("页界夹取：越界区域夹回页内，页内块一个浮点都不动")
    func pageClamp() {
        let belowPage = text("66666666-6666-6666-6666-666666666601", CGRect(x: 0.05, y: -0.05, width: 0.90, height: 0.35))
        let beyondRight = figure("66666666-6666-6666-6666-666666666602", CGRect(x: 0.90, y: 0.40, width: 0.15, height: 0.20))
        let inside = text("66666666-6666-6666-6666-666666666603", CGRect(x: 0.05, y: 0.60, width: 0.60, height: 0.20))

        let result = resolve([belowPage, beyondRight, inside])

        #expect(result.blocks[0].bbox.minY == 0)
        #expect(abs(result.blocks[0].bbox.maxY - 0.30) < 1e-9)
        #expect(abs(result.blocks[1].bbox.maxX - 1.0) < 1e-9)
        #expect(abs(result.blocks[1].bbox.minX - 0.90) < 1e-9)
        #expect(result.blocks[2].bbox == inside.bbox, "页内无冲突块必须逐位不动（零扰动）")
    }

    // MARK: - ⑦ 表格让位与文字保留

    @Test("表格让位只动 bbox 不动行列；text 撞 table 时 text 让位")
    func tableYieldsWithRowsPreserved() {
        // table×table：后序让位，行列内容原样
        let t1 = table(
            "77777777-7777-7777-7777-777777777701",
            CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.25),
            rows: [["项目", "每100克", "NRV%"], ["能量", "1429千焦", "17%"]]
        )
        let t2 = table(
            "77777777-7777-7777-7777-777777777702",
            CGRect(x: 0.10, y: 0.35, width: 0.80, height: 0.25),
            rows: [["a"], ["b"]]
        )
        let result = resolve([t1, t2])

        #expect(result.blocks[0].bbox == t1.bbox, "先序 table 原地")
        // maxY = (stay.minY − h) + h 为浮点合成值，容 1e-12 合成误差
        #expect(abs(result.blocks[1].bbox.maxY - t1.bbox.minY) < 1e-12, "让位 table 底边贴齐先序 table 顶边")
        #expect(result.blocks[1].table?.rows == [["a"], ["b"]], "让位后行列内容一字不丢")
        #expect(result.blocks[0].table?.rows == t1.table?.rows)

        // text×table：**text 让位**（表格 bbox 来自结构化识别，可信度高）
        let caption = text("77777777-7777-7777-7777-777777777703", CGRect(x: 0.05, y: 0.55, width: 0.90, height: 0.20))
        let tableBlock = table(
            "77777777-7777-7777-7777-777777777704",
            CGRect(x: 0.05, y: 0.40, width: 0.90, height: 0.20),
            rows: [["x"]]
        )
        let textYields = resolve([caption, tableBlock])

        #expect(textYields.blocks[1].bbox == tableBlock.bbox, "table 永不让位给 text")
        #expect(textYields.blocks[0].bbox.minY == tableBlock.bbox.maxY, "text 向远离 table 一侧平移")
        #expect(textYields.blocks[0].text == caption.text)
    }

    // MARK: - ⑧ table×figure：figure 收缩

    @Test("table×figure 相交：figure 收缩剔除相交部分，table 原地")
    func tableFigureIntersectionShrinksFigure() {
        // figure 在 table 上方：底边收到 table 顶边
        let tableBlock = table(
            "88888888-8888-8888-8888-888888888801",
            CGRect(x: 0.10, y: 0.40, width: 0.80, height: 0.30),
            rows: [["项目"]]
        )
        let figureAbove = figure("88888888-8888-8888-8888-888888888802", CGRect(x: 0.10, y: 0.55, width: 0.80, height: 0.30))
        let above = resolve([tableBlock, figureAbove])

        #expect(above.blocks[0].bbox == tableBlock.bbox, "table 原地")
        #expect(above.blocks[1].bbox.minY == tableBlock.bbox.maxY, "figure 底边贴齐 table 顶边（剔除相交带）")
        #expect(abs(above.blocks[1].bbox.maxY - 0.85) < 1e-9, "收缩只裁相交侧，另一侧原样")
        #expect(above.report.figureShrinkCount == 1)

        // figure 在 table 下方：顶边收到 table 底边
        let figureBelow = figure("88888888-8888-8888-8888-888888888803", CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.30))
        let below = resolve([tableBlock, figureBelow])

        // maxY = minY + (tbl.minY − minY) 为浮点合成值，容 1e-12 合成误差
        #expect(abs(below.blocks[1].bbox.maxY - tableBlock.bbox.minY) < 1e-12, "figure 顶带收齐 table 底边")
        #expect(abs(below.blocks[1].bbox.minY - 0.20) < 1e-9)
    }

    @Test("text×figure 相交保留（图上说明字例外，FR-002）")
    func textFigureOverlapIsPreserved() {
        let figureBlock = figure("88888888-8888-8888-8888-888888888804", CGRect(x: 0.10, y: 0.30, width: 0.80, height: 0.40))
        let caption = text("88888888-8888-8888-8888-888888888805", CGRect(x: 0.30, y: 0.45, width: 0.40, height: 0.10))

        let result = resolve([figureBlock, caption])

        #expect(result.blocks[0].bbox == figureBlock.bbox, "figure 不为 text 收缩")
        #expect(result.blocks[1].bbox == caption.bbox, "图上说明字保持原位（例外语义）")
        #expect(result.report == LayoutReport())
    }

    // MARK: - ⑨ 跨栏宽行双峰拆分

    @Test("跨栏宽行双峰拆分：块宽 > 版心 70% 且行 midX 双峰")
    func wideBimodalBlockSplits() {
        let wide = ReconstructBlock(
            id: uuid("99999999-9999-9999-9999-999999999901"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.40, width: 0.80, height: 0.15),
            text: "左一\n左二\n右一\n右二",
            lines: [
                BlockLine(text: "左一", height: 0.02, gapToPrevious: 0, leadingOffset: 0.00, width: 0.30),
                BlockLine(text: "左二", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.02, width: 0.28),
                BlockLine(text: "右一", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.45, width: 0.30),
                BlockLine(text: "右二", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.47, width: 0.26)
            ],
            measuredLineHeight: 0.02
        )

        let result = resolve([wide])

        #expect(result.blocks.count == 2, "双峰宽块拆成左右两块")
        #expect(result.report.splitCount == 1)

        let left = result.blocks[0]
        let right = result.blocks[1]
        #expect(left.text == "左一\n左二")
        #expect(right.text == "右一\n右二")
        #expect(left.lines?.map(\.text) == ["左一", "左二"])
        #expect(right.lines?.map(\.text) == ["右一", "右二"])
        #expect(abs((left.measuredLineHeight ?? 0) - 0.02) < 1e-9)

        // 左块：x [0.05, 0.35]（行并集），y [0.50, 0.55]（左侧两行的累积 y）
        #expect(abs(left.bbox.minX - 0.05) < 1e-9)
        #expect(abs(left.bbox.maxX - 0.35) < 1e-9)
        #expect(abs(left.bbox.maxY - 0.55) < 1e-9)
        #expect(abs(left.bbox.minY - 0.50) < 1e-9)
        // 右块：x [0.50, 0.80]，y [0.44, 0.49]
        #expect(abs(right.bbox.minX - 0.50) < 1e-9)
        #expect(abs(right.bbox.maxX - 0.80) < 1e-9)
        #expect(abs(right.bbox.maxY - 0.49) < 1e-9)
        #expect(abs(right.bbox.minY - 0.44) < 1e-9)

        // 派生 id：确定、互异、不等于原 id
        #expect(left.id != wide.id && right.id != wide.id && left.id != right.id)
        let again = resolve([wide])
        #expect(again.blocks.map(\.id) == result.blocks.map(\.id), "拆分 id 派生必须确定")

        // 阈值防御：窄于版心 70% 的双峰块不拆
        let narrow = ReconstructBlock(
            id: uuid("99999999-9999-9999-9999-999999999902"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.40, width: 0.55, height: 0.15),
            text: wide.text,
            lines: wide.lines,
            measuredLineHeight: 0.02
        )
        #expect(resolve([narrow]).blocks.count == 1)

        // 单峰不拆：midX 全挤在一处
        let unimodal = ReconstructBlock(
            id: uuid("99999999-9999-9999-9999-999999999903"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.40, width: 0.80, height: 0.15),
            text: "全都是左栏",
            lines: [
                BlockLine(text: "一", height: 0.02, gapToPrevious: 0, leadingOffset: 0.00, width: 0.30),
                BlockLine(text: "二", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.01, width: 0.28),
                BlockLine(text: "三", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.01, width: 0.30),
                BlockLine(text: "四", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.02, width: 0.28)
            ],
            measuredLineHeight: 0.02
        )
        #expect(resolve([unimodal]).blocks.count == 1)
    }

    // MARK: - ⑩ 确定性

    @Test("确定性：同输入两次调用输出与报告完全相等")
    func deterministicOutput() {
        let a = text("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAA01", CGRect(x: 0.05, y: 0.70, width: 0.90, height: 0.20))
        let b = text("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAA02", CGRect(x: 0.05, y: 0.60, width: 0.90, height: 0.20))
        let wide = ReconstructBlock(
            id: uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAA03"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.10, width: 0.80, height: 0.15),
            text: "左\n左\n右\n右",
            lines: [
                BlockLine(text: "左", height: 0.02, gapToPrevious: 0, leadingOffset: 0.00, width: 0.30),
                BlockLine(text: "左", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.02, width: 0.28),
                BlockLine(text: "右", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.45, width: 0.30),
                BlockLine(text: "右", height: 0.02, gapToPrevious: 0.01, leadingOffset: 0.47, width: 0.26)
            ],
            measuredLineHeight: 0.02
        )
        let blocks = [a, b, wide]

        let first = resolve(blocks)
        let second = resolve(blocks)

        #expect(first.blocks == second.blocks)
        #expect(first.report == second.report)
    }

    // MARK: - ⑪ 迭代上限

    @Test("迭代上限：装不下的病态夹具在 ≤4 轮内终止且不出页")
    func iterationCapTerminates() {
        // 4 块 × 0.30 高 = 1.20 > 页高 1.0 —— 物理上不可能全部无重叠放下。
        // 引擎必须在迭代上限内停下（页界收缩 / 残余重叠均可接受），绝不死循环。
        let a = text("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB01", CGRect(x: 0.05, y: 0.70, width: 0.90, height: 0.30))
        let b = text("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB02", CGRect(x: 0.05, y: 0.68, width: 0.90, height: 0.30))
        let c = text("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB03", CGRect(x: 0.05, y: 0.66, width: 0.90, height: 0.30))
        let d = text("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB04", CGRect(x: 0.05, y: 0.64, width: 0.90, height: 0.30))

        let result = resolve([a, b, c, d])

        #expect(result.report.resolveRounds <= 4, "消解轮次必须被钉死在 4 以内")
        for block in result.blocks {
            #expect(block.bbox.minY >= -1e-9)
            #expect(block.bbox.maxY <= 1 + 1e-9)
            #expect(!block.text.isEmpty, "极端情形文字也永不丢失")
        }
        // 终止且确定
        let again = resolve([a, b, c, d])
        #expect(again.blocks == result.blocks)
    }

    // MARK: - ⑫⑬⑭ 溢出阶梯（plan D6 / FR-006，US4）

    /// pageSize 800×1000px @96dpi → 页高 750pt、页宽 600pt（× 0.75）。
    private var pageHeightPT: Double { 750 }
    private var pageWidthPT: Double { 600 }

    @Test("溢出阶梯①：小框大文字先等比缩字号/行距（未触下限即放下，区域不动）")
    func overflowShrinksFontBeforeExpanding() {
        // 区域 0.04×750 = 30pt；内容 2 行 × 0.03×750 = 45pt → 溢出。
        // 等比缩至 s = 30/45 = 2/3：行高 0.02、字号 0.02×750×1.05 = 15.75pt（> 7pt
        // 下限）→ 放下；本步只动行几何，区域 bbox 不动。
        let block = ReconstructBlock(
            id: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCC01"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.60, width: 0.55, height: 0.04),
            text: "四个汉字\n四个汉字",
            lines: [
                BlockLine(text: "四个汉字", height: 0.03, gapToPrevious: 0, leadingOffset: 0, width: 0.20),
                BlockLine(text: "四个汉字", height: 0.03, gapToPrevious: 0, leadingOffset: 0, width: 0.20)
            ],
            measuredLineHeight: 0.03
        )

        let result = resolve([block])

        #expect(result.blocks.count == 1)
        let scaled = result.blocks[0]
        #expect(scaled.bbox == block.bbox, "缩字号阶段区域不动")
        let scaledHeight = scaled.lines?.first?.height ?? 0
        #expect(scaledHeight < 0.03, "行高必须被等比缩小，实际 \(scaledHeight)")
        #expect(scaledHeight > 0.03 * 7 / 23.625, "未触 7pt 下限（缩后字号 15.75pt > 7pt）")
        // 缩放后估算内容高度必须入区域（容浮点尘埃）
        let estimate = LayoutTypography.estimatedRenderHeight(
            lines: scaled.lines ?? [],
            blockWidth: scaled.bbox.width,
            pageWidthPT: pageWidthPT,
            pageHeightPT: pageHeightPT,
            baseFontPT: LayoutTypography.fontPT(for: scaled, pageHeightPT: pageHeightPT)
        )
        #expect(estimate <= 0.04 * pageHeightPT + 1e-6, "缩放后估算高度须入区域：\(estimate)")
        #expect(result.report.overflowShrinkCount == 1)
        #expect(result.report.overflowExpandCount == 0)
        #expect(result.report.overflowExtremeCount == 0)
    }

    @Test("溢出阶梯②：下限字号仍放不下 → 向下扩展吸收空白带且不侵入下方块")
    func overflowExpandsIntoBlankBandBelow() {
        // 区域 0.016×750 = 12pt；内容 3 行 × 0.04×750 = 90pt → 压到 7pt 下限当量仍
        // 3 × 6.667 = 20pt。下方块顶 0.45，空隙 0.05×750 = 37.5pt ≥ 需求 8pt →
        // 底边下扩 8/750，不侵入下方块。
        let overfull = ReconstructBlock(
            id: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCC02"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.50, width: 0.55, height: 0.016),
            text: "四个汉字\n四个汉字\n四个汉字",
            lines: [
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20),
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20),
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20)
            ],
            measuredLineHeight: 0.04
        )
        let below = text("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCC03", CGRect(x: 0.05, y: 0.30, width: 0.55, height: 0.15))

        let result = resolve([overfull, below])

        let expanded = result.blocks[0]
        #expect(
            abs(expanded.bbox.minY - (0.50 - 8.0 / 750)) < 1e-9,
            "底边应下扩 8pt/750，实际 minY \(expanded.bbox.minY)"
        )
        #expect(abs(expanded.bbox.height - (0.016 + 8.0 / 750)) < 1e-9)
        #expect(result.blocks[1].bbox == below.bbox, "下方块不得被侵入或移动")
        let overlap = expanded.bbox.intersection(below.bbox)
        #expect(overlap.isNull || overlap.width <= 0 || overlap.height <= 0, "扩展后不得与下方块相交")
        // 行高已压至 7pt 下限当量：0.04 × 7 / 31.5（raw 字号 0.04×750×1.05）
        let scaledHeight = expanded.lines?.first?.height ?? 0
        #expect(abs(scaledHeight - 0.04 * 7.0 / 31.5) < 1e-9, "行高压至下限当量，实际 \(scaledHeight)")
        #expect(result.report.overflowShrinkCount == 1, "先缩到下限（未解决）仍计入缩放步")
        #expect(result.report.overflowExpandCount == 1)
        #expect(result.report.overflowExtremeCount == 0)
    }

    @Test("溢出阶梯③：下限 + 空白耗尽 → 保文字完整且计入 overflowExtreme")
    func overflowExtremeKeepsTextIntact() {
        // 页底块：区域 0.008×750 = 6pt，页底空隙 6pt；下限当量内容 20pt，需求 14pt。
        // 扩展只吸收得到 6pt → 仍差 8pt → 极端路径：文字完整不截断、计数、不出页。
        let block = ReconstructBlock(
            id: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCC04"),
            kind: .paragraph,
            bbox: CGRect(x: 0.05, y: 0.008, width: 0.55, height: 0.008),
            text: "四个汉字\n四个汉字\n四个汉字",
            lines: [
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20),
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20),
                BlockLine(text: "四个汉字", height: 0.04, gapToPrevious: 0, leadingOffset: 0, width: 0.20)
            ],
            measuredLineHeight: 0.04
        )

        let result = resolve([block])

        #expect(result.report.overflowExtremeCount == 1, "下限 + 空白耗尽必须计入极端计数")
        #expect(result.report.overflowShrinkCount == 1)
        #expect(result.report.overflowExpandCount == 1, "空白带部分吸收也计入扩展")
        let extreme = result.blocks[0]
        #expect(extreme.lines?.count == 3, "极端路径文字完整（行不丢）")
        #expect(extreme.text == "四个汉字\n四个汉字\n四个汉字", "文本原样保留")
        #expect(abs(extreme.bbox.minY) < 1e-9, "扩展至页底后贴 0")
        #expect(extreme.bbox.minY >= 0 && extreme.bbox.maxY <= 1, "不出页")
    }

    // MARK: - 夹具与断言工具

    private func resolve(_ blocks: [ReconstructBlock]) -> (blocks: [ReconstructBlock], report: LayoutReport) {
        RegionLayoutEngine.resolve(blocks: blocks, layout: layout, pageSize: pageSize)
    }

    private func assertAllSolidPairsClear(_ blocks: [ReconstructBlock]) {
        let solid = blocks.filter { solidKinds.contains($0.kind) }
        for i in solid.indices {
            for j in solid.indices where j > i {
                let overlap = solid[i].bbox.intersection(solid[j].bbox)
                let overlaps = !overlap.isNull && overlap.width > 0 && overlap.height > 0
                #expect(!overlaps, "实心块 \(solid[i].id) 与 \(solid[j].id) 仍有相交")
            }
        }
    }

    private func uuid(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else {
            Issue.record("夹具 UUID 非法：\(string)")
            return UUID()
        }
        return id
    }

    private func text(_ id: String, _ bbox: CGRect, text content: String = "正文") -> ReconstructBlock {
        ReconstructBlock(
            id: uuid(id),
            kind: .paragraph,
            bbox: bbox,
            text: content
        )
    }

    private func table(_ id: String, _ bbox: CGRect, rows: [[String]]) -> ReconstructBlock {
        ReconstructBlock(
            id: uuid(id),
            kind: .table,
            bbox: bbox,
            text: "",
            table: ReconstructTable(rows: rows)
        )
    }

    private func figure(_ id: String, _ bbox: CGRect) -> ReconstructBlock {
        ReconstructBlock(
            id: uuid(id),
            kind: .figure,
            bbox: bbox,
            text: ""
        )
    }
}
