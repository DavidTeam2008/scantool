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
