import Foundation

struct OCRLine: Equatable, Sendable, Hashable {
    var text: String
    var boundingBox: CGRect
    /// 「这一行是标题」的**外部提示**。
    ///
    /// 只有 iOS 26 的结构化通路（`RecognizeDocumentsRequest` 的 `RecognizedTextObservation.isTitle`）
    /// 能给出这个信息；几何管线（`VNRecognizeTextRequest`）拿不到，**恒为 false**，
    /// 所以它只是给 `OnDeviceReadingOrder` 的启发式**加权**，不改变老通路的行为。
    var isTitle: Bool = false
    /// Vision 对这行文本的识别置信度（0~1，spec/layout-restore plan D4/D8）。
    ///
    /// - 几何通路：`VNRecognizedText.topCandidates(1).first?.confidence` 透传；
    /// - iOS 26 结构化通路暂无对应字段 → 保持默认 `1.0`；
    /// - **默认 1.0 向后兼容**：既有夹具/测试不传此字段时视为「完全可信」，
    ///   不会触发乱码区域判定（`GarbledRegionDetector` 的低置信门控）。
    var confidence: Double = 1.0
}

struct OCRPageText: Equatable, Sendable, Hashable {
    var pageID: UUID
    var lines: [OCRLine]

    var joinedText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var hasText: Bool {
        !joinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
