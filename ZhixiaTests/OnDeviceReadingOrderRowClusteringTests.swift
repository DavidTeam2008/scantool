import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// T014（spec/scan-fidelity US2 / R1 / R2）：对话/填空行聚类 —— DialogueRowFixture
/// 驱动的行结构断言。
///
/// 修复目标（对 R1「同排异高分段被拆散」与 R2「相邻视觉行误并导致乱序拼接」）：
/// - 同排分段（顶/底对齐、行高异构）必须合并为一个视觉行（R1）；
/// - 相邻视觉行（行 A 第二段与行 B 的 minY 差仅 0.0102，旧 midY 规则 0.012
///   下限误并）必须分开（R2）；
/// - 行内分段按 minX 升序、segments 采集逐位正确（T011，供 T012/T013 空隙
///   下划线占位消费）；
/// - 7 个 OCR 分段 → 4 个视觉行，一个段落块，语序自上而下。
struct OnDeviceReadingOrderRowClusteringTests {

    @Test("对话行：同排合并、相邻行分开、语序与 segments 采集正确")
    func dialogueRowsClusterByVisualLine() throws {
        let blocks = OnDeviceReadingOrder.makeBlocks(from: DialogueRowFixture.lines)

        // 7 个 OCR 分段 → 4 个视觉行；行距/缩进都在段落阈值内 → 1 个块
        #expect(blocks.count == 1, "对话区应聚为 1 个块，实际 \(blocks.count)")
        let block = try #require(blocks.first)
        #expect(block.kind == .paragraph, "4 行块不应判为标题/列表")

        let lines = try #require(block.lines)
        #expect(
            lines.count == DialogueRowFixture.expectedRowTexts.count,
            "行数应 = 视觉行数 4（同排不拆散 + 相邻行不合并），实际 \(lines.count)"
        )

