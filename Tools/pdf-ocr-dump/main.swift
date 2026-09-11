import Foundation
import PDFKit

// 从 SearchablePDF 的文字层反解真机 OCR 的 (text, bbox)。
// PDFPage.characterBounds(at:) 能拿到每个字符的矩形，按 y 聚成行即得原始 OCR 行。

let path = CommandLine.arguments[1]
let needWidth = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 595) : 595
let needHeight = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3]) ?? 842) : 842

guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
    print("cannot open"); exit(1)
}

print("pages: \(doc.pageCount)")
for pi in 0..<doc.pageCount {
    guard let page = doc.page(at: pi) else { continue }
    let bounds = page.bounds(for: .mediaBox)
    print("== page \(pi) size=\(bounds.width)x\(bounds.height)")
    guard let s = page.string, !s.isEmpty else { continue }

    // 逐字符收集 bounds
    let chars = Array(s)
    var items: [(ch: Character, r: CGRect)] = []
    for i in 0..<chars.count {
        var r = page.characterBounds(at: i)
        if r.isNull || r.isEmpty { continue }
        // 归一化到 0..1（Vision 坐标系：原点左下，y 向上）
        let nx = r.minX / bounds.width
        let ny = 1 - (r.maxY / bounds.height)
        let nw = r.width / bounds.width
        let nh = r.height / bounds.height
        items.append((chars[i], CGRect(x: nx, y: ny, width: nw, height: nh)))
    }

    // 按 y 聚类成行。
    // 注意：不能用「与上一个字符比」的链式聚类 —— 逐字符漂移会累积，
    // 把好几行粘成一行（第一次跑就踩了这个坑，解出来是乱码）。
    // 改成与「本行首字符」比，硬切。
    struct Row {
        var anchorY: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
        var runs: [(String, CGRect)]
    }
    var rows: [Row] = []
    let rowTol: CGFloat = 0.005
    for it in items.sorted(by: { $0.r.midY > $1.r.midY }) {
        if var last = rows.last, abs(it.r.midY - last.anchorY) < rowTol {
            last.runs.append((String(it.ch), it.r))
            last.minY = min(last.minY, it.r.minY)
            last.maxY = max(last.maxY, it.r.maxY)
            rows[rows.count - 1] = last
        } else {
            rows.append(Row(anchorY: it.r.midY, minY: it.r.minY, maxY: it.r.maxY, runs: [(String(it.ch), it.r)]))
        }
    }

    for (ri, row) in rows.enumerated() {
        let sorted = row.runs.sorted { $0.1.minX < $1.1.minX }
        // 字符间隔 > 0.012 视为分块（表格列的自然间隙）
        var chunks: [(String, CGFloat, CGFloat)] = []
        for (ch, r) in sorted {
            if var last = chunks.last, r.minX - last.2 < 0.012 {
                last.0 += ch
                last.2 = r.maxX
                chunks[chunks.count - 1] = last
            } else {
                chunks.append((String(ch), r.minX, r.maxX))
            }
        }
        let text = sorted.map { $0.0 }.joined()
        let x0 = sorted.first?.1.minX ?? 0
        let x1 = sorted.map { $0.1.maxX }.max() ?? 0
        print("  [\(ri)] y=\(String(format: "%.4f", row.minY)) h=\(String(format: "%.4f", row.maxY - row.minY)) x=\(String(format: "%.4f", x0)) w=\(String(format: "%.4f", x1 - x0)) | \(text)")
        if chunks.count > 1 {
            let desc = chunks.map { "'\($0.0)'@\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
            print("        chunks(\(chunks.count)): \(desc)")
        }
    }
}
