import CoreGraphics
import Testing
@testable import Zhixia

/// 真机 iPhone 13 的表格过分割回归（2026-10-24）。
///
/// 同一张 `IMG_7544.jpg`，模拟器给出 2 列 5 行，真机 `RecognizeDocumentsRequest`
/// 却给出 3 列 4 行：右列被从中间劈开、第 3/4 行被并成一行。夹具用真机原始
/// cell frame + OCR 行重建，不依赖页面图片，CI 可跑。
struct TableStructureRepairTests {
    private typealias RawCell = VisionDocumentStructureRecognizer.RawCell
    private typealias Repair = TableStructureRepair

    private static let tableBBox = CGRect(x: 0.054945, y: 0.125, width: 0.417582, height: 0.241667)

    private static let columnFrames: [(CGFloat, CGFloat)] = [
        (0.054945, 0.267912),
        (0.267912, 0.368132),
        (0.368132, 0.472527)
    ]

    private static let rowFrames: [(CGFloat, CGFloat)] = [
        (0.313500, 0.366667),
        (0.262750, 0.313500),
        (0.214417, 0.262750),
        (0.125000, 0.214417)
    ]

    private static func cell(_ text: String, row: Int, column: Int) -> RawCell {
        let x = columnFrames[column].0
        let y = rowFrames[row].0
        return RawCell(
            text: text,
            rowRange: row...row,
            columnRange: column...column,
            frame: CGRect(
                x: x,
                y: y,
                width: columnFrames[column].1 - x,
                height: rowFrames[row].1 - y
            )
        )
    }

    private static func rawRows() -> [[RawCell]] {
        [
            [
                cell("What's fun to do with your friends after school?", row: 0, column: 0),
                cell("How important is it to do something different from studying after school?", row: 0, column: 1),
                cell("", row: 0, column: 2)
            ],
            [
                cell("1 You can go to the park and do some football training.", row: 1, column: 0),
                cell("a lot to pass your exams.", row: 1, column: 1),
                cell("5 It's important to study", row: 1, column: 2)
            ],
            [
                cell("2 I have to do my homework, which is boring.", row: 2, column: 0),
                cell("6\nstudying all day.", row: 2, column: 1),
                cell("It's good for you to do something active after", row: 2, column: 2)
            ],
            [
                cell("3 You can learn to play a musical instrument and start a band.\n4 1 go swimming every\nTuesday with my dad.", row: 3, column: 0),
                cell("7\nrelax.\n8 I enjoy doing fun", row: 3, column: 1),
                cell("It's important to spend time with your friends outside of school to\nactivities after school.", row: 3, column: 2)
            ]
        ]
    }

    private static func line(_ text: String, _ box: CGRect) -> OCRLine {
        OCRLine(text: text, boundingBox: box)
    }

    private static func tableLines() -> [OCRLine] {
        [
            line("What's fun to do with your", CGRect(x: 0.055096, y: 0.350000, width: 0.181818, height: 0.012500)),
            line("How important is it to do", CGRect(x: 0.272727, y: 0.350000, width: 0.170799, height: 0.012500)),
            line("something different from", CGRect(x: 0.272727, y: 0.335417, width: 0.170799, height: 0.012500)),
            line("friends after school?", CGRect(x: 0.055096, y: 0.335417, width: 0.143251, height: 0.012500)),
            line("studying after school?", CGRect(x: 0.272502, y: 0.317817, width: 0.152039, height: 0.015771)),
            line("5 It's important to study", CGRect(x: 0.272727, y: 0.293750, width: 0.192837, height: 0.014583)),
            line("1 You can go to the park", CGRect(x: 0.055096, y: 0.293750, width: 0.195592, height: 0.014583)),
            line("and do some football", CGRect(x: 0.079890, y: 0.281250, width: 0.168044, height: 0.012500)),
            line("a lot to pass your", CGRect(x: 0.297521, y: 0.279167, width: 0.129477, height: 0.012500)),
            line("exams.", CGRect(x: 0.297521, y: 0.266667, width: 0.055096, height: 0.010417)),
            line("training.", CGRect(x: 0.082645, y: 0.264583, width: 0.063361, height: 0.012500)),
            line("6", CGRect(x: 0.272727, y: 0.247917, width: 0.016529, height: 0.012500)),
            line("It's good for you to do", CGRect(x: 0.294766, y: 0.245833, width: 0.168044, height: 0.014583)),
            line("2 I have to do my", CGRect(x: 0.055096, y: 0.245833, width: 0.143251, height: 0.014583)),
            line("homework, which is", CGRect(x: 0.082645, y: 0.231250, width: 0.151515, height: 0.014583)),
            line("something active after", CGRect(x: 0.297521, y: 0.229167, width: 0.170799, height: 0.016667)),
            line("boring.", CGRect(x: 0.082645, y: 0.216667, width: 0.055096, height: 0.012500)),
            line("studying all day.", CGRect(x: 0.297521, y: 0.214583, width: 0.121212, height: 0.014583)),
            line("7", CGRect(x: 0.272727, y: 0.200000, width: 0.013774, height: 0.012500)),
            line("3 You can learn to play", CGRect(x: 0.057851, y: 0.197917, width: 0.184573, height: 0.014583)),
            line("It's important to spend", CGRect(x: 0.294766, y: 0.197917, width: 0.176309, height: 0.014583)),
            line("a musical instrument", CGRect(x: 0.082406, y: 0.183183, width: 0.162973, height: 0.014392)),
            line("time with your friends", CGRect(x: 0.297183, y: 0.179915, width: 0.168637, height: 0.018158)),
            line("outside of school to", CGRect(x: 0.297521, y: 0.170833, width: 0.151515, height: 0.010417)),
            line("and start a band.", CGRect(x: 0.082645, y: 0.168750, width: 0.132231, height: 0.012500)),
            line("relax.", CGRect(x: 0.297521, y: 0.154167, width: 0.044077, height: 0.012500)),
            line("4 1 go swimming every", CGRect(x: 0.057338, y: 0.146324, width: 0.180033, height: 0.018535)),
            line("8 I enjoy doing fun", CGRect(x: 0.272727, y: 0.135417, width: 0.151515, height: 0.012500)),
            line("Tuesday with my dad.", CGRect(x: 0.082645, y: 0.133333, width: 0.159780, height: 0.014583)),
            line("activities after school.", CGRect(x: 0.297521, y: 0.120833, width: 0.168044, height: 0.012500))
        ]
    }

