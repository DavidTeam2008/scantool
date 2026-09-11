import Foundation

struct OCRLine: Equatable, Sendable, Hashable {
    var text: String
    var boundingBox: CGRect
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
