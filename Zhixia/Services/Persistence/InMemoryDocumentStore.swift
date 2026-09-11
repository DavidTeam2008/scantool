import Foundation

@MainActor
final class InMemoryDocumentStore: DocumentStore {
    private var documents: [UUID: ScanDocument] = [:]
    private var pages: [UUID: ScanPage] = [:]
    private var foldersByID: [UUID: Folder] = [:]

    func documents(query: String, folderID: UUID?, favoritesOnly: Bool) async throws -> [ScanDocument] {
        documents.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { document in
                if let folderID, document.folderID != folderID { return false }
                if favoritesOnly, !document.isFavorite { return false }
                if query.isEmpty { return true }
                return document.title.localizedStandardContains(query)
                    || document.ocrSearchBlob.localizedStandardContains(query)
            }
    }

    func document(id: UUID) async throws -> ScanDocument? {
        documents[id]
    }

    func pages(for documentID: UUID) async throws -> [ScanPage] {
        guard let document = documents[documentID] else { return [] }
        return document.pageIDs.compactMap { pages[$0] }.sorted { $0.index < $1.index }
    }

    func folders() async throws -> [Folder] {
        foldersByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    func create(document: ScanDocument, pages newPages: [ScanPage]) async throws {
        var stored = document
        stored.pageIDs = newPages.map(\.id)
        documents[stored.id] = stored
        for page in newPages {
            pages[page.id] = page
        }
    }

    func appendPages(documentID: UUID, pages newPages: [ScanPage]) async throws {
        guard var document = documents[documentID] else {
            throw ZhixiaError.notFound
        }
        let start = document.pageIDs.count
        for (offset, var page) in newPages.enumerated() {
            page.index = start + offset
            pages[page.id] = page
            document.pageIDs.append(page.id)
        }
        document.updatedAt = Date()
        documents[documentID] = document
    }

    func updateDocument(_ document: ScanDocument) async throws {
        guard documents[document.id] != nil else {
            throw ZhixiaError.notFound
        }
        documents[document.id] = document
    }

    func updatePage(_ page: ScanPage) async throws {
        guard pages[page.id] != nil else {
            throw ZhixiaError.notFound
        }
        pages[page.id] = page
    }

    func deleteDocument(id: UUID) async throws {
        if let document = documents.removeValue(forKey: id) {
            for pageID in document.pageIDs {
                pages.removeValue(forKey: pageID)
            }
        }
    }

    func createFolder(name: String) async throws -> Folder {
        let folder = Folder(id: UUID(), name: name, createdAt: Date())
        foldersByID[folder.id] = folder
        return folder
    }

    func deleteFolder(id: UUID) async throws {
        foldersByID.removeValue(forKey: id)
        for (documentID, document) in documents where document.folderID == id {
            var updated = document
            updated.folderID = nil
            documents[documentID] = updated
        }
    }

    func knownDocumentIDs() async throws -> Set<UUID> {
        Set(documents.keys)
    }
}