    @Test("3 列 4 行 → 2 列 5 行，右列文本按 x/y 还原")
    func repairsOverSegmentedTable() throws {
        let result = try #require(
            Repair.repair(
                rawRows: Self.rawRows(),
                tableBBox: Self.tableBBox,
                lines: Self.tableLines()
            )
        )
        #expect(result.rows.count == 5)
        #expect(result.rows.allSatisfy { $0.count == 2 })
        #expect(result.columnRatios?.count == 2)
        #expect(abs((result.columnRatios?[0] ?? 0) - 0.51) < 0.01)
        #expect(result.rows[0][1].contains("How important"))
        #expect(result.rows[0][1].contains("studying after school?"))
        #expect(result.rows[1][1].hasPrefix("5 It's important"))
        #expect(result.rows[1][1].contains("pass your"))
        #expect(result.rows[2][1].contains("6 It's good"))
        #expect(result.rows[3][1].hasPrefix("7 It's important"))
        #expect(result.rows[4][1].hasPrefix("8 I enjoy"))
        #expect(result.rows[4][1].contains("activities after school."))
        #expect(result.rows[3][0].contains("3 You can"))
        #expect(result.rows[4][0].contains("4 1 go swimming"))
    }

    @Test("真实三列表格（列框有间隙、正文不跨边界）不合并")
    func leavesGenuineThreeColumnTableAlone() {
        let rows = (0..<3).map { row in
            (0..<3).map { column in
                RawCell(
                    text: "r\(row)c\(column)",
                    rowRange: row...row,
                    columnRange: column...column,
                    frame: CGRect(
                        x: 0.10 + CGFloat(column) * 0.20,
                        y: 0.10 + CGFloat(row) * 0.10,
                        width: 0.12,
                        height: 0.06
                    )
                )
            }
        }
        let lines = rows.flatMap { row in
            row.map { cell in
                OCRLine(text: cell.text, boundingBox: cell.frame!)
            }
        }
        #expect(
            Repair.repair(
                rawRows: rows,
                tableBBox: CGRect(x: 0.08, y: 0.08, width: 0.62, height: 0.36),
                lines: lines
            ) == nil
        )
    }

    @Test("普通两列表格不改")
    func leavesTwoColumnTableAlone() {
        let rows = (0..<2).map { row in
            (0..<2).map { column in
                RawCell(
                    text: "r\(row)c\(column)",
                    rowRange: row...row,
                    columnRange: column...column,
                    frame: CGRect(
                        x: 0.10 + CGFloat(column) * 0.30,
                        y: 0.10 + CGFloat(row) * 0.12,
                        width: 0.20,
                        height: 0.08
                    )
                )
            }
        }
        let lines = rows.flatMap { row in
            row.map { OCRLine(text: $0.text, boundingBox: $0.frame!) }
        }
        #expect(
            Repair.repair(
                rawRows: rows,
                tableBBox: CGRect(x: 0.08, y: 0.08, width: 0.62, height: 0.36),
                lines: lines
            ) == nil
        )
    }
}
