import CoreGraphics
import Foundation

/// 修复 iOS 26 `RecognizeDocumentsRequest` 在真机上的表格**过分割**。
///
/// 背景（2026-10-24 iPhone 13 实测）：
/// 同一张 `IMG_7544.jpg`，模拟器把表格识别成 2 列 5 行，真机却给成
/// `3 列 × 4 行`：
///
/// - 右列被从中间劈成两列，列框首尾相接（没有真实分隔带）；
/// - 第 3、4 行被并成一行，单元格里出现 `3 ... 4 ...`。
///
/// 这不是本项目的行列聚类算法造成的，而是 Vision 的直接输出。修复不依赖
/// 页面坐标，只依赖两类**可泛化证据**：
///
/// 1. **列框之间没有间隙，且 OCR 文本行跨过列边界**：真实列边界不会让
///    一整行文字连续跨过去；跨过去说明边界落在文字内部。
/// 2. **高行内含多个编号项**：行高明显大于中位行高，且至少一列出现两个
///    行首编号，说明这是两条逻辑行被并成一条。
///
/// 修复后列数、行数和文本顺序都回到视觉真实值；没有命中证据的表格原样返回。
enum TableStructureRepair {
    typealias RawCell = VisionDocumentStructureRecognizer.RawCell

    struct Result: Equatable, Sendable {
        var rows: [[String]]
        var columnRatios: [Double]?
    }

    /// 相邻列框允许的最大间隙（归一化页宽）。真机过分割时是 0。
    private static let maxColumnGap: CGFloat = 0.004
    /// 一行文字跨过列边界时，两侧至少各延伸这么多，避免标点/抗锯齿误判。
    private static let minCrossOverhang: CGFloat = 0.005
    /// 表格行高超过中位行高的这个倍数，才考虑拆行。
    private static let tallRowFactor: CGFloat = 1.3

    static func repair(
        rawRows: [[RawCell]],
        tableBBox: CGRect,
        lines: [OCRLine]
    ) -> Result? {
        let cells = rawRows.flatMap { $0 }
        guard !cells.isEmpty else { return nil }

        let gridWidth = cells.map { $0.columnRange.upperBound + 1 }.max() ?? 0
        guard gridWidth >= 2 else { return nil }

        let columnFrames = columnFrameUnion(cells, gridWidth: gridWidth)
        guard let columnFrames else { return nil }
        let tableLines = lines.filter { line in
            let box = line.boundingBox
            return box.width > 0
                && box.height > 0
                && box.intersects(tableBBox.insetBy(dx: -0.004, dy: -0.004))
        }
        guard !tableLines.isEmpty else { return nil }

        let originalRatios = VisionDocumentStructureRecognizer.columnRatios(rawRows)
        let groups = columnGroups(
            rawRows: rawRows,
            columnFrames: columnFrames,
            tableBBox: tableBBox,
            tableLines: tableLines
        )
        guard groups.count < gridWidth else { return nil }

        let rebuiltCells = groups.map { group in
            groupCellLines(
                group: group,
                rawRows: rawRows,
                tableBBox: tableBBox,
                lines: tableLines
            )
        }
        guard rebuiltCells.contains(where: { !$0.isEmpty }) else { return nil }
        let rowCount = rebuiltCells.map(\.count).max() ?? 0
        guard rowCount > 0 else { return nil }
        let rowMajorCells: [[[String]]] = (0..<rowCount).map { rowIndex in
            groups.indices.map { groupIndex in
                let groupRows = rebuiltCells[groupIndex]
                return rowIndex < groupRows.count ? groupRows[rowIndex] : []
            }
        }

        let heights = rawRows.compactMap { row -> CGFloat? in
            let frames = row.compactMap(\.frame)
            guard !frames.isEmpty else { return nil }
            return frames.reduce(frames[0]) { $0.union($1) }.height
        }
        let medianHeight = median(heights)
        let rebuiltRows = assembleRows(
            cells: rowMajorCells,
            rawRows: rawRows,
            medianHeight: medianHeight
        )
        guard !rebuiltRows.isEmpty else { return nil }

        let ratios: [Double]?
        if let originalRatios, originalRatios.count == gridWidth {
            ratios = groups.map { group in
                group.indices.reduce(0) { $0 + originalRatios[$1] }
            }
        } else {
            let total = groups.reduce(CGFloat(0)) { $0 + $1.width }
            ratios = total > 0 ? groups.map { Double($0.width / total) } : nil
        }
        return Result(rows: rebuiltRows, columnRatios: ratios)
    }

