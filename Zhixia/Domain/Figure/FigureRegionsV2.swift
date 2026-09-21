import CoreGraphics
import Foundation

/// M3 配图检测（docs/07 §6.4）。纯几何 + 文本 anchor，**不读图像像素**。
///
/// ## 真机回归教训（2026-09-07）
/// v1 版直接把「题目 → 下一题」的整块 gap 当 figure 交出去，结果裁出
/// 844×393 / 768×1005 这种几乎整页的大图，图里**全是文字** —— 用户看到的是
/// 「一堆文字的截图」，比原来的 0 个 figure 还糟。
/// 根因：gap 区域里本来就是对话正文，不是图；为了凑 `boxes.count >= 3` 而放弃质量。
///
/// 修正后的做法：
/// 1. **题下 anchor 通道**（练习册）：只在「题目 → 下一题」的 gap **内部**做网格
///    flood fill，用该区域里的文字盒做掩码，**只取真正的空白连通域**。
///    找不到合格空白 → 这个 anchor 不产出 figure（宁缺毋滥）。
/// 2. **v1 兜底**：整页 flood fill，ad-hoc 空洞。
/// 3. 全部经「面积 / 长宽比 / fill 率」三重过滤 + IoU dedup。
///
/// ## US3（spec/layout-restore plan D5 / FR-007）：条码通道已移除
/// 早期还有一条「barcode 通道」把 occupied 里像条码的框 / layout 条码锚点外扩成
/// figure 输出 —— 那会让同一条码在产物里同时出现 figure、`.barcode` 块、URL 降级
/// 块三份表示。现在条码由 `.barcode` 块**单份表示**（裁图 + payload），
/// `occupied` 里的条码框仅作为墙（不产 figure、也不被图侵占）。
///
/// ## 关键阈值（真机调出来的，别乱动）
/// - `maxArea = 0.12`：题下整块 gap 约 0.9×0.3 = 0.27，必须卡掉，否则又变满屏文字。
/// - `minArea = 0.006`：再小就是行间空隙，不是图。
/// - `textInset = 0.008`：比 v1 的 0.018 小一半，避免膨胀吃掉图旁边的题注。
/// - `minFill = 0.5`：连通域要够"实"，排除锯齿状碎片。
enum FigureRegionsV2 {

    struct Input {
        var textBoxes: [CGRect]
        var layout: PageLayout
        var occupied: [CGRect]
    }

    // MARK: - 阈值

    private static let gridColumns = 96
    private static let gridRows = 128
    /// 文字盒膨胀量。v1 用 0.018 太肥，会把图旁边的题注连成一片。
    private static let textInset: CGFloat = 0.008
    private static let minArea: CGFloat = 0.006
    private static let maxArea: CGFloat = 0.12
    private static let minFill: CGFloat = 0.5
    private static let minAspect: CGFloat = 0.20
    private static let maxAspect: CGFloat = 5.0
    /// 题下区域至少要有这么高才值得找图。
    private static let minQuestionGap: CGFloat = 0.06
    /// 单题最多取这么多个 figure（按面积降序）。
    private static let maxFiguresPerQuestion = 1

    static func boxes(_ input: Input) -> [CGRect] {
        var figs: [CGRect] = []
        figs.append(contentsOf: questionAnchorFigures(input))
        figs.append(
            contentsOf: OnDeviceFigureRegions.boxes(
                textBoxes: input.textBoxes,
                occupied: input.occupied
            )
        )
        return dedup(figs.filter { isPlausible($0) })
            .sorted { $0.maxY > $1.maxY }
    }

    // MARK: - 题下 anchor 通道（练习册）

    private static func questionAnchorFigures(_ input: Input) -> [CGRect] {
        let qs = input.layout.anchors
            .filter { $0.kind == .questionStem }
            .sorted { $0.frame.minY > $1.frame.minY }   // 大 y 在上
        guard !qs.isEmpty else { return [] }

        var out: [CGRect] = []
        for (i, q) in qs.enumerated() {
            let top = q.frame.maxY                       // 当前题视觉底
            let bottom: CGFloat = i + 1 < qs.count
                ? qs[i + 1].frame.minY                    // 下一题视觉顶
                : 0.0
            let gap = top - bottom
            guard gap >= minQuestionGap else { continue }

            let centerX = q.frame.midX
            let halfW = min(0.45, max(0.20, q.frame.width / 2 + 0.15))
            let xLo = max(0.0, centerX - halfW)
            let region = CGRect(
                x: xLo,
                y: bottom,
                width: min(1.0 - xLo, halfW * 2),
                height: gap
            )
            // 关键改动：不直接交出 region，而是在 region 内找真正的空白。
            let holes = emptyHoles(in: region, avoiding: input.textBoxes + input.occupied)
            out.append(contentsOf: holes.prefix(maxFiguresPerQuestion))
        }
        return out
    }

