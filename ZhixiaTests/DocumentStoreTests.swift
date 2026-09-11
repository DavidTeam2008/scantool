import Foundation
import Testing
@testable import Zhixia

@MainActor
struct DocumentStoreTests {
    @Test("Saving a document writes metadata and files")
    func saveWritesStoreAndFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zhixia-test-\(UUID().uuidString)")
        let files = PageFileStore(root: directory)
        let store = InMemoryDocumentStore()
        let session = UUID()
        let page = UUID()
        let jpeg = PreviewImages.jpeg()
        _ = try await files.writeOriginal(session: session, page: page, data: jpeg)
        let draft = PageDraft(sessionID: session, quad: .fullImage, enhancement: .enhance)
        let pages = try await files.commit(
            document: UUID(),
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .enhance)],
            rendered: [page: jpeg],
            thumbs: [page: jpeg],
            keepOriginals: true
        )
        let documentID = pages[0].documentID
        try await store.create(
            document: ScanDocument(
                id: documentID,
                title: "测试",
                folderID: nil,
                createdAt: Date(),
                updatedAt: Date(),
                isFavorite: false,
                pageIDs: [page],
                ocrSearchBlob: ""
            ),
            pages: pages
        )
        let listed = try await store.documents(query: "", folderID: nil, favoritesOnly: false)
        #expect(listed.count == 1)
        #expect(FileManager.default.fileExists(atPath: files.url(document: documentID, page: page, kind: .rendered).path))
        _ = draft
    }

    @Test("Deleting a document removes its files")
    func deleteRemovesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zhixia-del-\(UUID().uuidString)")
        let files = PageFileStore(root: directory)
        let store = InMemoryDocumentStore()
        let session = UUID()
        let page = UUID()
        let documentID = UUID()
        let jpeg = PreviewImages.jpeg()
        _ = try await files.writeOriginal(session: session, page: page, data: jpeg)
        let pages = try await files.commit(
            document: documentID,
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .original)],
            rendered: [page: jpeg],
            thumbs: [page: jpeg],
            keepOriginals: true
        )
        try await store.create(
            document: ScanDocument(
                id: documentID,
                title: "删我",
                folderID: nil,
                createdAt: Date(),
                updatedAt: Date(),
                isFavorite: false,
                pageIDs: [page],
                ocrSearchBlob: ""
            ),
            pages: pages
        )
        try await files.removeDocument(document: documentID)
        try await store.deleteDocument(id: documentID)
        #expect(try await store.document(id: documentID) == nil)
        #expect(!FileManager.default.fileExists(atPath: files.url(document: documentID, page: page, kind: .rendered).path))
    }

    @Test("Search matches OCR blob")
    func searchOCR() async throws {
        let store = InMemoryDocumentStore()
        let document = ScanDocument(
            id: UUID(),
            title: "8月30日 扫描",
            folderID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            isFavorite: false,
            pageIDs: [],
            ocrSearchBlob: "房屋租赁合同 甲方林秋白"
        )
        try await store.create(document: document, pages: [])
        let found = try await store.documents(query: "租赁", folderID: nil, favoritesOnly: false)
        #expect(found.count == 1)
    }

    @Test("Creating a folder persists and reloads")
    func createFolderPersists() async throws {
        let store = InMemoryDocumentStore()
        let viewModel = LibraryViewModel(
            store: store,
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory.appending(path: "lib-\(UUID().uuidString)"))
        )
        await viewModel.createFolder(name: "  合同  ")
        #expect(viewModel.folders.map(\.name) == ["合同"])
        let stored = try await store.folders()
        #expect(stored.map(\.name) == ["合同"])
    }
}
