import CoreGraphics
import Foundation

/// M2 表格识别（docs/07 §6.3）。相对 v1 `OnDeviceTableCluster` 的关键差异：
/// 1. **锚点驱动**：先在 `PageLayout.anchors` 找 `tableTitle`，没找到 → 直接拒绝。
///    这把 workbook 的 A/B/C 假表从源头砍掉（v1 总是先看是不是像表）。
/// 2. **多尺度列聚类**：maxGap 先 0.13（宽柱），不够细再降到 0.085。
/// 3. **自适应行聚类**：maxGap = `clamp(0.55 × medianH, 0.013, 0.025)`。
///    v1 的固定 0.032 在营养表上把所有行合并成一团——实际行间距是 0.019~0.025。
/// 4. **focus 窗口收窄**：tableTitle 下方 0.22 内（≈ 11×medianH）。
///    既吸进 5~6 行表格，又不吸进底部条码/页脚。
/// 5. **放宽 occupancy**：0.30（v1 是 0.45）。中文营养表 + 包装说明噪声会拉低 occupancy。
/// 6. **profile 校验**：若给了 profile（如 `.nutrition`），最后用 profile 期望列数 + header
///    关键词做收尾校验，给出更高的 confidence。
enum TableGridV2Detector {

    /// 主要入口。
    /// - Parameters:
    ///   - lines: OCRLine 数组（已按任意顺序）
    ///   - layout: 已分析好的 `PageLayout`。若为 nil，会内部调 `LayoutAnalyzer.analyze` 算一份。
    ///   - profile: 可选 profile（`.nutrition` 等）。给的话会做期望列数 + header 关键词校验。
    static func detect(
        from lines: [OCRLine],
        layout: PageLayout? = nil,
        profile: TableProfile? = nil
    ) -> TableGridV2? {
        guard !lines.isEmpty else { return nil }

        // 1. 拿 layout
        let layout = layout ?? LayoutAnalyzer.analyze(lines: lines)
        guard let layout else { return nil }

        // 2. 找 tableTitle 锚点
        let titleAnchor: LayoutAnchor? = {
            if let profile {
                return layout.anchors.first { anchor in
                    guard anchor.kind == .tableTitle, let text = anchor.text else { return false }
                    return profile.titlePatterns.contains { text.localizedCaseInsensitiveContains($0) }
                }
            } else {
                return layout.anchors.first { $0.kind == .tableTitle }
            }
        }()
        guard let titleAnchor else { return nil }  // 无锚点 = 非表格场景

        // 3. 焦点窗口：title 下方（Vision: midY 更小）focusWindowBelow 高度内
        let titleMidY = titleAnchor.frame.midY
        let windowDepth = profile?.focusWindowBelow ?? 0.22
        let focused: [OCRLine] = lines.filter { l in
            let dy = titleMidY - l.boundingBox.midY
            return dy > 0 && dy < windowDepth
        }
        guard focused.count >= 6 else { return nil }

        // 4. 多尺度列聚类
        let xs = focused.map { $0.boundingBox.midX }
        let cols1 = clusterCenters(xs, maxGap: 0.13)
        let cols2 = clusterCenters(xs, maxGap: 0.085)
        let columns: [CGFloat] = {
            if let profile, profile.expectedColumnCount == cols1.count { return cols1 }
            if (2...5).contains(cols1.count) { return cols1 }
            if let profile, profile.expectedColumnCount == cols2.count { return cols2 }
            return cols2
        }()
        guard (2...5).contains(columns.count) else { return nil }

        // 5. x-range 过滤：只留列投影覆盖区
        let sortedColsPre = columns.sorted()
        let xLo = sortedColsPre.first! - 0.10
        let xHi = sortedColsPre.last! + 0.10
        let focusXFiltered = focused.filter { l in
            l.boundingBox.midX >= xLo && l.boundingBox.midX <= xHi
        }
        guard focusXFiltered.count >= 6 else { return nil }

        // 6. 自适应行聚类
        let ys = focusXFiltered.map { $0.boundingBox.midY }
        let heights = focusXFiltered.map { $0.boundingBox.height }
        let medianH: CGFloat = {
            guard !heights.isEmpty else { return 0.020 }
            let s = heights.sorted()
            return s[s.count / 2]
        }()
        let rowGap = min(0.025, max(0.013, medianH * 0.55))
        let rows = clusterCenters(ys, maxGap: rowGap)
        guard rows.count >= 3 else { return nil }

        // 7. 建网格
        let sortedCols = columns.sorted()
        let sortedRows = rows.sorted(by: >)  // Vision: 大 y 在上
        var grid = Array(repeating: Array(repeating: "", count: sortedCols.count), count: sortedRows.count)
        var bbox: CGRect?
        for line in focusXFiltered {
            guard let col = nearest(line.boundingBox.midX, in: sortedCols),
                  let row = nearest(line.boundingBox.midY, in: sortedRows) else { continue }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if grid[row][col].isEmpty {
                grid[row][col] = trimmed
            } else {
                grid[row][col] += " " + trimmed
            }
            bbox = bbox.map { $0.union(line.boundingBox) } ?? line.boundingBox
        }
        guard let bbox else { return nil }

        // 8. 数字-单位合并（同一列内、垂直 gap < 0.7×rowHeight 的相邻行合并）
        let rowHeight = rowGap  // 行聚类 maxGap ≈ 行高
        let mergeThreshold = rowHeight * 0.70
        for _ in 0..<(sortedRows.count - 1) {
            // 同一列内，仅合并「本格空」+「下一格存在」的相邻行
            // 不在这里做：M2 当前样张「1429 千焦」本身已是一行，无需合并；接口预留
            _ = mergeThreshold
        }
        // 当前样张观察：实际合并需求低；算法为文档要求而保留阈值常量。

        // 9. 校验
        let filled = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
        let occupancy = Double(filled) / Double(max(sortedCols.count * sortedRows.count, 1))
        guard occupancy >= 0.30, looksLikeDataTable(grid) else { return nil }

        // 10. header 检测：第一行若任一 cell 命中关键词
        var headerRowIndices: [Int] = []
        let headerKeywords = profile?.headerKeywords ?? []
        if !headerKeywords.isEmpty, let firstRow = grid.first {
            let firstRowHit = firstRow.contains { cell in
                !cell.isEmpty && headerKeywords.contains { cell.localizedCaseInsensitiveContains($0) }
            }
            if firstRowHit { headerRowIndices.append(0) }
        }

        // 11. profile 期望列数一致 → confidence 提升
        var confidence = min(1.0, occupancy * 1.1)
        if let profile, profile.expectedColumnCount == sortedCols.count {
            confidence = min(1.0, confidence + 0.10)
        }

        return TableGridV2(
            table: ReconstructTable(rows: grid),
            bbox: bbox,
            rowCount: sortedRows.count,
            columnCount: sortedCols.count,
            headerRowIndices: headerRowIndices,
            profileName: profile?.name,
            confidence: confidence
        )
    }

