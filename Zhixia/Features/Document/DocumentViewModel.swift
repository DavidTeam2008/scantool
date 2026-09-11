import Foundation

@MainActor
@Observable
final class DocumentViewModel {
    var document: ScanDocument?
    var pages: [ScanPage] = []
    var selectedIndex = 0
    var error: ZhixiaError?

    let documentID: UUID
    private let store: any DocumentStore
    private let fileStore: any PageFileStoring

    init(documentID: UUID, store: any DocumentStore, fileStore: any PageFileStoring) {
        self.documentID = documentID
        self.store = store
        self.fileStore = fileStore
    }

    var currentPage: ScanPage? {
        pages.indices.contains(selectedIndex) ? pages[selectedIndex] : nil
    }

    func selectPrevious() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
    }

    func selectNext() {
        guard selectedIndex + 1 < pages.count else { return }
        selectedIndex += 1
    }

    func load() async {
        do {
            document = try await store.document(id: documentID)
            pages = try await store.pages(for: documentID)
            if selectedIndex >= pages.count {
                selectedIndex = max(0, pages.count - 1)
            }
        } catch {
            self.error = .notFound
        }
    }

    func renderedURL(for page: ScanPage) -> URL {
        fileStore.url(document: documentID, page: page.id, kind: .rendered)
    }

    func thumbnailURL(for page: ScanPage) -> URL {
        fileStore.url(document: documentID, page: page.id, kind: .thumbnail)
    }

    func renderedURLs() -> [URL] {
        pages.map { renderedURL(for: $0) }
    }

    func rename(_ title: String) async {
        guard var document else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.title = trimmed
        document.updatedAt = Date()
        try? await store.updateDocument(document)
        self.document = document
    }

    func toggleFavorite() async {
        guard var document else { return }
        document.isFavorite.toggle()
        document.updatedAt = Date()
        try? await store.updateDocument(document)
        self.document = document
    }

    func move(to folderID: UUID?) async {
        guard var document else { return }
        document.folderID = folderID
        document.updatedAt = Date()
        try? await store.updateDocument(document)
        self.document = document
    }

    func reorder(from source: IndexSet, to destination: Int) async {
        pages.move(fromOffsets: source, toOffset: destination)
        for index in pages.indices {
            pages[index].index = index
        }
        guard var document else { return }
        document.pageIDs = pages.map(\.id)
        document.updatedAt = Date()
        try? await store.updateDocument(document)
        self.document = document
    }

    func deleteDocument() async -> Bool {
        do {
            try await fileStore.removeDocument(document: documentID)
            try await store.deleteDocument(id: documentID)
            return true
        } catch {
            self.error = .storeFailed
            return false
        }
    }

    func applyOCRBlob(_ blob: String) async {
        guard var document else { return }
        document.ocrSearchBlob = blob
        if document.title.contains("扫描"), let firstLine = blob.split(separator: "\n").first {
            let snippet = String(firstLine.prefix(16))
            if !snippet.isEmpty {
                document.title = snippet
            }
        }
        document.updatedAt = Date()
        try? await store.updateDocument(document)
        self.document = document
    }
}
