import Foundation

enum OnDeviceReadingOrder {
    static func makeBlocks(from lines: [OCRLine]) -> [ReconstructBlock] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }
        let medianH = median(usable.map(\.boundingBox.height))
        // M2.5 收尾：剔除首段中孤立的顶部短行（页眉）。
        // HeaderFooterClassifier 是按 band 维度判（5 行带太厚过不了 height 检查），
        // 这里在行级兜底：若首段第一行非常短、且后面有更长的行 → 把首行丢掉。
        // 适配 workbook 右上「Test 4」+ 标题「Test 4 Questions 1~5（...）」的情形。
        let filtered: [OCRLine] = {
            guard usable.count > 1 else { return usable }
            let sorted = usable.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            guard let first = sorted.first, let second = sorted.dropFirst().first else { return usable }
            let firstIsAtTop = first.boundingBox.maxY > 0.93
            let firstIsShortLine = first.text.count < 10
                && first.boundingBox.height < medianH * 1.8
            let secondIsLonger = second.text.count > first.text.count * 2
            if firstIsAtTop && firstIsShortLine && secondIsLonger {
                return Array(sorted.dropFirst())
            }
            return usable
        }()
        let rows = clusterRows(filtered)
        guard !rows.isEmpty else { return [] }
        let paragraphs = clusterParagraphs(rows, medianHeight: medianH)
        return paragraphs.enumerated().map { index, paragraph in
            // M2.5 收尾：标题判定 —— CJK 短文本（4 字）也算；拉丁/数字文本需更长（≥ 8 字符）
            // 才算标题；还要单行（避免吞整段）。
            let cjkCount = paragraph.text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            let nonCjkCount = paragraph.text.count - cjkCount
            let weightedLength = cjkCount * 2 + nonCjkCount
            // 外部标题提示（只有 iOS 26 结构化通路会给）优先于按行高猜的启发式。
            // 几何通路下所有 line 的 isTitle 都是 false，这里与改动前完全一致。
            let hasTitleHint = paragraph.rows.contains { row in
                row.lines.contains { $0.isTitle }
            }
            let isHeading = (index == 0
                && paragraph.rows.count <= 2
                && weightedLength >= 8
                && paragraph.text.count <= 60
                && paragraph.height > medianH * 1.1)
                || (hasTitleHint && paragraph.text.count <= 60)
            let isList = looksLikeList(paragraph.text)
            let kind: ReconstructBlockKind = isHeading ? .heading : (isList ? .list : .paragraph)
            // 行几何上块（spec/layout-engine plan D3/D7）：只附加几何，不改文本拼接。
            let geometry = blockLines(for: paragraph)
            return ReconstructBlock(
                kind: kind,
                bbox: paragraph.bbox,
                text: paragraph.text,
                style: isHeading ? .heading : .body,
                lines: geometry.lines,
                measuredLineHeight: geometry.measuredLineHeight
            )
        }
    }

    /// Row → `BlockLine` 映射 + 块级中位行高（spec/layout-engine plan D3/D7）。
    ///
    /// - `text` 用既有 `Row.text`（sameRow 碎片 join 产物，**拼接规则不变**——
    ///   `paragraph.text` 与逐行 text 以 "\n" 互切，渲染端行段与整块文本天然一致）；
    /// - `gapToPrevious` 与 `clusterParagraphs` 同口径（prev.minY − cur.maxY，可负：
    ///   行框垂直重叠时与逐行定位渲染模型同样累积，不造假数据）；
    /// - `leadingOffset` = 行 minX − 块 minX；`width` = 行水平延伸（引擎 midX 双峰
    ///   拆分与溢出换行估算依据，midX = leadingOffset + width / 2）；
    /// - `measuredLineHeight` = 块内行高中位数（字号精化依据）。
    private static func blockLines(for paragraph: Paragraph) -> (lines: [BlockLine], measuredLineHeight: Double) {
        var result: [BlockLine] = []
        var previous: Row?
        for row in paragraph.rows {
            let gap: CGFloat = previous.map { $0.bbox.minY - row.bbox.maxY } ?? 0
            // T011（spec/scan-fidelity US2 / FR-005）：行内分段采集——row.lines 每个
            // OCR 分段一个 `LineSegment`（offset = 分段 minX − 块 minX，与
            // `leadingOffset` 同基准；width = 分段宽），行内按 minX 升序（聚类已
            // 保证，此处幂等重排兜底）。单段行也写 segments——消费端（T012 DOCX
            // 多 run / T013 预览分段定位）无需特判段数，单段几何与整行路径恒等。
            let segments = row.lines
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map { line in
                    LineSegment(
                        text: line.text,
                        offset: Double(line.boundingBox.minX - paragraph.bbox.minX),
                        width: Double(line.boundingBox.width)
                    )
                }
            result.append(
                BlockLine(
                    text: row.text,
                    height: Double(row.bbox.height),
                    gapToPrevious: Double(gap),
                    leadingOffset: Double(row.bbox.minX - paragraph.bbox.minX),
                    width: Double(row.bbox.width),
                    segments: segments
                )
            )
            previous = row
        }
        let measured = Double(median(paragraph.rows.map { $0.bbox.height }))
        return (result, measured)
    }

    private struct Row {
        var lines: [OCRLine]
        var bbox: CGRect
        var height: CGFloat { bbox.height }
        var text: String { join(lines.map(\.text)) }
    }

    private struct Paragraph {
        var rows: [Row]
        var bbox: CGRect
        var height: CGFloat { bbox.height }
        var text: String { rows.map(\.text).joined(separator: "\n") }
    }

    private static func clusterRows(_ lines: [OCRLine]) -> [Row] {
        // M2.5 收尾：sameRow 阈值从固定 0.02 改为自适应 `min(0.025, 0.4 × medianH)`，
        // 让 Section 1/2（minY 差 0.018、height ~0.06）不再被合并为同一行。
        // 0.018 < 0.025 ✓ 分行；0.4 × 0.029 = 0.012，又避免太敏感把大行距的相邻行也合掉。
        let heights = lines.map(\.boundingBox.height)
        let medianH = median(heights)
        let rowThreshold = min(0.025, max(0.012, 0.4 * medianH))
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > rowThreshold {
                return lhs.boundingBox.minY > rhs.boundingBox.minY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var rows: [Row] = []
        for line in sorted {
            // T010（spec/scan-fidelity US2 / R2）：反向扫描全部已有行（新 → 旧），
            // 并入第一个命中行。旧「只看最后一行」在排序把同行分段拆进不同位置时
            // 会让后到的分段找不到先到的同行（对话区 B minX 0.098 < A2 0.279，
            // B 排在 A2 前面 → A2 到达时 last 是 B 的行）——反向扫描让碎片回到
            // 视觉同行；未命中照旧新建行，行序 = 首成员出现序（与旧行为同语义）。
            if let index = rows.lastIndex(where: { sameRow($0.bbox, line.boundingBox) }) {
                var row = rows[index]
                row.lines.append(line)
                row.lines.sort { $0.boundingBox.minX < $1.boundingBox.minX }
                row.bbox = row.lines.map(\.boundingBox).reduce(row.bbox) { $0.union($1) }
                rows[index] = row
            } else {
                rows.append(Row(lines: [line], bbox: line.boundingBox))
            }
        }
        return rows
    }

    private static func clusterParagraphs(_ rows: [Row], medianHeight: CGFloat) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        for row in rows {
            if var last = paragraphs.last {
                let gap = last.bbox.minY - row.bbox.maxY
                let indentJump = abs(row.bbox.minX - last.bbox.minX) > 0.18
                if gap > medianHeight * 1.6 || indentJump {
                    paragraphs.append(Paragraph(rows: [row], bbox: row.bbox))
                } else {
                    last.rows.append(row)
                    last.bbox = last.bbox.union(row.bbox)
                    paragraphs[paragraphs.count - 1] = last
                }
            } else {
                paragraphs.append(Paragraph(rows: [row], bbox: row.bbox))
            }
        }
        return paragraphs
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        // M2.5：从 0.45 改 0.30，让 Section 1/2 (midY diff 0.021, max h 0.066) 不再被
        // 误判为同一行。普通同行内 midY 差 < 0.01，0.30×h 仍能容下。
        // T010（spec/scan-fidelity US2 / R2）：在旧 midY 规则之上**合取**垂直重叠
        // 条件（overlap ≥ 0.5 × min(h)）——对话行相邻碎片（行 A 并集与 B：midY 差
        // 0.0116 仍过旧规则）y 跨度几乎不重叠（overlap 0.0046 < 0.0074），旧规则
        // 会并、合取式拆开；真同行（顶/底对齐，重叠 ≥ 矮行高一半）不受影响。
        // 合取式严格窄于旧规则（只拆不并），基线行为只增不减。
        // 注：plan D2 原案「替换为纯重叠率」会把 Section 1/2（重叠 0.0416 ≥
        // 0.0296）并回一行、破坏既有 workbook 顺序测试——与「基线只增不减」硬
        // 冲突，故取合取式（偏差记录见 T010 日志）。
        let midYClose = abs(a.midY - b.midY) < max(0.012, 0.30 * max(a.height, b.height))
        guard midYClose else { return false }
        let overlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return overlap >= 0.5 * min(a.height, b.height)
    }

    private static func looksLikeList(_ text: String) -> Bool {
        let first = text.trimmingCharacters(in: .whitespaces)
        return first.hasPrefix("•")
            || first.hasPrefix("-")
            || first.hasPrefix("·")
            || first.hasPrefix("○")
            || first.hasPrefix("◎")
            || first.range(of: #"^\d+[\.、]"#, options: .regularExpression) != nil
    }

    private static func join(_ parts: [String]) -> String {
        let cjkHeavy = parts.contains { OCRTextQuality.cjkCount($0) >= max(1, $0.count / 2) }
        return parts.joined(separator: cjkHeavy ? "" : " ")
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0.04 }
        return sorted[sorted.count / 2]
    }
}
