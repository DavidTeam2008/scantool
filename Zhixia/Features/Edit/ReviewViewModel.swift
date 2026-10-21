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

    /// 拍后增强（spec/scan-enhance FR-001/002）：
    /// 1. **全分辨率静帧重检 + 身份锚定**——静帧候选与拍摄框 IoU ≥ 0.85
    ///    才采纳（高分辨率检测 + 贴边吸附更准）；低于阈值视为换了对象，
    ///    保留拍摄框；`.fullImage` 兜底页无身份，直接采纳。
    /// 2. **书页拆分**——摊开书场景候选池里只有整书一个候选，「只拍右页」
    ///    只能拍后按书脊拆开：把四边形透视矫正成矩形，在矫正图上找贯穿
    ///    页高的竖暗带（书脊），拆出右页。
    /// 结果直接反映在整理页预览（可见、可再拖角）；用户调过角的页跳过。
    private func refineQuads() async {
        for index in drafts.indices where !drafts[index].userAdjustedQuad {
            let url = fileStore.originalURL(session: drafts[index].sessionID, page: drafts[index].id)
            guard let data = try? Data(contentsOf: url) else { continue }
            let captured = drafts[index].quad
            var stillArea = -1.0
            var identityIOU = -1.0
            var acceptedStill = false
            if let detected = await detector.detect(imageData: data, idCardWindow: nil) {
                stillArea = detected.area
                identityIOU = detected.iou(with: captured)
                // 身份锚定 + **不越出拍摄框太多**：拍摄框已钳制到预览可见域
                //（capture 侧），整理页重检不得把用户没看见的内容扩回来
                //（如"右页+折痕"外框，面积可大 20%+）。10% 容差保留平整
                // 文档的内缩修正。`.fullImage` 兜底页无身份，直接采纳。
                let withinCapture = detected.area <= captured.area * 1.10
                if captured == .fullImage
                    || (identityIOU >= Self.refineIdentityIOU && withinCapture) {
                    drafts[index].quad = detected
                    acceptedStill = true
                }
            }
            let split = applySpreadSplitIfNeeded(index: index, data: data)
            ZhixiaLog.refineStage(
                capturedArea: captured.area,
                stillArea: stillArea,
                iou: identityIOU,
                acceptedStill: acceptedStill,
                aspect: split.aspect,
                reason: split.reason,
                trimU: split.trimU,
                trimDepth: split.trimDepth,
                spineU: split.spineU,
                prominence: split.prominence,
                continuity: split.continuity,
                splitApplied: split.applied
            )
        }
    }

    /// 整理页拍后增强的身份锚定阈值（spec/scan-enhance FR-001）。
    private static let refineIdentityIOU: Double = 0.85

    private struct SplitOutcome {
        var aspect: Double = -1
        var reason = "none"
        var trimU: Double = -1
        var trimDepth: Double = 0
        var spineU: Double = -1
        var prominence: Double = 0
        var continuity: Double = 0
        var applied = false
    }

    /// 拍后裁切（spec/scan-enhance FR-002）：透视矫正后两种模型互补——
    /// 1. **左侧折痕暗条**（场景 2：折起部分是一条暗带）→ 从左侧第一个持续
    ///    明亮列裁掉折条；
    /// 2. **中央书脊暗谷**（场景 1：亮左页的摊开书）→ 沿书脊拆出右页。
    private func applySpreadSplitIfNeeded(index: Int, data: Data) -> SplitOutcome {
        var outcome = SplitOutcome()
        guard let image = Self.uprightImage(from: data) else {
            outcome.reason = "noImage"
            return outcome
        }
        let quad = drafts[index].quad
        let size = image.extent.size
        outcome.aspect = SpreadSplitter.pixelAspect(of: quad, imageSize: size)
        guard let rectified = Self.rectifiedImage(image, quad: quad) else {
            outcome.reason = "noRectified"
            return outcome
        }
        if let trim = SpreadSplitter.leftFoldTrim(inRectified: rectified) {
            outcome.reason = "leftTrim"
            outcome.trimU = trim.u
            outcome.trimDepth = trim.stripDepth
            drafts[index].quad = SpreadSplitter.split(quad, at: trim.u).right
            outcome.applied = true
            return outcome
        }
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        let diagnosis = analysis.diagnosis
        outcome.spineU = diagnosis.bestU
        outcome.prominence = diagnosis.prominence
        outcome.continuity = diagnosis.continuity
        guard let spine = analysis.spine else {
            outcome.reason = diagnosis.reason.isEmpty ? "noSpine" : diagnosis.reason
            return outcome
        }
        outcome.reason = "spine"
        drafts[index].quad = SpreadSplitter.split(quad, at: spine.u).right
        outcome.applied = true
        return outcome
    }

    /// 从原图数据加载直立 CIImage（EXIF 方向与渲染链一致）。
    private static func uprightImage(from data: Data) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let orientationRaw = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        return CIImage(data: data)?.oriented(orientation)
    }

    /// 四边形 → 透视矫正矩形图（与 `ImagePipeline.perspectiveCorrect` 同源
    /// 语义：像素点、y 翻转到 CI 坐标）；长边限 600px，只用于书脊亮度扫描。
    private static func rectifiedImage(
        _ image: CIImage, quad: Quad, maxLongestEdge: CGFloat = 600
    ) -> CGImage? {
        let size = image.extent.size
        guard size.width > 0, size.height > 0, !quad.isDegenerate else { return nil }
        let pixels = quad.pixelPoints(imageSize: size)
        func ciPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: size.height - point.y)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = ciPoint(pixels.0)
        filter.topRight = ciPoint(pixels.1)
        filter.bottomRight = ciPoint(pixels.2)
        filter.bottomLeft = ciPoint(pixels.3)
        guard var output = filter.outputImage else { return nil }
        let longest = max(output.extent.width, output.extent.height)
        if longest > maxLongestEdge {
            let scale = maxLongestEdge / longest
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let context = CIContext()
        return context.createCGImage(output, from: output.extent.integral)
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