    // MARK: - 列分组

    private struct ColumnGroup {
        var indices: [Int]
        var minX: CGFloat
        var maxX: CGFloat
        var width: CGFloat { maxX - minX }
    }

    private static func columnFrameUnion(
        _ cells: [RawCell],
        gridWidth: Int
    ) -> (lows: [CGFloat], highs: [CGFloat])? {
        var lows = [CGFloat](repeating: .greatestFiniteMagnitude, count: gridWidth)
        var highs = [CGFloat](repeating: -.greatestFiniteMagnitude, count: gridWidth)
        var seen = [Bool](repeating: false, count: gridWidth)
        for cell in cells where cell.columnRange.count == 1 {
            guard let frame = cell.frame, frame.width > 0 else { continue }
            let column = cell.columnRange.lowerBound
            guard column >= 0, column < gridWidth else { continue }
            lows[column] = min(lows[column], frame.minX)
            highs[column] = max(highs[column], frame.maxX)
            seen[column] = true
        }
        guard seen.allSatisfy({ $0 }) else { return nil }
        return (lows, highs)
    }

    private static func columnGroups(
        rawRows: [[RawCell]],
        columnFrames: (lows: [CGFloat], highs: [CGFloat]),
        tableBBox: CGRect,
        tableLines: [OCRLine]
    ) -> [ColumnGroup] {
        let count = columnFrames.lows.count
        var groups: [ColumnGroup] = []
        var current = [0]
        for column in 1..<count {
            let gap = columnFrames.lows[column] - columnFrames.highs[column - 1]
            let boundary = (columnFrames.highs[column - 1] + columnFrames.lows[column]) / 2
            if gap <= maxColumnGap,
               crossesColumnBoundary(
                   boundary: boundary,
                   tableBBox: tableBBox,
                   tableLines: tableLines
               ) {
                current.append(column)
            } else {
                groups.append(makeGroup(current, frames: columnFrames))
                current = [column]
            }
        }
        groups.append(makeGroup(current, frames: columnFrames))
        return groups
    }

    private static func makeGroup(
        _ indices: [Int],
        frames: (lows: [CGFloat], highs: [CGFloat])
    ) -> ColumnGroup {
        let lows = indices.map { frames.lows[$0] }
        let highs = indices.map { frames.highs[$0] }
        return ColumnGroup(
            indices: indices,
            minX: lows.min() ?? 0,
            maxX: highs.max() ?? 0
        )
    }

    /// 列边界是否被文字行「跨过去」。
    ///
    /// 不能只看跨过次数：表头合并单元格天然会跨列。因此要求跨栏行里
    /// 至少有一条位于表格下半部（正文区），且跨栏行占表内行数的比例够高。
    private static func crossesColumnBoundary(
        boundary: CGFloat,
        tableBBox: CGRect,
        tableLines: [OCRLine]
    ) -> Bool {
        let crossing = tableLines.filter { line in
            line.boundingBox.minX < boundary - minCrossOverhang
                && line.boundingBox.maxX > boundary + minCrossOverhang
        }
        guard !crossing.isEmpty else { return false }
        let bodyBandTop = tableBBox.maxY - tableBBox.height * 0.30
        let hasBodyCrossing = crossing.contains { $0.boundingBox.maxY < bodyBandTop }
        guard hasBodyCrossing else { return false }
        let required = max(2, Int(ceil(Double(tableLines.count) * 0.15)))
        return crossing.count >= required
    }

    // MARK: - 单元格文本

