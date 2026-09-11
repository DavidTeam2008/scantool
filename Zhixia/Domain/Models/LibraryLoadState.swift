import Foundation

enum LibraryTab: String, Sendable, CaseIterable, Hashable {
    case all
    case folders
    case favorites
}

enum LibraryLoadState: Equatable, Sendable {
    case loading
    case empty
    case ready([ScanDocument])
    case failed(ZhixiaError)
}

enum CapturePhase: Equatable, Sendable {
    case idle
    case previewing
    case locked(Quad)
    case capturing
}

enum IDCardFace: String, Sendable, Hashable {
    case front
    case back
}
