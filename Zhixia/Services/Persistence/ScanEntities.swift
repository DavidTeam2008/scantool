import Foundation
import SwiftData

@Model
final class DocumentEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var folderID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool
    var ocrSearchBlob: String
    @Relationship(deleteRule: .cascade, inverse: \PageEntity.document)
    var pages: [PageEntity]

    init(
        id: UUID,
        title: String,
        folderID: UUID?,
        createdAt: Date,
        updatedAt: Date,
        isFavorite: Bool,
        ocrSearchBlob: String,
        pages: [PageEntity] = []
    ) {
        self.id = id
        self.title = title
        self.folderID = folderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.ocrSearchBlob = ocrSearchBlob
        self.pages = pages
    }
}

@Model
final class PageEntity {
    @Attribute(.unique) var id: UUID
    var index: Int
    var quadData: Data
    var enhancementRaw: String
    var rotationTurns: Int
    var originalRelativePath: String
    var renderedRelativePath: String
    var thumbnailRelativePath: String
    var document: DocumentEntity?

    init(
        id: UUID,
        index: Int,
        quadData: Data,
        enhancementRaw: String,
        rotationTurns: Int,
        originalRelativePath: String,
        renderedRelativePath: String,
        thumbnailRelativePath: String
    ) {
        self.id = id
        self.index = index
        self.quadData = quadData
        self.enhancementRaw = enhancementRaw
        self.rotationTurns = rotationTurns
        self.originalRelativePath = originalRelativePath
        self.renderedRelativePath = renderedRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

@Model
final class FolderEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

enum ScanMapping {
    static func encode(_ quad: Quad) -> Data {
        (try? JSONEncoder().encode(quad)) ?? Data()
    }

    static func decodeQuad(_ data: Data) -> Quad {
        (try? JSONDecoder().decode(Quad.self, from: data)) ?? .fullImage
    }

    static func document(from entity: DocumentEntity) -> ScanDocument {
        ScanDocument(
            id: entity.id,
            title: entity.title,
            folderID: entity.folderID,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            isFavorite: entity.isFavorite,
            pageIDs: entity.pages.sorted { $0.index < $1.index }.map(\.id),
            ocrSearchBlob: entity.ocrSearchBlob
        )
    }

    static func page(from entity: PageEntity) -> ScanPage? {
        guard let documentID = entity.document?.id else { return nil }
        return ScanPage(
            id: entity.id,
            documentID: documentID,
            index: entity.index,
            quad: decodeQuad(entity.quadData),
            enhancement: Enhancement(rawValue: entity.enhancementRaw) ?? .enhance,
            rotationTurns: entity.rotationTurns,
            originalRelativePath: entity.originalRelativePath,
            renderedRelativePath: entity.renderedRelativePath,
            thumbnailRelativePath: entity.thumbnailRelativePath
        )
    }

    static func folder(from entity: FolderEntity) -> Folder {
        Folder(id: entity.id, name: entity.name, createdAt: entity.createdAt)
    }
}
