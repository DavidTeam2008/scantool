import Foundation

enum Enhancement: String, Codable, CaseIterable, Sendable, Hashable {
    case original
    case enhance
    case deskewShadow
    case grayscale
    case blackWhite
}
