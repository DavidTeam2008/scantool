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
