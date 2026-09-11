import Foundation

struct ScanDocument: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var title: String
    var folderID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool
    var pageIDs: [UUID]
    var ocrSearchBlob: String

    var pageCount: Int { pageIDs.count }
}

struct Folder: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
}
