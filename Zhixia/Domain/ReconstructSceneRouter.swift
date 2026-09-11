import Foundation

enum ReconstructSceneRouter {
    static func route(text: String, barcodeCount: Int = 0) -> ReconstructScene {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        // M2.5 收尾：判定顺序调整。
        // 之前 looksLikeGrid 排在 looksLikeExam 前面，练习册（有 Question + A/B/C + 大量数字）
        // 被先判成 .table。Question/选项是更强的 exam 信号，应优先。
        if looksLikeExam(trimmed) || barcodeCount >= 2 {
            return .exam
        }
        if looksLikeNutritionTable(trimmed) || looksLikeGrid(trimmed) {
            return .table
        }
        if looksLikePackaging(trimmed) {
            return .packaging
        }
        return .plain
    }

    private static func looksLikeNutritionTable(_ text: String) -> Bool {
        text.contains("营养成分表") || text.localizedCaseInsensitiveContains("NRV")
    }

    private static func looksLikeExam(_ text: String) -> Bool {
        let hasQuestion = text.localizedCaseInsensitiveContains("Question")
            || text.contains("题")
        let hasOptions = text.contains("A") && text.contains("B") && text.contains("C")
        return hasQuestion && hasOptions
    }

    private static func looksLikePackaging(_ text: String) -> Bool {
        text.contains("配料") || text.contains("保质期") || text.contains("生产日期")
    }

    private static func looksLikeGrid(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let shortNumeric = lines.filter { line in
            line.count <= 12 && line.contains(where: \.isNumber)
        }
        return shortNumeric.count >= 6 && lines.count >= 10
    }
}