        // 语序：行文本自上而下与期望一致（拉丁分段空格连接，与 join 规则一致）
        for (index, expected) in DialogueRowFixture.expectedRowTexts.enumerated() {
            #expect(
                lines[index].text == expected,
                "第 \(index) 行文本应为「\(expected)」，实际「\(lines[index].text)」"
            )
        }

        // R2 乱序回归：旧规则把行 B 并进行 A 的乱序拼接（"homework. three"）
        // 不得再现；同时每个分段文本都必须保留在块内。
        #expect(!block.text.contains("homework. three"), "相邻视觉行不得串接（R2 乱序拼接再现）")
        for fragment in DialogueRowFixture.allRows.flatMap({ $0 }).map(\.text) {
            #expect(block.text.contains(fragment), "分段文本「\(fragment)」丢失")
        }

        // 块 minX = 各行 minX 最小值（segments offset / leadingOffset 的基准）
        #expect(abs(block.bbox.minX - DialogueRowFixture.expectedBlockMinX) < 1e-6)

        // segments 采集（T011）：分段成员 / offset / width 与期望逐位一致，minX 升序
        for (lineIndex, expectedSegments) in DialogueRowFixture.expectedSegmentsByRow.enumerated() {
            let segments = try #require(lines[lineIndex].segments, "第 \(lineIndex) 行缺 segments")
            #expect(
                segments.count == expectedSegments.count,
                "第 \(lineIndex) 行分段数应 \(expectedSegments.count)，实际 \(segments.count)"
            )
            for (segIndex, expected) in expectedSegments.enumerated() {
                let actual = segments[segIndex]
                #expect(
                    actual.text == expected.text,
                    "L\(lineIndex)S\(segIndex) 文本应为「\(expected.text)」，实际「\(actual.text)」"
                )
                #expect(
                    abs(actual.offset - expected.offset) < 1e-6,
                    "L\(lineIndex)S\(segIndex) offset 应 \(expected.offset)，实际 \(actual.offset)"
                )
                #expect(
                    abs(actual.width - expected.width) < 1e-6,
                    "L\(lineIndex)S\(segIndex) width 应 \(expected.width)，实际 \(actual.width)"
                )
            }
            let offsets = segments.map(\.offset)
            #expect(offsets == offsets.sorted(), "第 \(lineIndex) 行分段应按 minX 升序")
        }

        // 行帧几何：行高 = 行并集高（R1——同排异高分段取并集，既不拆散也不取矮段）
        let expectedHeights: [Double] = [0.0176, 0.0148, 0.0140, 0.0176]
        for (index, expected) in expectedHeights.enumerated() {
            #expect(
                abs(lines[index].height - expected) < 1e-6,
                "第 \(index) 行行高应 \(expected)，实际 \(lines[index].height)"
            )
        }
        // 行首偏移 = 行 minX − 块 minX
        let expectedLeading: [Double] = [0.000, 0.047, 0.025, 0.098]
        for (index, expected) in expectedLeading.enumerated() {
            #expect(
                abs(lines[index].leadingOffset - expected) < 1e-6,
                "第 \(index) 行 leadingOffset 应 \(expected)，实际 \(lines[index].leadingOffset)"
            )
        }

        // 段间填空空隙（T012/T013 下划线占位的数据依据）：A/C/D 三行逐位相符，
        // 且全部超过 0.6 字符宽阈值（fontPT 12 / 页宽 450pt 下阈值 0.0096）——
        // 预览与 DOCX 都会画下划线占位。
        var gaps: [Double] = []
        for lineIndex in [0, 2, 3] {
            let segments = try #require(lines[lineIndex].segments)
            gaps.append(segments[1].offset - (segments[0].offset + segments[0].width))
        }
        for (index, expected) in DialogueRowFixture.expectedIntraRowGaps.enumerated() {
            #expect(
                abs(gaps[index] - expected) < 1e-6,
                "第 \(index) 个段间空隙应 \(expected)，实际 \(gaps[index])"
            )
        }
        for gap in gaps {
            #expect(
                LayoutTypography.gapPlaceholderSpaces(gapWidthNormalized: gap, fontPT: 12, pageWidthPT: 450) != nil,
                "填空空隙 \(gap) 应超过下划线占位阈值"
            )
        }
    }

    @Test("行聚类与输入顺序无关（排序 + 反向扫描的鲁棒性）")
    func rowClusteringIsInputOrderIndependent() throws {
        // fixture 7 分段的排序比较器约束构成全序（21 对两两有向），任意输入排列
        // 都产出同一 sorted 序列 → 聚类结果必须与输入顺序完全无关。
        let forward = OnDeviceReadingOrder.makeBlocks(from: DialogueRowFixture.lines)
        let reversed = OnDeviceReadingOrder.makeBlocks(from: Array(DialogueRowFixture.lines.reversed()))

        #expect(forward.count == reversed.count)
        let forwardLines = try #require(forward.first?.lines)
        let reversedLines = try #require(reversed.first?.lines)
        #expect(forwardLines.count == reversedLines.count)
        #expect(forwardLines.map(\.text) == reversedLines.map(\.text), "行文本应与输入顺序无关")
        #expect(forwardLines.map(\.height) == reversedLines.map(\.height), "行高应与输入顺序无关")
        #expect(forwardLines.map(\.leadingOffset) == reversedLines.map(\.leadingOffset))
        #expect(
            forwardLines.map { $0.segments?.map(\.text) ?? [] }
                == reversedLines.map { $0.segments?.map(\.text) ?? [] },
            "分段归属应与输入顺序无关"
        )
    }

    // MARK: - US3 聚类稳定（T015）

    @Test("聚类稳定：分段几何 ±5% 微扰三变体全部保持行结构")
    func perturbedVariantsKeepRowStructure() throws {
        // 同页多次扫描的 OCR 分段几何天然抖动（T015）：位置 minX/minY 平移
        // U(−1,1)×5%×(w/h)，尺寸 w/h 缩放 ×(1+U(−1,1)×5%)，SplitMix64 固定种子
        // （1/2/3）→ 三组变体跨运行完全确定。行结构不变量在抖动下必须全部成立
        // （margin 预分析：A 行 vs B 的重叠拆分裕度 ≥ 0.0008、C/D 的 midY 拆分
        // 裕度 ≥ 0.0012、A1+A2 合并重叠裕度 ≥ 0.003——±5% 全域安全）。
        for variant in 0..<3 {
            let perturbed = Self.perturbedLines(seed: UInt64(variant + 1))
            let blocks = OnDeviceReadingOrder.makeBlocks(from: perturbed)

            #expect(blocks.count == 1, "变体 \(variant)：应聚为 1 个块，实际 \(blocks.count)")
            let block = try #require(blocks.first)
            let lines = try #require(block.lines)
            #expect(
                lines.count == DialogueRowFixture.expectedRowTexts.count,
                "变体 \(variant)：行数应保持 4（同行分段不拆散 + 相邻行不合并），实际 \(lines.count)"
            )

            // 行文本与分段归属不变（几何抖动不改文本与成员关系——无跨行串接）
            for (index, expected) in DialogueRowFixture.expectedRowTexts.enumerated() {
                #expect(
                    lines[index].text == expected,
                    "变体 \(variant)：第 \(index) 行文本应为「\(expected)」，实际「\(lines[index].text)」"
                )
            }
            let groups = lines.map { $0.segments?.map(\.text) ?? [] }
            #expect(
                groups == DialogueRowFixture.expectedRowGroups,
                "变体 \(variant)：分段归属改变（跨行串接）"
            )
            #expect(
                !block.text.contains("homework. three"),
                "变体 \(variant)：相邻视觉行串接（R2 乱序再现）"
            )

            // 行内分段 minX 升序
            for (index, line) in lines.enumerated() {
                let offsets = line.segments?.map(\.offset) ?? []
                #expect(
                    offsets == offsets.sorted(),
                    "变体 \(variant)：第 \(index) 行分段 minX 序被破坏"
                )
            }
        }
    }

    // MARK: - wps-parity-layout T014（FR-005 页眉短行规则收紧，T010 落地）

    /// T010 收紧点 ①：位置约束从「上缘擦过」（maxY > 0.93）改为「整行落页顶
    /// 窄带」（minY > 0.93）。上缘擦过 0.93 但整行没挤进顶部 7% 的内容短行
    /// 不再被当页眉丢；窄带内的「Test 4」式孤立短页眉仍稳定命中。
    @Test("页眉窄带收紧：上缘擦过 0.93 的内容短行保留，窄带内孤立短页眉仍被剔")
    func headerRuleRequiresWholeLineInTopBand() {
        let body = OCRLine(
            text: "Choose the correct option A or B and write it down",
            boundingBox: CGRect(x: 0.10, y: 0.75, width: 0.80, height: 0.05)
        )
        // 擦带内容行：maxY 0.95 擦过 0.93，但 minY 0.90 → 旧规则误剔、新规则保留
        let grazing = OCRLine(
            text: "Quiz",
            boundingBox: CGRect(x: 0.40, y: 0.90, width: 0.20, height: 0.05)
        )
        let grazingBlocks = OnDeviceReadingOrder.makeBlocks(from: [grazing, body])
        #expect(
            grazingBlocks.map(\.text).joined(separator: "\n").contains("Quiz"),
            "上缘擦过窄带的内容短行不得被当页眉丢弃"
        )

        // 对照：整行落窄带（minY 0.95）+ 后行远长于它 → 仍按页眉剔
        let header = OCRLine(
            text: "Test 9",
            boundingBox: CGRect(x: 0.80, y: 0.95, width: 0.15, height: 0.02)
        )
        let headerBlocks = OnDeviceReadingOrder.makeBlocks(from: [header, body])
        #expect(
            !headerBlocks.map(\.text).joined(separator: "\n").contains("Test 9"),
            "窄带内孤立短页眉仍应被剔除"
        )
    }

    /// T010 收紧点 ②：句末标点守卫 —— 页眉标签（"Test 4"）不带句末标点，
    /// 正文短句（"wrong bus!" = 10 字符踩线教训）带。带句末标点的窄带短行
    /// 按正文处理。
    @Test("句末标点守卫：窄带内带句末标点的短行按正文保留")
    func punctuatedShortTopLineIsContentNotHeader() {
        let short = OCRLine(
            text: "Stop!",
            boundingBox: CGRect(x: 0.40, y: 0.95, width: 0.10, height: 0.02)
        )
        let body = OCRLine(
            text: "The bus finally arrived at the station on time",
            boundingBox: CGRect(x: 0.10, y: 0.80, width: 0.80, height: 0.02)
        )
        let blocks = OnDeviceReadingOrder.makeBlocks(from: [short, body])
        #expect(
            blocks.map(\.text).joined(separator: "\n").contains("Stop!"),
            "带句末标点的窄带短行是正文，不是页眉"
        )
    }

    /// T010 收紧点 ③：字符边界 10 → 8 且先 trim。未 trim 10 字符（旧阈值
    /// `< 10` 判「不短」而漏剔）、trim 后 7 字符的页眉仍要被剔；
    /// trim 后恰 8 字符的窄带短行不再命中（边界下沿，按正文保留）。
    @Test("字符边界 8 + 先 trim：trim 后 <8 仍剔，恰 8 字符保留")
    func headerCharBoundaryIsEightAfterTrim() {
        let body = OCRLine(
            text: "Answer all the questions in complete sentences",
            boundingBox: CGRect(x: 0.10, y: 0.75, width: 0.80, height: 0.02)
        )
        let padded = OCRLine(
            text: "  Test 44 ",
            boundingBox: CGRect(x: 0.78, y: 0.95, width: 0.18, height: 0.02)
        )
        let paddedBlocks = OnDeviceReadingOrder.makeBlocks(from: [padded, body])
        #expect(
            !paddedBlocks.map(\.text).joined(separator: "\n").contains("Test 44"),
            "trim 后 7 字符的窄带孤立短行仍应被剔除"
        )

        let eight = OCRLine(
            text: "Test 444",
            boundingBox: CGRect(x: 0.78, y: 0.95, width: 0.18, height: 0.02)
        )
        let eightBlocks = OnDeviceReadingOrder.makeBlocks(from: [eight, body])
        #expect(
            eightBlocks.map(\.text).joined(separator: "\n").contains("Test 444"),
            "trim 后恰 8 字符的窄带短行不满足 < 8，按正文保留"
        )
    }

    // MARK: - wps-parity-layout T019（US4 流式档段落切分回归锚，T018 落地）

    /// `FlowParagraphSplitter` 三判据 / 不变量的合成行回归：几何取金标准取证值
    /// 折算（对话轮换回撤 0.022~0.027、OCR 行首抖动 ≤ 0.006、第 2 节条目行距
    /// 0.002~0.006 —— 详录 `FlowParagraphSplitter` 文档与 T018 checkpoint）。
    /// 切分发生在导出侧、块与块序不动（scan-fidelity 聚类断言不受影响），
    /// 这里钉的是**切分参数与不变量**：阈值 0.012 / 条目号两位上限 / 句末标点
    /// 口径 / 无行几何恒等 / text-lines 失配回退，任一漂移都会变红。
    @Test("条目号起段：1~2 位数字起段，年份与三位数不切")
    func itemMarkerStartsParagraphWhileYearsDoNot() {
        // "1 Item…" 起段；其续行（无信号）并入同段
        let numbered = Self.flowBlock([
            Self.flowLine("First paragraph line one", lead: 0.030),
            Self.flowLine("1 Item one starts here", lead: 0.030),
            Self.flowLine("and continues here", lead: 0.054)
        ])
        Self.expectParagraphTexts(
            numbered,
            ["First paragraph line one", "1 Item one starts here\nand continues here"],
            "条目号行应起段，其续行应并入"
        )

        // 年份守卫："2010 was…" 四位数字，^\d{1,2} + 分隔符在位置 2/1 都取不到
        // 分隔符 → 不切；"999 items" 三位同理
        let year = Self.flowBlock([
            Self.flowLine("We moved here in", lead: 0.030),
            Self.flowLine("2010 was the year", lead: 0.030)
        ])
        Self.expectParagraphTexts(year, ["We moved here in\n2010 was the year"], "年份不得被当条目号切开")

        let threeDigits = Self.flowBlock([
            Self.flowLine("We counted", lead: 0.030),
            Self.flowLine("999 items in total", lead: 0.030)
        ])
        Self.expectParagraphTexts(threeDigits, ["We counted\n999 items in total"], "三位数不得被当条目号切开")

        // 中文顿号分隔符同样命中
        let chinese = Self.flowBlock([
            Self.flowLine("前面一句还没完", lead: 0.030),
            Self.flowLine("3、你好世界", lead: 0.030)
        ])
        Self.expectParagraphTexts(chinese, ["前面一句还没完", "3、你好世界"], "顿号条目号应起段")
    }

    /// 行首回撤判据：轮换回撤（0.024 > 0.012）切，抖动（0.002 < 0.012）与
    /// 恰在阈值（0.012，严格大于才切）不切。
    @Test("行首回撤起段：轮换回撤切，抖动与阈值边界不切")
    func leadingRetreatStartsParagraphWhileJitterDoesNot() {
        // 对话轮换取证形态：续行 0.076 → 轮首 0.052，回撤 0.024；
        // 前两行刻意不带句末标点 —— 切分必须只能来自回撤信号
        let turnTaking = Self.flowBlock([
            Self.flowLine("A: Yesterday l three hours", lead: 0.049),
            Self.flowLine("physics exercises for homework", lead: 0.076),
            Self.flowLine("B: It me a long time, too", lead: 0.052)
        ])
        Self.expectParagraphTexts(
            turnTaking,
            ["A: Yesterday l three hours\nphysics exercises for homework", "B: It me a long time, too"],
            "对话轮换的行首回撤应起段"
        )

        // OCR 抖动 0.002 远低于阈值 → 同段
        let jitter = Self.flowBlock([
            Self.flowLine("Line one stays", lead: 0.030),
            Self.flowLine("with the next line", lead: 0.028)
        ])
        Self.expectParagraphTexts(jitter, ["Line one stays\nwith the next line"], "行首抖动不得误切段落")

        // 恰 0.012（严格大于才切）→ 同段：边界下沿
        let boundary = Self.flowBlock([
            Self.flowLine("Edge exactly at", lead: 0.030),
            Self.flowLine("threshold stays together", lead: 0.018)
        ])
        Self.expectParagraphTexts(boundary, ["Edge exactly at\nthreshold stays together"], "回撤恰在阈值（0.012）不切（严格大于）")

        // 可调参数的回归锚：T018 定案阈值（抖动 ≤0.006 的 2 倍裕度）。
        // 重调此值必须是有意识的决策（改这里 + 行为断言一起动）。
        #expect(
            FlowParagraphSplitter.leadRetreatThreshold == 0.012,
            "leadRetreatThreshold 被改动 —— 金标准抖动/回撤取证（0.006/0.022~0.027）下的 2 倍裕度失效，重调须复核 T018 取证"
        )
    }

    /// 句末完结判据：上一行以句末标点（`.!?。！？…`，`OCRNoiseFilter` 同口径）
    /// 收尾 → 当前行起段；无标点不切。
    @Test("前句完结起段：句末标点切，无标点不切")
    func sentencePunctuationStartsParagraph() {
        let english = Self.flowBlock([
            Self.flowLine("One sentence ends here.", lead: 0.030),
            Self.flowLine("Second paragraph follows", lead: 0.054)
        ])
        Self.expectParagraphTexts(english, ["One sentence ends here.", "Second paragraph follows"], "英文句号后应起段")

        let chinese = Self.flowBlock([
            Self.flowLine("第一句到此结束。", lead: 0.030),
            Self.flowLine("第二段从这里开始", lead: 0.054)
        ])
        Self.expectParagraphTexts(chinese, ["第一句到此结束。", "第二段从这里开始"], "中文句号后应起段")

        let noPunct = Self.flowBlock([
            Self.flowLine("No terminal punctuation", lead: 0.030),
            Self.flowLine("so lines stay together", lead: 0.054)
        ])
        Self.expectParagraphTexts(noPunct, ["No terminal punctuation\nso lines stay together"], "无句末标点不得切段")
    }

    /// 不变量：无行几何恒等单段（旧行为字节不变）；text/lines 失配回退整块
    /// （文本零丢失）；正常切分组拼回 == 块文本（只改分组、不丢不重排）。
    @Test("不变量：无 lines 恒等，text/lines 失配回退，正常切分零丢失")
    func identityAndFallbackInvariantsHold() {
        // 无 lines（旧持久化 / 既有夹具）：恒等返回 [block.text]
        let legacy = ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2),
            text: "legacy block text"
        )
        Self.expectParagraphTexts(legacy, ["legacy block text"], "无行几何的块必须恒等单段（旧行为）")

        // 单行块：无切分可做
        let single = Self.flowBlock([Self.flowLine("only one line", lead: 0.030)])
        Self.expectParagraphTexts(single, ["only one line"], "单行块必须恒等单段")

        // text/lines 失配（生产方防御）：回退整块单段，文本零丢失
        let mismatch = Self.flowBlock(
            [
                Self.flowLine("line geometry says one thing", lead: 0.030),
                Self.flowLine("2 but block text disagrees", lead: 0.030)
            ],
            text: "block text is the source of truth here"
        )
        Self.expectParagraphTexts(
            mismatch,
            ["block text is the source of truth here"],
            "text/lines 失配必须回退整块单段（零丢失）"
        )

        // 正常切分：组拼回 == 块文本（只改分组），组数 > 1（确实切了）
        // 三判据各切一次：句号（0→1）、条目号（1→2）、轮换回撤 0.054→0.030
        // 即 0.024 > 0.012（2→3）。
        let mixed = Self.flowBlock([
            Self.flowLine("Intro sentence here.", lead: 0.030),
            Self.flowLine("1 first item line", lead: 0.030),
            Self.flowLine("item continuation", lead: 0.054),
            Self.flowLine("A new turn begins", lead: 0.030)
        ])
        let groups = FlowParagraphSplitter.paragraphTexts(in: mixed)
        #expect(groups.count == 3, "混合判据块应切 3 段，实际 \(groups.count)")
        #expect(
            groups.joined(separator: "\n") == mixed.text,
            "分段组拼回必须等于块文本 —— 只改分组，不丢字不重排"
        )
    }

    /// 切分测试合成行：几何取金标准取证量级（行高 0.015 / 行距 0.004 / 行宽 0.30），
    /// lead 由用例按判据场景给定。
    private static func flowLine(_ text: String, lead: Double) -> BlockLine {
        BlockLine(text: text, height: 0.015, gapToPrevious: 0.004, leadingOffset: lead, width: 0.30)
    }

    /// 切分测试合成块：默认块文本 = 行文本按 "\n" 连接（与生产方口径一致）；
    /// 失配场景用 `text:` 显式覆写。
    private static func flowBlock(_ lines: [BlockLine], text: String? = nil) -> ReconstructBlock {
        ReconstructBlock(
            kind: .paragraph,
            bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2),
            text: text ?? lines.map(\.text).joined(separator: "\n"),
            lines: lines
        )
    }

    private static func expectParagraphTexts(_ block: ReconstructBlock, _ expected: [String], _ message: String) {
        let actual = FlowParagraphSplitter.paragraphTexts(in: block)
        #expect(actual == expected, "\(message)：期望 \(expected) 段，实际 \(actual)")
    }

    /// SplitMix64（固定种子，跨运行确定）：`unit()` ∈ [0, 1)。
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double {
            Double(next() >> 11) * (1.0 / Double(UInt64(1) << 53))
        }
    }

    /// 微扰变体：每个分段 minX/minY += U(−1,1)×5%×(w/h)，w/h ×(1+U(−1,1)×5%)。
    /// 消费顺序 = fixture 视觉行序（聚类内部会重排）。
    private static func perturbedLines(seed: UInt64) -> [OCRLine] {
        var rng = SplitMix64(seed: seed)
        return DialogueRowFixture.allRows.flatMap { row in
            row.map { segment in
                let dx = (rng.unit() * 2 - 1) * 0.05 * Double(segment.width)
                let dy = (rng.unit() * 2 - 1) * 0.05 * Double(segment.height)
                let widthScale = 1 + (rng.unit() * 2 - 1) * 0.05
                let heightScale = 1 + (rng.unit() * 2 - 1) * 0.05
                return OCRLine(
                    text: segment.text,
                    boundingBox: CGRect(
                        x: segment.x + CGFloat(dx),
                        y: segment.y + CGFloat(dy),
                        width: segment.width * CGFloat(widthScale),
                        height: segment.height * CGFloat(heightScale)
                    )
                )
            }
        }
    }
}