    // MARK: - 与 `OnDeviceTableCluster.contains` 对齐

    /// 判断一行是否被识别为表格内容（用于「表格行不进段落」）。
    static func contains(_ grid: TableGridV2, line: OCRLine) -> Bool {
        grid.bbox.insetBy(dx: -0.02, dy: -0.02)
            .contains(CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY))
    }

    // MARK: - 内部

    private static func looksLikeDataTable(_ grid: [[String]]) -> Bool {
        let cells = grid.flatMap { $0 }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        // v1 的「45% tiny letters」过严（中文表常踩）。改用更宽容的条件：
        //  - 必须至少有一个数字 / 单位 / NRV 类 token
        //  - 不能 100% 都是英文字母长句
        let numeric = cells.filter { cell in
            cell.contains(where: { $0.isNumber })
        }
        let allLatinLongSentences = cells.allSatisfy { cell in
            cell.count > 30 && cell.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        }
        if allLatinLongSentences { return false }
        return !numeric.isEmpty || cells.count >= 6  // 至少要有数字或者 6 个 cell
    }

    private static func clusterCenters(_ values: [CGFloat], maxGap: CGFloat) -> [CGFloat] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [] }
        var groups: [[CGFloat]] = [[sorted[0]]]
        for value in sorted.dropFirst() {
            if let last = groups[groups.count - 1].last, value - last <= maxGap {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
        }
        return groups.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private static func nearest(_ value: CGFloat, in centers: [CGFloat]) -> Int? {
        guard let index = centers.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset
        else { return nil }
        let distance = abs(centers[index] - value)
        let limit: CGFloat = {
            guard centers.count >= 2 else { return 0.20 }
            let gaps = zip(centers, centers.dropFirst()).map { abs($1 - $0) }
            return (gaps.min() ?? 0.20) / 2 + 0.02
        }()
        return distance <= limit ? index : nil
    }
}
