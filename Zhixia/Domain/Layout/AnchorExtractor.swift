import CoreGraphics
import Foundation

/// 语义锚点 + 逐行语义标签。两种粒度：
/// - anchors：带 frame 的关键点（M2/M3 用作「在锚点附近找」的几何种子）；
/// - lineSemantics：与输入 lines 一一对应的标签。
enum AnchorExtractor {
    static func extract(
        lines: [OCRLine],
        barcodes: [CGRect] = []
    ) -> (anchors: [LayoutAnchor], semantics: [ReconstructSemanticTag?], tableTitleLineIndices: Set<Int>) {
        let n = lines.count
        var anchors: [LayoutAnchor] = []
        var semantics = Array(repeating: ReconstructSemanticTag?.none, count: n)
        var tableTitleLineIndices: Set<Int> = []

        // 1. 表标题：营养成分表 / Nutrition Facts / NRV 等关键词
        for (i, l) in lines.enumerated() {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            for pat in tableTitlePatterns {
                if t.localizedCaseInsensitiveContains(pat) {
                    anchors.append(LayoutAnchor(
                        kind: .tableTitle,
                        frame: l.boundingBox,
                        text: t,
                        confidence: 0.95
                    ))
                    semantics[i] = .tableTitle
                    tableTitleLineIndices.insert(i)
                    break
                }
            }
        }

        // 2. 题号 / Section 标题
        for (i, l) in lines.enumerated() {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let anchorKind = matchQuestionOrSection(text: t) {
                anchors.append(LayoutAnchor(
                    kind: anchorKind,
                    frame: l.boundingBox,
                    text: t,
                    confidence: 0.85
                ))
                if semantics[i] == nil {
                    semantics[i] = .questionStem
                }
            }
        }

        // 3. 选项字母：单大写 A-Z，且同一 y 带（±0.025）上 ≥ 2 个
        let letterIndices = lines.indices.filter {
            let t = lines[$0].text.trimmingCharacters(in: .whitespaces)
            return singleUppercaseLetter(t)
        }
        if letterIndices.count >= 2 {
            let sorted = letterIndices.sorted { lines[$0].boundingBox.midY > lines[$1].boundingBox.midY }
            var k = 0
            while k < sorted.count {
                var j = k
                let yi = lines[sorted[k]].boundingBox.midY
                while j < sorted.count, abs(lines[sorted[j]].boundingBox.midY - yi) < 0.025 {
                    j += 1
                }
                if j - k >= 2 {
                    for idx in sorted[k..<j] {
                        anchors.append(LayoutAnchor(
                            kind: .optionLetter,
                            frame: lines[idx].boundingBox,
                            text: lines[idx].text,
                            confidence: 0.9
                        ))
                        semantics[idx] = .optionLetter
                    }
                }
                k = j
            }
        }

        // 4. OCR 文本里的条码候选：长数字串
        let barcodeTextRe = try! NSRegularExpression(pattern: #"^\d[\d\s]+\d$"#, options: [])
        for (i, l) in lines.enumerated() {
            let t = l.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let nsRange = NSRange(t.startIndex..., in: t)
            guard barcodeTextRe.firstMatch(in: t, range: nsRange) != nil,
                  t.filter({ $0.isNumber }).count >= 10
            else { continue }
            anchors.append(LayoutAnchor(
                kind: .barcode,
                frame: l.boundingBox,
                text: t,
                confidence: 0.7
            ))
            if semantics[i] == nil { semantics[i] = .barcode }
        }

        // 5. Vision 条码 box
        for b in barcodes {
            anchors.append(LayoutAnchor(kind: .barcode, frame: b, text: nil, confidence: 0.95))
        }

        return (anchors, semantics, tableTitleLineIndices)
    }

    // MARK: - 内部

    private static let tableTitlePatterns = [
        "营养成分表",
        "营养配料表",
        "Nutrition Facts",
        "Nutrition Information",
        "Supplement Facts"
    ]

    private static let questionRe = try! NSRegularExpression(
        pattern: #"^\s*Question\s*\d+"#,
        options: .caseInsensitive
    )
    private static let sectionRe = try! NSRegularExpression(
        pattern: #"^\s*Section\s*\d+"#,
        options: .caseInsensitive
    )

    private static func matchQuestionOrSection(text: String) -> LayoutAnchorKind? {
        let range = NSRange(text.startIndex..., in: text)
        if questionRe.firstMatch(in: text, range: range) != nil { return .questionStem }
        if sectionRe.firstMatch(in: text, range: range) != nil { return .questionStem }
        return nil
    }

    private static let singleLetterRe = try! NSRegularExpression(pattern: #"^[A-Z]$"#, options: [])

    private static func singleUppercaseLetter(_ text: String) -> Bool {
        guard text.count == 1 else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return singleLetterRe.firstMatch(in: text, range: range) != nil
    }
}
