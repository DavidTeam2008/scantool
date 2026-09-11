import Foundation
import UIKit

@MainActor
@Observable
final class ReviewViewModel {
    var drafts: [PageDraft]
    var selectedIndex = 0
    var previewImage: UIImage?
    var originalImage: UIImage?
    var isSaving = false
    var isRendering = false
    var isAdjustingCrop = false
    var error: ZhixiaError?
    var savedDocumentID: UUID?

    let sessionID: UUID
    let appendToDocumentID: UUID?

    private let renderer: any ImageRendering
    private let detector: any EdgeDetecting
    private let fileStore: any PageFileStoring
    private let documentStore: any DocumentStore
    private let preferences: PreferencesStore
    private var didRefineQuads = false
    private var pipelineTask: Task<Void, Never>?
    private var renderGeneration = 0

    init(
        drafts: [PageDraft],
        sessionID: UUID,
        appendToDocumentID: UUID?,
        renderer: any ImageRendering,
        detector: any EdgeDetecting,
        fileStore: any PageFileStoring,
        documentStore: any DocumentStore,
        preferences: PreferencesStore
    ) {
        self.drafts = drafts
        self.sessionID = sessionID
        self.appendToDocumentID = appendToDocumentID
        self.renderer = renderer
        self.detector = detector
        self.fileStore = fileStore
        self.documentStore = documentStore
        self.preferences = preferences
    }

    var current: PageDraft? {
        drafts.indices.contains(selectedIndex) ? drafts[selectedIndex] : nil
    }

    var canSave: Bool { !drafts.isEmpty && !isSaving }

    func appear() {
        loadOriginal()
        guard pipelineTask == nil else { return }
        pipelineTask = Task {
            defer { pipelineTask = nil }
            if !didRefineQuads {
                await refineQuads()
                didRefineQuads = true
                await renderSelected()
            } else if previewImage == nil {
                await renderSelected()
            }
        }
    }

    func replaceDrafts(_ drafts: [PageDraft]) {
        let previousIDs = Set(self.drafts.map(\.id))
        let selectedID = current?.id
        self.drafts = drafts
        if let selectedID, let index = drafts.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
        if drafts.contains(where: { !previousIDs.contains($0.id) }) {
            didRefineQuads = false
            previewImage = nil
        }
    }

    func select(index: Int) {
        guard drafts.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        isAdjustingCrop = false
        previewImage = nil
        loadOriginal()
        Task { await renderSelected() }
    }

    func setFilter(_ enhancement: Enhancement) {
        guard drafts.indices.contains(selectedIndex) else { return }
        drafts[selectedIndex].enhancement = enhancement
        drafts[selectedIndex].userAdjustedFilter = true
        leaveCropAndRender()
    }

    func applyFilterToAll() {
        guard let current else { return }
        for index in drafts.indices where !drafts[index].userAdjustedFilter || index == selectedIndex {
            drafts[index].enhancement = current.enhancement
        }
        leaveCropAndRender()
    }

    func rotate() {
        guard drafts.indices.contains(selectedIndex) else { return }
        drafts[selectedIndex].rotationTurns += 1
        leaveCropAndRender()
    }

    func beginCrop() {
        loadOriginal()
        isAdjustingCrop = true
    }

    func toggleCrop() {
        if isAdjustingCrop {
            commitCrop()
        } else {
            beginCrop()
        }
    }

    func updateQuad(_ quad: Quad) {
        guard drafts.indices.contains(selectedIndex) else { return }
        drafts[selectedIndex].quad = quad.clamped()
        drafts[selectedIndex].userAdjustedQuad = true
    }

    func commitCrop() {
        isAdjustingCrop = false
        Task { await renderSelected() }
    }

    func deleteCurrent() {
        guard drafts.indices.contains(selectedIndex) else { return }
        drafts.remove(at: selectedIndex)
        if selectedIndex >= drafts.count {
            selectedIndex = max(0, drafts.count - 1)
        }
        isAdjustingCrop = false
        previewImage = nil
        loadOriginal()
        Task { await renderSelected() }
    }

    func save() async -> UUID? {
        guard canSave else { return nil }
        isAdjustingCrop = false
        isSaving = true
        defer { isSaving = false }
        do {
            var rendered: [UUID: Data] = [:]
            var thumbs: [UUID: Data] = [:]
            for draft in drafts {
                let original = fileStore.originalURL(session: draft.sessionID, page: draft.id)
                let page = try await renderer.renderPage(original: original, draft: draft)
                rendered[draft.id] = page.jpeg
                thumbs[draft.id] = page.thumbnail
            }
            let documentID = appendToDocumentID ?? UUID()
            let pages = try await fileStore.commit(
                document: documentID,
                drafts: drafts,
                rendered: rendered,
                thumbs: thumbs,
                keepOriginals: preferences.keepOriginals
            )
            if let appendToDocumentID {
                try await documentStore.appendPages(documentID: appendToDocumentID, pages: pages)
            } else {
                let existing = try await documentStore.documents(query: "", folderID: nil, favoritesOnly: false)
                let title = modeTitle(existingTitles: existing.map(\.title))
                let document = ScanDocument(
                    id: documentID,
                    title: title,
                    folderID: nil,
                    createdAt: Date(),
                    updatedAt: Date(),
                    isFavorite: false,
                    pageIDs: pages.map(\.id),
                    ocrSearchBlob: ""
                )
                try await documentStore.create(document: document, pages: pages)
            }
            await fileStore.removeSession(session: sessionID)
            savedDocumentID = documentID
            return documentID
        } catch let zhixia as ZhixiaError {
            if case .diskFull = zhixia {
                error = .diskFull
            } else {
                error = .storeFailed
            }
            return nil
        } catch {
            self.error = .storeFailed
            return nil
        }
    }

    private func leaveCropAndRender() {
        isAdjustingCrop = false
        Task { await renderSelected() }
    }

    private func modeTitle(existingTitles: [String]) -> String {
        if drafts.count == 2, drafts.allSatisfy({ $0.quad.iou(with: .idCardWindow) > 0.35 }) {
            return DocumentTitle.idCard()
        }
        return DocumentTitle.automatic(existingTitles: existingTitles)
    }

    private func refineQuads() async {
        for index in drafts.indices where !drafts[index].userAdjustedQuad {
            let url = fileStore.originalURL(session: drafts[index].sessionID, page: drafts[index].id)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let detected = await detector.detect(imageData: data, idCardWindow: nil) {
                drafts[index].quad = detected
            }
        }
    }

    private func loadOriginal() {
        guard let current else {
            originalImage = nil
            return
        }
        let originalURL = fileStore.originalURL(session: current.sessionID, page: current.id)
        originalImage = UIImage(contentsOfFile: originalURL.path)
    }

    private func renderSelected() async {
        guard let current else {
            previewImage = nil
            originalImage = nil
            return
        }
        renderGeneration += 1
        let generation = renderGeneration
        isRendering = true
        if originalImage == nil {
            loadOriginal()
        }
        let originalURL = fileStore.originalURL(session: current.sessionID, page: current.id)
        do {
            let rendered = try await renderer.renderPage(original: originalURL, draft: current)
            guard generation == renderGeneration else { return }
            previewImage = UIImage(data: rendered.jpeg) ?? originalImage
        } catch {
            guard generation == renderGeneration else { return }
            previewImage = originalImage
        }
        if generation == renderGeneration {
            isRendering = false
        }
    }
}
