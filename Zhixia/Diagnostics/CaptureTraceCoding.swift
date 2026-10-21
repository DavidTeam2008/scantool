import Foundation

/// 诊断数据的 JSON 编解码（spec/guided-capture T001 / T003）——**时间戳必须保精度**。
///
/// ## 为什么不用默认 `.iso8601`
/// `JSONEncoder.DateEncodingStrategy.iso8601` **只保留整秒**（无小数秒）。
/// 取景帧间隔约 1/15s ≈ 67ms，整秒截断会把同秒的帧压成同一时刻——
/// 诊断包里「锁定延迟」「慢漂移（1%/帧）」这两类判读**直接失真**。
/// 这里用 ISO8601 + 小数秒（毫秒精度），解码端同时兼容无小数秒的旧包。
///
/// ## 实现注记
/// 用 `Date.ISO8601FormatStyle`（值类型、Sendable 安全）而非
/// `ISO8601DateFormatter`（非 Sendable，Swift 6 严格并发下不能做静态常量）。
enum CaptureTraceCoding {
    /// 编码器（ISO8601 + 小数秒，键排序 + 美化输出——便于人工判读 diff）。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// 解码器（兼容带/不带小数秒的 ISO8601）。
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间戳：\(raw)"
            )
        }
        return decoder
    }
}