    /// 每列分组的**视觉行文本**。用 OCR 行而不是被劈开的 cell.text，
    /// 才能按 y/x 真实顺序还原右列里交错的两段。
    private static func groupCellLines(
        group: ColumnGroup,
        rawRows: [[RawCell]],
        tableBBox: CGRect,
        lines: [OCRLine]
    ) -> [[String]] {
        let xRange = group.minX...group.maxX
        let tableLines = lines.filter { line in
            let centerX = line.boundingBox.midX
            return centerX >= xRange.lowerBound - 0.004
                && centerX <= xRange.upperBound + 0.004
        }

        let rowFrames = rawRows.compactMap { row -> CGRect? in
            let frames = row.compactMap(\.frame)
            guard !frames.isEmpty else { return nil }
            return frames.reduce(frames[0]) { $0.union($1) }
        }

        var result: [[String]] = []
        for (index, frame) in rowFrames.enumerated() {
            let rowLines = tableLines.filter { line in
                let centerY = line.boundingBox.midY
                return centerY >= frame.minY - 0.003
                    && centerY <= frame.maxY + 0.003
            }
            let cellLines = visualLines(rowLines)
            if cellLines.isEmpty {
                // OCR 行缺失时退回原始 cell 文本，保证不因修复丢内容。
                result.append(rawCellText(rawRows[index], group: group))
            } else {
                result.append(cellLines)
            }
        }
        return result
    }

    private static func visualLines(_ lines: [OCRLine]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.boundingBox.height)
        let tolerance = max(0.003, min(0.008, median(heights) * 0.35))
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.0001 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var visualRows: [[OCRLine]] = []
        for line in sorted {
            if let last = visualRows.last,
               let anchor = last.first,
               abs(anchor.boundingBox.midY - line.boundingBox.midY) <= tolerance {
                visualRows[visualRows.count - 1].append(line)
            } else {
                visualRows.append([line])
            }
        }
        return visualRows.map { row in
            let parts = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return join(parts)
        }
    }

    private static func rawCellText(_ row: [RawCell], group: ColumnGroup) -> [String] {
        let texts = row
            .filter { cell in
                cell.columnRange.lowerBound >= group.indices.first!
                    && cell.columnRange.upperBound <= group.indices.last!
            }
            .sorted { $0.columnRange.lowerBound < $1.columnRange.lowerBound }
            .map(\.text)
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }
        return join(texts).components(separatedBy: "\n")
    }

    // MARK: - 行拆分

    /// 把「被合并的高行」按行首编号拆回逻辑行。
    private static func assembleRows(
        cells: [[[String]]],
        rawRows: [[RawCell]],
        medianHeight: CGFloat
    ) -> [[String]] {
        var result: [[String]] = []
        for (rowIndex, rowCells) in cells.enumerated() {
            let height: CGFloat = {
                let frames = rawRows[rowIndex].compactMap(\.frame)
                guard !frames.isEmpty else { return medianHeight }
                return frames.reduce(frames[0]) { $0.union($1) }.height
            }()
            let items = rowCells.map(splitItems)
            let maxItemCount = items.map(\.count).max() ?? 1
            let shouldSplit = height > medianHeight * tallRowFactor && maxItemCount >= 2
            guard shouldSplit else {
                result.append(rowCells.map { $0.joined(separator: "\n") })
                continue
            }
            for itemIndex in 0..<maxItemCount {
                let splitRow: [String] = items.map { columnItems -> String in
                    if columnItems.count == maxItemCount {
                        return columnItems[itemIndex].joined(separator: "\n")
                    }
                    if itemIndex == 0 {
                        return columnItems.flatMap { $0 }.joined(separator: "\n")
                    }
                    return ""
                }
                result.append(splitRow)
            }
        }
        return result
    }

    /// 按行首编号切分单元格。编号必须是「1~2 位数字 + 空白 + 非空文本」。
    private static func splitItems(_ lines: [String]) -> [[String]] {
        guard !lines.isEmpty else { return [] }
        var starts = [0]
        for (index, line) in lines.enumerated() where index > 0 {
            if isItemStart(line) {
                starts.append(index)
            }
        }
        guard starts.count > 1 else { return [lines] }
        var items: [[String]] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : lines.count
            items.append(Array(lines[start..<end]))
        }
        return items
    }

    private static func isItemStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(
            of: #"^\d{1,2}[\.\)]?\s+\S"#,
            options: .regularExpression
        ) else { return false }
        return trimmed.distance(from: trimmed.startIndex, to: match.lowerBound) == 0
    }

    // MARK: - 工具

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
