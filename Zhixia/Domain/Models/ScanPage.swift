import Foundation

struct ScanPage: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var documentID: UUID
    var index: Int
    var quad: Quad
    var enhancement: Enhancement
    var rotationTurns: Int
    var originalRelativePath: String
    var renderedRelativePath: String
    var thumbnailRelativePath: String
}
