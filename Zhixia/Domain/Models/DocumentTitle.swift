import Foundation

enum DocumentTitle {
    static func automatic(now: Date = .now, existingTitles: [String] = []) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let base = "\(formatter.string(from: now)) 扫描"
        if !existingTitles.contains(base) {
            return base
        }
        var suffix = 2
        while existingTitles.contains("\(base) · \(suffix)") {
            suffix += 1
        }
        return "\(base) · \(suffix)"
    }

    static func idCard(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: now)) 证件"
    }
}
