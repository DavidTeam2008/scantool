import Foundation

struct ScanSession: Identifiable, Equatable, Sendable {
    var id: UUID
    var mode: ScanMode
    var appendToDocumentID: UUID?
    var drafts: [PageDraft]
    var phase: CapturePhase
    var idFace: IDCardFace

    init(
        id: UUID = UUID(),
        mode: ScanMode = .document,
        appendToDocumentID: UUID? = nil,
        drafts: [PageDraft] = [],
        phase: CapturePhase = .idle,
        idFace: IDCardFace = .front
    ) {
        self.id = id
        self.mode = mode
        self.appendToDocumentID = appendToDocumentID
        self.drafts = drafts
        self.phase = phase
        self.idFace = idFace
    }
}

enum CaptureLaunch: Identifiable, Hashable, Sendable {
    case fresh
    case append(UUID)

    var id: String {
        switch self {
        case .fresh: "fresh"
        case .append(let documentID): documentID.uuidString
        }
    }

    var documentID: UUID? {
        switch self {
        case .fresh: nil
        case .append(let documentID): documentID
        }
    }
}
