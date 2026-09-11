import CoreGraphics
import Foundation

struct DetectedTable: Equatable, Sendable {
    var table: ReconstructTable
    var bbox: CGRect
}

enum OnDeviceTableCluster {
    static func detect(from lines: [OCRLine]) -> DetectedTable? {
        let cells = lines.filter(isCell)
        guard cells.count >= 6 else { return nil }

        let focused = focus(cells, in: lines)
        let source = focused.count >= 6 ? focused : cells
        let columns = clusterCenters(source.map { $0.boundingBox.midX }, maxGap: 0.11)
        let rows = clusterCenters(source.map { $0.boundingBox.midY }, maxGap: 0.032)
        guard (2...5).contains(columns.count), rows.count >= 3 else { return nil }

        let sortedCols = columns.sorted()
        let sortedRows = rows.sorted(by: >)
        var grid = Array(
            repeating: Array(repeating: "", count: sortedCols.count),
            count: sortedRows.count
        )
        var bbox: CGRect?
        for line in source {
            let col = nearest(line.boundingBox.midX, in: sortedCols)
            let row = nearest(line.boundingBox.midY, in: sortedRows)
            guard let col, let row else { continue }
            if grid[row][col].isEmpty {
                grid[row][col] = line.text.trimmingCharacters(in: .whitespaces)
            } else {
                grid[row][col] += " " + line.text.trimmingCharacters(in: .whitespaces)
            }
            bbox = bbox.map { $0.union(line.boundingBox) } ?? line.boundingBox
        }

        let filled = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
        let occupancy = Double(filled) / Double(max(sortedCols.count * sortedRows.count, 1))
        guard occupancy >= 0.45, let bbox, looksLikeDataTable(grid) else { return nil }
        return DetectedTable(table: ReconstructTable(rows: grid), bbox: bbox)
    }

    static func contains(_ table: DetectedTable, line: OCRLine) -> Bool {
        table.bbox.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY))
    }

    private static func isCell(_ line: OCRLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 28 else { return false }
        return line.boundingBox.width < 0.35 && line.boundingBox.height < 0.08
    }

    private static func focus(_ cells: [OCRLine], in all: [OCRLine]) -> [OCRLine] {
        guard let anchor = all.first(where: {
            $0.text.contains("营养成分表") || $0.text.localizedCaseInsensitiveContains("NRV")
        }) else {
            return cells
        }
        let below = cells.filter { $0.boundingBox.midY < anchor.boundingBox.midY + 0.02 }
        return below.count >= 6 ? below : cells
    }

    private static func looksLikeDataTable(_ grid: [[String]]) -> Bool {
        let cells = grid.flatMap { $0 }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        let tinyLetters = cells.filter { cell in
            cell.count <= 2 && cell.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        }
        if Double(tinyLetters.count) / Double(cells.count) > 0.45 {
            return false
        }
        return true
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
        else {
            return nil
        }
        let distance = abs(centers[index] - value)
        let limit = centers.count <= 1 ? 0.2 : (centers.adjacentGap / 2 + 0.02)
        return distance <= limit ? index : nil
    }
}

private extension Array where Element == CGFloat {
    var adjacentGap: CGFloat {
        guard count >= 2 else { return 0.2 }
        return zip(self, dropFirst()).map { abs($1 - $0) }.min() ?? 0.2
    }
}
