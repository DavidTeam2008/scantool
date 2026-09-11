import CoreGraphics
import Foundation

enum OnDeviceFigureRegions {
    static func boxes(
        textBoxes: [CGRect],
        occupied: [CGRect] = [],
        columns: Int = 36,
        rows: Int = 48
    ) -> [CGRect] {
        var grid = Array(repeating: Array(repeating: false, count: columns), count: rows)
        for col in 0..<columns {
            grid[0][col] = true
            grid[rows - 1][col] = true
        }
        for row in 0..<rows {
            grid[row][0] = true
            grid[row][columns - 1] = true
        }
        for box in textBoxes + occupied {
            fill(&grid, box: box.insetBy(dx: -0.018, dy: -0.018), columns: columns, rows: rows)
        }
        var visited = Array(repeating: Array(repeating: false, count: columns), count: rows)
        var found: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<columns where !grid[row][col] && !visited[row][col] {
                let component = flood(row: row, col: col, occupied: grid, visited: &visited)
                if let (box, fill) = normalized(component, columns: columns, rows: rows), isUseful(box, fill: fill) {
                    found.append(box)
                }
            }
        }
        return found.sorted { $0.maxY > $1.maxY }
    }

    private static func fill(
        _ grid: inout [[Bool]],
        box: CGRect,
        columns: Int,
        rows: Int
    ) {
        let left = max(0, Int(box.minX * CGFloat(columns)))
        let right = min(columns - 1, Int(ceil(box.maxX * CGFloat(columns))) - 1)
        let top = max(0, Int((1 - box.maxY) * CGFloat(rows)))
        let bottom = min(rows - 1, Int(ceil((1 - box.minY) * CGFloat(rows))) - 1)
        guard left <= right, top <= bottom else { return }
        for row in top...bottom {
            for col in left...right {
                grid[row][col] = true
            }
        }
    }

    private static func flood(
        row: Int,
        col: Int,
        occupied: [[Bool]],
        visited: inout [[Bool]]
    ) -> [(Int, Int)] {
        let rows = occupied.count
        let columns = occupied[0].count
        var stack = [(row, col)]
        var cells: [(Int, Int)] = []
        visited[row][col] = true
        while let (r, c) = stack.popLast() {
            cells.append((r, c))
            let neighbors = [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
            for (nr, nc) in neighbors {
                guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                guard !occupied[nr][nc], !visited[nr][nc] else { continue }
                visited[nr][nc] = true
                stack.append((nr, nc))
            }
        }
        return cells
    }

    private static func normalized(_ cells: [(Int, Int)], columns: Int, rows: Int) -> (CGRect, CGFloat)? {
        guard let minR = cells.map(\.0).min(),
              let maxR = cells.map(\.0).max(),
              let minC = cells.map(\.1).min(),
              let maxC = cells.map(\.1).max()
        else {
            return nil
        }
        let boxCells = (maxR - minR + 1) * (maxC - minC + 1)
        let fill = CGFloat(cells.count) / CGFloat(max(boxCells, 1))
        let x = CGFloat(minC) / CGFloat(columns)
        let width = CGFloat(maxC - minC + 1) / CGFloat(columns)
        let top = CGFloat(minR) / CGFloat(rows)
        let height = CGFloat(maxR - minR + 1) / CGFloat(rows)
        return (CGRect(x: x, y: 1 - top - height, width: width, height: height), fill)
    }

    private static func isUseful(_ box: CGRect, fill: CGFloat) -> Bool {
        let area = box.width * box.height
        guard area >= 0.012, area <= 0.42 else { return false }
        guard fill >= 0.55 else { return false }
        let aspect = box.width / max(box.height, 0.001)
        guard aspect > 0.2, aspect < 5 else { return false }
        if box.minX < 0.03, box.width < 0.12 { return false }
        if box.maxX > 0.97, box.width < 0.12 { return false }
        return true
    }
}
