import Foundation
import SwiftData

@MainActor
final class SwiftDataDocumentStore: DocumentStore {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    func documents(query: String, folderID: UUID?, favoritesOnly: Bool) async throws -> [ScanDocument] {
        let descriptor = FetchDescriptor<DocumentEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let entities = try context.fetch(descriptor)
        return entities
            .map(ScanMapping.document(from:))
            .filter { document in
                if let folderID, document.folderID != folderID { return false }
                if favoritesOnly, !document.isFavorite { return false }
                if query.isEmpty { return true }
                return document.title.localizedStandardContains(query)
                    || document.ocrSearchBlob.localizedStandardContains(query)
            }
    }

    func document(id: UUID) async throws -> ScanDocument? {
        try entity(id: id).map(ScanMapping.document(from:))
    }

    func pages(for documentID: UUID) async throws -> [ScanPage] {
        guard let entity = try entity(id: documentID) else { return [] }
        return entity.pages
            .sorted { $0.index < $1.index }
            .compactMap(ScanMapping.page(from:))
    }

    func folders() async throws -> [Folder] {
        let descriptor = FetchDescriptor<FolderEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(ScanMapping.folder(from:))
    }

    func create(document: ScanDocument, pages: [ScanPage]) async throws {
        let entity = DocumentEntity(
            id: document.id,
            title: document.title,
            folderID: document.folderID,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt,
            isFavorite: document.isFavorite,
            ocrSearchBlob: document.ocrSearchBlob
        )
        entity.pages = pages.map(makePageEntity)
        context.insert(entity)
        try context.save()
    }

    func appendPages(documentID: UUID, pages: [ScanPage]) async throws {
        guard let entity = try entity(id: documentID) else {
            throw ZhixiaError.notFound
        }
        let start = (entity.pages.map(\.index).max() ?? -1) + 1
        for (offset, page) in pages.enumerated() {
            var shifted = page
            shifted.index = start + offset
            let pageEntity = makePageEntity(shifted)
            pageEntity.document = entity
            entity.pages.append(pageEntity)
        }
        entity.updatedAt = Date()
        try context.save()
    }

    func updateDocument(_ document: ScanDocument) async throws {
        guard let entity = try entity(id: document.id) else {
            throw ZhixiaError.notFound
        }
        entity.title = document.title
        entity.folderID = document.folderID
        entity.updatedAt = document.updatedAt
        entity.isFavorite = document.isFavorite
        entity.ocrSearchBlob = document.ocrSearchBlob
        if !document.pageIDs.isEmpty {
            for page in entity.pages {
                if let index = document.pageIDs.firstIndex(of: page.id) {
                    page.index = index
                }
            }
        }
        try context.save()
    }

    func updatePage(_ page: ScanPage) async throws {
        let id = page.id
        var descriptor = FetchDescriptor<PageEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw ZhixiaError.notFound
        }
        entity.index = page.index
        entity.quadData = ScanMapping.encode(page.quad)
        entity.enhancementRaw = page.enhancement.rawValue
        entity.rotationTurns = page.rotationTurns
        entity.originalRelativePath = page.originalRelativePath
        entity.renderedRelativePath = page.renderedRelativePath
        entity.thumbnailRelativePath = page.thumbnailRelativePath
        entity.document?.updatedAt = Date()
        try context.save()
    }

    func deleteDocument(id: UUID) async throws {
        guard let entity = try entity(id: id) else { return }
        context.delete(entity)
        try context.save()
    }

    func createFolder(name: String) async throws -> Folder {
        let entity = FolderEntity(id: UUID(), name: name, createdAt: Date())
        context.insert(entity)
        try context.save()
        return ScanMapping.folder(from: entity)
    }

    func deleteFolder(id: UUID) async throws {
        var descriptor = FetchDescriptor<FolderEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        if let folder = try context.fetch(descriptor).first {
            let documents = try context.fetch(FetchDescriptor<DocumentEntity>())
            for document in documents where document.folderID == id {
                document.folderID = nil
            }
            context.delete(folder)
            try context.save()
        }
    }

    func knownDocumentIDs() async throws -> Set<UUID> {
        let entities = try context.fetch(FetchDescriptor<DocumentEntity>())
        return Set(entities.map(\.id))
    }

    private func entity(id: UUID) throws -> DocumentEntity? {
        var descriptor = FetchDescriptor<DocumentEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func makePageEntity(_ page: ScanPage) -> PageEntity {
        PageEntity(
            id: page.id,
            index: page.index,
            quadData: ScanMapping.encode(page.quad),
            enhancementRaw: page.enhancement.rawValue,
            rotationTurns: page.rotationTurns,
            originalRelativePath: page.originalRelativePath,
            renderedRelativePath: page.renderedRelativePath,
            thumbnailRelativePath: page.thumbnailRelativePath
        )
    }
}