    // MARK: - 网格 flood fill（区域限定版）

    /// 在 `region` 内做网格 flood fill，把 `avoiding` 覆盖的格子当墙，
    /// 返回所有「合格空白连通域」的外接框，按面积降序。
    private static func emptyHoles(
        in region: CGRect,
        avoiding: [CGRect]
    ) -> [CGRect] {
        guard region.width > 0.01, region.height > 0.01 else { return [] }
        var grid = Array(
            repeating: Array(repeating: false, count: gridColumns),
            count: gridRows
        )
        // 先把 region 外的格子设成墙（等价于把搜索裁剪到 region 内）
        for r in 0..<gridRows {
            for c in 0..<gridColumns {
                let x = (CGFloat(c) + 0.5) / CGFloat(gridColumns)
                let y = 1.0 - (CGFloat(r) + 0.5) / CGFloat(gridRows)
                if !region.contains(CGPoint(x: x, y: y)) {
                    grid[r][c] = true
                }
            }
        }
        // 再把文字盒覆盖的格子设成墙
        for box in avoiding {
            let box = box.insetBy(dx: -textInset, dy: -textInset)
            let left = max(0, Int(box.minX * CGFloat(gridColumns)))
            let right = min(gridColumns - 1, Int(ceil(box.maxX * CGFloat(gridColumns))) - 1)
            let top = max(0, Int((1 - box.maxY) * CGFloat(gridRows)))
            let bottom = min(gridRows - 1, Int(ceil((1 - box.minY) * CGFloat(gridRows))) - 1)
            guard left <= right, top <= bottom else { continue }
            for r in top...bottom {
                for c in left...right {
                    grid[r][c] = true
                }
            }
        }

        var visited = Array(
            repeating: Array(repeating: false, count: gridColumns),
            count: gridRows
        )
        var found: [(box: CGRect, fill: CGFloat, area: CGFloat)] = []
        for r in 0..<gridRows {
            for c in 0..<gridColumns where !grid[r][c] && !visited[r][c] {
                let cells = flood(row: r, col: c, walls: grid, visited: &visited)
                guard let (box, fill) = normalized(cells) else { continue }
                guard isPlausible(box), fill >= minFill else { continue }
                found.append((box, fill, box.width * box.height))
            }
        }
        return found
            .sorted { $0.area > $1.area }
            .map(\.box)
    }

    private static func flood(
        row: Int,
        col: Int,
        walls: [[Bool]],
        visited: inout [[Bool]]
    ) -> [(Int, Int)] {
        let rows = walls.count
        let columns = walls[0].count
        var stack = [(row, col)]
        var cells: [(Int, Int)] = []
        visited[row][col] = true
        while let (r, c) = stack.popLast() {
            cells.append((r, c))
            for (nr, nc) in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)] {
                guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                guard !walls[nr][nc], !visited[nr][nc] else { continue }
                visited[nr][nc] = true
                stack.append((nr, nc))
            }
        }
        return cells
    }

    private static func normalized(_ cells: [(Int, Int)]) -> (CGRect, CGFloat)? {
        guard let minR = cells.map(\.0).min(),
              let maxR = cells.map(\.0).max(),
              let minC = cells.map(\.1).min(),
              let maxC = cells.map(\.1).max()
        else {
            return nil
        }
        let boxCells = (maxR - minR + 1) * (maxC - minC + 1)
        let fill = CGFloat(cells.count) / CGFloat(max(boxCells, 1))
        let x = CGFloat(minC) / CGFloat(gridColumns)
        let width = CGFloat(maxC - minC + 1) / CGFloat(gridColumns)
        let top = CGFloat(minR) / CGFloat(gridRows)
        let height = CGFloat(maxR - minR + 1) / CGFloat(gridRows)
        return (CGRect(x: x, y: 1 - top - height, width: width, height: height), fill)
    }

    // MARK: - 过滤 / 去重

    /// 三重过滤：面积区间 + 长宽比。真机回归的关键闸门 —— 没有 `maxArea` 就会
    /// 把整块文字区当 figure 交出去，又变成"满屏文字的截图"。
    private static func isPlausible(_ box: CGRect) -> Bool {
        let area = box.width * box.height
        guard area >= minArea, area <= maxArea else { return false }
        let aspect = box.width / max(box.height, 0.001)
        guard aspect > minAspect, aspect < maxAspect else { return false }
        return true
    }

    private static func dedup(_ boxes: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for box in boxes {
            if result.contains(where: { iou($0, box) > 0.6 }) { continue }
            result.append(box)
        }
        return result
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let union = a.union(b)
        if union.isNull || union.isEmpty { return 0 }
        return (inter.width * inter.height) / (union.width * union.height)
    }
}
