import Foundation

@MainActor
@Observable
final class LibraryViewModel {
    var state: LibraryLoadState = .loading
    var tab: LibraryTab = .all
    var query = ""
    var folders: [Folder] = []
    var selectedFolderID: UUID?
    var storageBytes: Int64 = 0

    private let store: any DocumentStore
    private let fileStore: any PageFileStoring

    init(store: any DocumentStore, fileStore: any PageFileStoring) {
        self.store = store
        self.fileStore = fileStore
    }

    var documents: [ScanDocument] {
        if case .ready(let items) = state { return items }
        return []
    }

    func reload() async {
        do {
            let folderID = tab == .folders ? selectedFolderID : nil
            let items = try await store.documents(
                query: query,
                folderID: folderID,
                favoritesOnly: tab == .favorites
            )
            folders = try await store.folders()
            storageBytes = await fileStore.storageByteCount()
            state = items.isEmpty ? .empty : .ready(items)
            let known = try await store.knownDocumentIDs()
            await fileStore.sweep(knownDocumentIDs: known)
        } catch {
            state = .failed(.storeFailed)
        }
    }

    func delete(_ document: ScanDocument) async {
        do {
            try await fileStore.removeDocument(document: document.id)
            try await store.deleteDocument(id: document.id)
            await reload()
        } catch {
            state = .failed(.storeFailed)
        }
    }

    func toggleFavorite(_ document: ScanDocument) async {
        var updated = document
        updated.isFavorite.toggle()
        updated.updatedAt = Date()
        do {
            try await store.updateDocument(updated)
            await reload()
        } catch {
            state = .failed(.storeFailed)
        }
    }

    func rename(_ document: ScanDocument, title: String) async {
        var updated = document
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return }
        updated.updatedAt = Date()
        try? await store.updateDocument(updated)
        await reload()
    }

    func move(_ document: ScanDocument, to folderID: UUID?) async {
        var updated = document
        updated.folderID = folderID
        updated.updatedAt = Date()
        try? await store.updateDocument(updated)
        await reload()
    }

    func createFolder(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await store.createFolder(name: trimmed)
            await reload()
        } catch {
            state = .failed(.storeFailed)
        }
    }

    func deleteFolder(_ folder: Folder) async {
        try? await store.deleteFolder(id: folder.id)
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        await reload()
    }

    func coverURL(for document: ScanDocument) -> URL? {
        guard let pageID = document.pageIDs.first else { return nil }
        return fileStore.url(document: document.id, page: pageID, kind: .thumbnail)
    }
}
