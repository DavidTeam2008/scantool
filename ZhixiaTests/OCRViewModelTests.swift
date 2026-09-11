import Foundation
import Testing
@testable import Zhixia

@MainActor
struct OCRViewModelTests {
    @Test("Empty page results are not treated as text")
    func emptyPagesHaveNoText() async {
        let store = InMemoryDocumentStore()
        let document = ScanDocument(
            id: UUID(),
            title: "试卷",
            folderID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            isFavorite: false,
            pageIDs: [],
            ocrSearchBlob: ""
        )
        let viewModel = OCRViewModel(
            document: document,
            scanPages: [],
            selectedIndex: 0,
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory),
            recognizer: PreviewRecognizer()
        )
        viewModel.pages = [
            OCRPageText(pageID: UUID(), lines: []),
            OCRPageText(pageID: UUID(), lines: [])
        ]
        #expect(viewModel.hasAnyText == false)
        #expect(viewModel.allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Chinese text scores higher than Latin garbage")
    func chineseBeatsGarbage() {
        let chinese = OCRTextQuality.score("这台 iPhone 不能使用 Apple 智能。可以把文字稿导出。")
        let garbage = OCRTextQuality.score("2026 ÷ 88 · „Ë\n*Ж&M], MN&R&ŒZ1‡Л")
        #expect(chinese > garbage)
        #expect(OCRTextQuality.cjkCount("会议记录") == 4)
    }

    @Test("Picks the higher quality of rendered and original")
    func picksBetterOfTwoImages() async {
        let documentID = UUID()
        let pageID = UUID()
        let document = ScanDocument(
            id: documentID,
            title: "会议",
            folderID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            isFavorite: false,
            pageIDs: [pageID],
            ocrSearchBlob: ""
        )
        let page = ScanPage(
            id: pageID,
            documentID: documentID,
            index: 0,
            quad: .fullImage,
            enhancement: .enhance,
            rotationTurns: 0,
            originalRelativePath: "o",
            renderedRelativePath: "r",
            thumbnailRelativePath: "t"
        )
        let viewModel = OCRViewModel(
            document: document,
            scanPages: [page],
            selectedIndex: 0,
            fileStore: FakePagePaths(),
            recognizer: QualityPickerRecognizer()
        )
        await viewModel.recognizeAll()
        #expect(viewModel.allText.contains("会议记录"))
        #expect(!viewModel.allText.contains("÷"))
    }
}

actor QualityPickerRecognizer: TextRecognizing {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        if imageURL.path.contains("rendered") {
            return OCRPageText(pageID: pageID, lines: [OCRLine(text: "2026 ÷ 88 · „Ë", boundingBox: .zero)])
        }
        return OCRPageText(pageID: pageID, lines: [OCRLine(text: "2026年8月30日会议记录", boundingBox: .zero)])
    }
}

struct FakePagePaths: PageFileStoring {
    func writeOriginal(session: UUID, page: UUID, data: Data) async throws -> URL {
        URL(fileURLWithPath: "/tmp/original.jpg")
    }

    nonisolated func originalURL(session: UUID, page: UUID) -> URL {
        URL(fileURLWithPath: "/tmp/original.jpg")
    }

    nonisolated func url(document: UUID, page: UUID, kind: PageFileKind) -> URL {
        URL(fileURLWithPath: "/tmp/\(kind.rawValue).jpg")
    }

    func commit(
        document: UUID,
        drafts: [PageDraft],
        rendered: [UUID: Data],
        thumbs: [UUID: Data],
        keepOriginals: Bool
    ) async throws -> [ScanPage] {
        []
    }

    func removeDocument(document: UUID) async throws {}
    func removeSession(session: UUID) async {}
    func sweep(knownDocumentIDs: Set<UUID>) async {}
    func storageByteCount() async -> Int64 { 0 }
}

@MainActor
struct DocumentPagingTests {
    @Test("Page selection stays in range")
    func paging() async throws {
        let store = InMemoryDocumentStore()
        let files = PageFileStore(root: FileManager.default.temporaryDirectory.appending(path: "page-\(UUID().uuidString)"))
        let documentID = UUID()
        let pages = (0..<3).map { index in
            ScanPage(
                id: UUID(),
                documentID: documentID,
                index: index,
                quad: .fullImage,
                enhancement: .original,
                rotationTurns: 0,
                originalRelativePath: "",
                renderedRelativePath: "",
                thumbnailRelativePath: ""
            )
        }
        try await store.create(
            document: ScanDocument(
                id: documentID,
                title: "书",
                folderID: nil,
                createdAt: Date(),
                updatedAt: Date(),
                isFavorite: false,
                pageIDs: pages.map(\.id),
                ocrSearchBlob: ""
            ),
            pages: pages
        )
        let viewModel = DocumentViewModel(documentID: documentID, store: store, fileStore: files)
        await viewModel.load()
        viewModel.selectNext()
        #expect(viewModel.selectedIndex == 1)
        viewModel.selectNext()
        viewModel.selectNext()
        #expect(viewModel.selectedIndex == 2)
        viewModel.selectPrevious()
        #expect(viewModel.selectedIndex == 1)
    }
}