/// 2026-10-24 真机回归：右上三行题头的 OCR 输入序是「下行在前、上行在后」，
/// 且行距为负。旧 `clusterRows` 在 minY 差小于「同一行阈值」时退化成按 minX
/// 排，导致上下颠倒；同时第三条右栏续行被 `indentJump` 拆成独立块。
struct HeaderLineOrderRegressionTests {
    @Test("负行距的三行题头：自上而下，右栏续行不拆块")
    func negativeGapHeaderStaysTopDown() throws {
        let lines = [
            OCRLine(
                text: "friends after school? something different from",
                boundingBox: CGRect(x: 0.5537, y: 0.8979, width: 0.3774, height: 0.0146)
            ),
            OCRLine(
                text: "What's fun to do with your How important is it to do",
                boundingBox: CGRect(x: 0.5537, y: 0.9125, width: 0.3774, height: 0.0167)
            ),
            OCRLine(
                text: "studying after school?",
                boundingBox: CGRect(x: 0.7600, y: 0.8838, width: 0.1522, height: 0.0151)
            )
        ]
        let blocks = OnDeviceReadingOrder.makeBlocks(from: lines)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        let texts = (block.lines ?? []).map(\.text)
        #expect(texts.count == 3)
        #expect(texts[0].hasPrefix("What's fun"))
        #expect(texts[1].hasPrefix("friends after"))
        #expect(texts[2].hasPrefix("studying after"))
    }
}
