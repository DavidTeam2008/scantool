import Foundation
import Testing
@testable import Zhixia

@MainActor
struct CaptureViewModelTests {
    @Test("Finish is blocked when there are no pages")
    func finishRequiresPages() async {
        let viewModel = makeViewModel()
        #expect(viewModel.finish() == nil)
        #expect(viewModel.canFinish == false)
    }

    @Test("A captured page allows finish")
    func captureThenFinish() async throws {
        let viewModel = makeViewModel()
        await viewModel.importImageData(PreviewImages.jpeg())
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.finish()?.count == 1)
    }

    private func makeViewModel() -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.capture.\(UUID().uuidString)") ?? .standard
        return CaptureViewModel(
            launch: .fresh,
            camera: PreviewCamera(),
            detector: PreviewDetector(),
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory.appending(path: "cap-\(UUID().uuidString)")),
            permissions: PreviewPermissions(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }
}

@MainActor
struct ReviewViewModelTests {
    @Test("Save writes a document and clears tmp")
    func savePersists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rev-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let store = InMemoryDocumentStore()
        let session = UUID()
        let page = UUID()
        let jpeg = PreviewImages.jpeg()
        _ = try await files.writeOriginal(session: session, page: page, data: jpeg)
        let defaults = UserDefaults(suiteName: "zhixia.review.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .original)],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: files,
            documentStore: store,
            preferences: PreferencesStore(defaults: defaults)
        )
        let documentID = await viewModel.save()
        #expect(documentID != nil)
        let listed = try await store.documents(query: "", folderID: nil, favoritesOnly: false)
        #expect(listed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: files.originalURL(session: session, page: page).path))
    }

    @Test("Empty drafts cannot save")
    func emptyCannotSave() async {
        let defaults = UserDefaults(suiteName: "zhixia.review.empty.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [],
            sessionID: UUID(),
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory),
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        #expect(viewModel.canSave == false)
        let id = await viewModel.save()
        #expect(id == nil)
    }

    @Test("Filter and rotate leave crop mode so the preview can update")
    func filterLeavesCrop() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rev-crop-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let page = UUID()
        _ = try await files.writeOriginal(session: session, page: page, data: PreviewImages.jpeg())
        let defaults = UserDefaults(suiteName: "zhixia.review.crop.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .original)],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        viewModel.beginCrop()
        #expect(viewModel.isAdjustingCrop)
        viewModel.setFilter(.grayscale)
        #expect(viewModel.isAdjustingCrop == false)
        viewModel.beginCrop()
        viewModel.rotate()
        #expect(viewModel.isAdjustingCrop == false)
    }
}
