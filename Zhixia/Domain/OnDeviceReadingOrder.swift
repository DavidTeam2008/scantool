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
            let isHeading = index == 0
                && paragraph.rows.count <= 2
                && weightedLength >= 8
                && paragraph.text.count <= 60
                && paragraph.height > medianH * 1.1
            let isList = looksLikeList(paragraph.text)
            let kind: ReconstructBlockKind = isHeading ? .heading : (isList ? .list : .paragraph)
            return ReconstructBlock(
                kind: kind,
                bbox: paragraph.bbox,
                text: paragraph.text,
                style: isHeading ? .heading : .body
            )
        }
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
            if var last = rows.last, sameRow(last.bbox, line.boundingBox) {
                last.lines.append(line)
                last.lines.sort { $0.boundingBox.minX < $1.boundingBox.minX }
                last.bbox = last.lines.map(\.boundingBox).reduce(last.bbox) { $0.union($1) }
                rows[rows.count - 1] = last
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
        abs(a.midY - b.midY) < max(0.012, 0.30 * max(a.height, b.height))
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
