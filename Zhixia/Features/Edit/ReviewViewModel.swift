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
    /// 拆分工具是否打开（spec/guided-capture T021 / FR-008）。
    var isAdjustingSplit = false
    var error: ZhixiaError?
    var savedDocumentID: UUID?

    /// 逐页拆分提案（spec/guided-capture T020 / FR-008）——**提案不写 quad**，
    /// 只在用户确认（`applySplit`）时才改写。键为页 ID：提案只属于它自己的
    /// 页，不跨页复用（`splitProposal` 取当前页的那一份）。
    private var proposalsByPage: [UUID: SplitProposal] = [:]
    /// 拆分撤销栈（每项：页 ID + 提案前的框 + 当时的提案）。
    private struct SplitUndo: Equatable {
        var pageID: UUID
        var quadBefore: Quad
        var proposal: SplitProposal
    }
    private var splitUndoStack: [SplitUndo] = []

    /// 当前页的拆分提案（nil = 没有建议；UI 此时提供「手动拆分」）。
    var splitProposal: SplitProposal? {
        guard let id = current?.id else { return nil }
        return proposalsByPage[id]
    }

    /// 是否还能撤销上一次拆分应用。
    var canUndoSplit: Bool { !splitUndoStack.isEmpty }

    let sessionID: UUID
    let appendToDocumentID: UUID?

    private let renderer: any ImageRendering
    private let detector: any EdgeDetecting
    private let fileStore: any PageFileStoring
    private let documentStore: any DocumentStore
    private let preferences: PreferencesStore
    /// 首轮拍后精修（静帧重检/书脊拆分）是否完成——测试与诊断用的只读锚点，
    /// 不依赖预览渲染（渲染在慢机器/并发全量测试时可能长时间不返回）。
    private(set) var didRefineQuads = false
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
        // 手动改框 → 提案作废（用户已经自己决定了边界，系统的建议不再适用）。
        clearProposal(for: drafts[selectedIndex].id)
    }

    func commitCrop() {
        isAdjustingCrop = false
        Task { await renderSelected() }
    }

    func deleteCurrent() {
        guard drafts.indices.contains(selectedIndex) else { return }
        let removedID = drafts[selectedIndex].id
        drafts.remove(at: selectedIndex)
        if selectedIndex >= drafts.count {
            selectedIndex = max(0, drafts.count - 1)
        }
        isAdjustingCrop = false
        // 删页 → 该页的提案与撤销记录一并作废。
        clearProposal(for: removedID)
        splitUndoStack.removeAll { $0.pageID == removedID }
        previewImage = nil
        loadOriginal()
        Task { await renderSelected() }
    }

    // MARK: - 拆分提案（spec/guided-capture T020~T022 / FR-008 / plan D5）

    /// 打开/关闭拆分工具（打开时若无提案 → 现场算一次）。
    func toggleSplitTool() {
        isAdjustingSplit.toggle()
        if isAdjustingSplit, splitProposal == nil {
            Task { await computeSplitProposal() }
        }
    }

    /// 现场计算当前页的拆分提案（不写 quad）。
    func computeSplitProposal() async {
        guard drafts.indices.contains(selectedIndex) else { return }
        let index = selectedIndex
        // 引导页（用户已定框）不生成提案——引导框就是用户意图。
        guard !drafts[index].userAdjustedQuad else { return }
        let url = fileStore.originalURL(session: drafts[index].sessionID, page: drafts[index].id)
        guard let data = try? Data(contentsOf: url) else { return }
        if let proposal = Self.makeSplitProposal(quad: drafts[index].quad, data: data) {
            proposalsByPage[drafts[index].id] = proposal
        }
    }

    /// 拖动分割线（改 `u`）——只改提案，不写 quad。
    func updateSplitU(_ u: Double) {
        guard var proposal = splitProposal, let pageID = current?.id else { return }
        let clamped = min(1, max(0, u))
        proposal.u = clamped
        proposal.quadAfter = SpreadSplitter.split(proposal.quadBefore, at: clamped).right
        proposalsByPage[pageID] = proposal
    }

    /// 选择拆分结果（整页/左页/右页）——**只改提案的高亮，不写 quad**。
    func selectSplitOption(_ selection: SplitProposal.Selection) {
        guard var proposal = splitProposal, let pageID = current?.id else { return }
        proposal.selection = selection
        proposalsByPage[pageID] = proposal
    }

    /// 应用拆分（用户确认）——**这一步才写 quad**。
    func applySplit(_ selection: SplitProposal.Selection) {
        guard drafts.indices.contains(selectedIndex) else { return }
        guard let proposal = splitProposal else { return }
        let index = selectedIndex
        let pageID = drafts[index].id
        let quad: Quad
        switch selection {
        case .whole:
            quad = proposal.quadBefore
        case .left:
            quad = SpreadSplitter.split(proposal.quadBefore, at: proposal.u).left
        case .right:
            quad = SpreadSplitter.split(proposal.quadBefore, at: proposal.u).right
        }
        drafts[index].quad = quad
        drafts[index].userAdjustedQuad = true
        splitUndoStack.append(
            SplitUndo(pageID: pageID, quadBefore: proposal.quadBefore, proposal: proposal)
        )
        proposalsByPage.removeValue(forKey: pageID)
        ZhixiaLog.reviewSplit(
            proposalU: proposal.u,
            source: proposal.source.rawValue,
            prominence: proposal.prominence,
            continuity: proposal.continuity,
            confidence: proposal.confidence,
            selection: selection.rawValue,
            applied: true
        )
        Task { await renderSelected() }
    }

    /// 撤销上一次拆分应用（恢复提案前的框）——**并恢复提案**，用户可再选一次
    /// （验收 §4-5「撤销：恢复 quadBefore；可再次应用」）。
    func undoSplit() {
        guard let undo = splitUndoStack.popLast() else { return }
        guard let index = drafts.firstIndex(where: { $0.id == undo.pageID }) else { return }
        drafts[index].quad = undo.quadBefore
        proposalsByPage[undo.pageID] = undo.proposal
        ZhixiaLog.reviewSplit(
            proposalU: undo.proposal.u,
            source: undo.proposal.source.rawValue,
            prominence: undo.proposal.prominence,
            continuity: undo.proposal.continuity,
            confidence: undo.proposal.confidence,
            selection: "none",
            applied: false
        )
        Task { await renderSelected() }
    }

    /// 清空某页的提案（手动改框 / 删页 / 应用后）。
    private func clearProposal(for pageID: UUID) {
        proposalsByPage.removeValue(forKey: pageID)
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
            let split: SplitOutcome
            if let intent = drafts[index].outputIntent, intent != .wholePage {
                split = splitForOutputIntent(index: index, data: data, intent: intent)
            } else {
                split = makeSplitProposal(index: index, data: data)
            }
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

    /// CF-T005：左/右页输出意图的拍后拆分分派。
    ///
    /// **角色优先**（视频 8 回归修复）：快门拍的是目标页还是整摊包络，
    /// 由拍摄时写入的 `PageDraft.quadRole` 决定，不再用宽高比猜——
    /// 被屏幕裁掉的整摊包络可能只有 0.8 的 pixel aspect，和单页一样窄。
    ///
    /// - `.target`：已经是目标页；右页只做左折条清理，左页不二次拆；
    /// - `.envelope`：目标页没解析出来，**必须尝试**书脊/亮缝拆分；
    ///   找不到证据就保留包络并记录 `envelopeNoSplit`，绝不静默当目标页；
    /// - `nil`（旧数据/非包络路径）：保留原来的宽高比推断，旧草稿行为不变。
    private func splitForOutputIntent(
        index: Int,
        data: Data,
        intent: CaptureIntent
    ) -> SplitOutcome {
        switch drafts[index].quadRole {
        case .target:
            if intent == .rightPage {
                // 折页书右页常见形态：单页框左缘仍带折起条。复用暗折条/
                // 亮折条模型，高置信才自动裁掉，否则只给预选提案。
                return applyOutputIntentFoldSplit(index: index, data: data)
            }
            var outcome = SplitOutcome()
            outcome.reason = "intentPage"
            return outcome
        case .envelope:
            var outcome = applyOutputIntentSplit(index: index, data: data, intent: intent)
            guard !outcome.found else { return outcome }
            outcome.reason = "envelopeNoSplit:\(outcome.reason)"
            return outcome
        case nil:
            if PageIntentResolver.isSpreadLike(drafts[index].quad) {
                return applyOutputIntentSplit(index: index, data: data, intent: intent)
            }
            if intent == .rightPage {
                return applyOutputIntentFoldSplit(index: index, data: data)
            }
            var outcome = SplitOutcome()
            outcome.reason = "intentPage"
            return outcome
        }
    }

    /// CF-T005：拍后高分辨率拆分（左/右页输出意图）。
    ///
    /// 与实时 600px 矫正图不同，这里用 1600px 原图矫正后再找书脊——书脊
    /// 阴影带、折页暗条在高分辨率下更完整，左右页边界更准。策略：
    /// - 只有书脊证据（`SpreadSplitter.analyzeSpine`）才作为左/右页输出；
    ///   左侧折条模型是“右页左缘”，套到左页会切出折页窄条，故不采用；
    /// - 置信度 ≥ `SplitProposalConfidence.applyThreshold` → 直接落到目标页
    ///   （可见页立即正确，并压入撤销栈）；
    /// - 置信度不足 → 只生成提案并预选目标侧，Review 首屏可见、由用户确认。
    private func applyOutputIntentSplit(
        index: Int,
        data: Data,
        intent: CaptureIntent
    ) -> SplitOutcome {
        var outcome = SplitOutcome()
        guard let image = Self.uprightImage(from: data) else {
            outcome.reason = "noImage"
            return outcome
        }
        let quad = drafts[index].quad
        outcome.aspect = SpreadSplitter.pixelAspect(of: quad, imageSize: image.extent.size)
        guard let rectified = Self.rectifiedImage(
            image,
            quad: quad,
            maxLongestEdge: Self.outputIntentRectifyLongEdge
        ) else {
            outcome.reason = "noRectified"
            return outcome
        }
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        let diagnosis = analysis.diagnosis
        outcome.spineU = diagnosis.bestU
        outcome.prominence = diagnosis.prominence
        outcome.continuity = diagnosis.continuity
        if let spine = analysis.spine {
            return applySpineSplit(
                index: index,
                quad: quad,
                u: spine.u,
                prominence: diagnosis.prominence,
                continuity: diagnosis.continuity,
                confidence: SplitProposalConfidence.spine(
                    prominence: diagnosis.prominence,
                    continuity: diagnosis.continuity
                ),
                intent: intent,
                outcome: outcome
            )
        }
        // CF-T005：暗谷模型找不到时，补「亮缝」模型——白色内边距的书脊
        // 在亮度上是一条比两侧更亮的空白带（视频 8：prominence≈0.02）。
        if let gutter = SpreadSplitter.analyzeGutter(inRectified: rectified) {
            outcome.reason = "gutter"
            outcome.spineU = gutter.u
            outcome.prominence = gutter.contrast
            outcome.continuity = gutter.width
            return applySpineSplit(
                index: index,
                quad: quad,
                u: gutter.u,
                prominence: gutter.contrast,
                continuity: gutter.width,
                confidence: gutter.confidence,
                intent: intent,
                source: .gutter,
                outcome: outcome
            )
        }
        outcome.reason = diagnosis.reason.isEmpty ? "noSpine" : diagnosis.reason
        return outcome
    }

    /// 书脊/亮缝共用落地：生成提案；置信度 ≥ 阈值直接应用并压撤销栈。
    private func applySpineSplit(
        index: Int,
        quad: Quad,
        u: Double,
        prominence: Double,
        continuity: Double,
        confidence: Double,
        intent: CaptureIntent,
        source: SplitProposal.Source = .spine,
        outcome: SplitOutcome
    ) -> SplitOutcome {
        var outcome = outcome
        let parts = SpreadSplitter.split(quad, at: u)
        let target: Quad = intent == .leftPage ? parts.left : parts.right
        let proposal = SplitProposal(
            u: u,
            source: source,
            prominence: prominence,
            continuity: continuity,
            confidence: confidence,
            quadBefore: quad,
            quadAfter: target,
            selection: intent == .leftPage ? .left : .right
        )
        outcome.found = true
        if confidence >= SplitProposalConfidence.applyThreshold {
            drafts[index].quad = target
            drafts[index].userAdjustedQuad = true
            splitUndoStack.append(
                SplitUndo(pageID: drafts[index].id, quadBefore: quad, proposal: proposal)
            )
            outcome.applied = true
        } else {
            proposalsByPage[drafts[index].id] = proposal
        }
        ZhixiaLog.reviewSplit(
            proposalU: u,
            source: source.rawValue,
            prominence: prominence,
            continuity: continuity,
            confidence: confidence,
            selection: proposal.selection.rawValue,
            applied: outcome.applied
        )
        return outcome
    }

    /// CF-T005：右页输出意图的折条裁切（单页框形态）。
    ///
    /// 折页书右页常见「右页 + 左侧折起条」，框本身不是整摊（宽高比 <0.95），
    /// 不能走书脊拆分。这里复用 `SpreadSplitter` 的暗折条/亮折条模型，在
    /// 1600px 矫正图上找左缘；高置信直接裁掉，低置信只给预选右页提案。
    /// 左页意图不适用（折条裁切的左侧本来就是左页，不是要输出的右页）。
    private func applyOutputIntentFoldSplit(index: Int, data: Data) -> SplitOutcome {
        var outcome = SplitOutcome()
        guard let image = Self.uprightImage(from: data) else {
            outcome.reason = "noImage"
            return outcome
        }
        let quad = drafts[index].quad
        outcome.aspect = SpreadSplitter.pixelAspect(of: quad, imageSize: image.extent.size)
        guard let rectified = Self.rectifiedImage(
            image,
            quad: quad,
            maxLongestEdge: Self.outputIntentRectifyLongEdge
        ) else {
            outcome.reason = "noRectified"
            return outcome
        }
        let trims = [
            SpreadSplitter.leftFoldTrim(inRectified: rectified),
            SpreadSplitter.leftBrightFoldTrim(inRectified: rectified)
        ].compactMap { $0 }
        guard let trim = trims.first(where: { $0.u >= 0.03 && $0.u <= 0.35 }) else {
            outcome.reason = "noLeftFold"
            return outcome
        }
        let confidence = SplitProposalConfidence.leftFold(stripDepth: trim.stripDepth)
        let target = SpreadSplitter.split(quad, at: trim.u).right
        outcome.trimU = trim.u
        outcome.trimDepth = trim.stripDepth
        outcome.reason = "leftFold"
        outcome.found = true
        let proposal = SplitProposal(
            u: trim.u,
            source: .leftFold,
            prominence: 0,
            continuity: 0,
            confidence: confidence,
            quadBefore: quad,
            quadAfter: target,
            selection: .right
        )
        if confidence >= SplitProposalConfidence.applyThreshold {
            drafts[index].quad = target
            drafts[index].userAdjustedQuad = true
            splitUndoStack.append(
                SplitUndo(pageID: drafts[index].id, quadBefore: quad, proposal: proposal)
            )
            outcome.applied = true
        } else {
            proposalsByPage[drafts[index].id] = proposal
        }
        ZhixiaLog.reviewSplit(
            proposalU: trim.u,
            source: SplitProposal.Source.leftFold.rawValue,
            prominence: 0,
            continuity: 0,
            confidence: confidence,
            selection: proposal.selection.rawValue,
            applied: outcome.applied
        )
        return outcome
    }

    /// 拍后输出意图的高分辨率矫正边长（原图坐标；只用于书脊/折条扫描）。
    private static let outputIntentRectifyLongEdge: CGFloat = 1600

    /// 整理页拍后增强的身份锚定阈值（spec/scan-enhance FR-001）。
    private static let refineIdentityIOU: Double = 0.85

    private struct SplitOutcome {
        var aspect: Double = -1
        var reason = "none"
        /// 是否找到了书脊/亮缝/折条证据（即使置信度不足只给提案也算）。
        var found = false
        var trimU: Double = -1
        var trimDepth: Double = 0
        var spineU: Double = -1
        var prominence: Double = 0
        var continuity: Double = 0
        var applied = false
    }

    /// 拍后裁切（spec/guided-capture T020 / FR-008）：**只生成提案，不写 quad**。
    ///
    /// 两种模型互补（与 spec/scan-enhance FR-002 同一套纯函数）：
    /// 1. **左侧折痕暗条**（场景 2：折起部分是一条暗带）→ 从左侧第一个持续
    ///    明亮列裁掉折条；
    /// 2. **中央书脊暗谷**（场景 1：亮左页的摊开书）→ 沿书脊拆出右页。
    ///
    /// 上一周期这里是**直接改写 `drafts[index].quad`**（静默误裁的来源）；
    /// 现在只产出 `SplitProposal`（可见、可撤销），由用户在 Review 里确认。
    private func makeSplitProposal(index: Int, data: Data) -> SplitOutcome {
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
            let confidence = SplitProposalConfidence.leftFold(stripDepth: trim.stripDepth)
            proposalsByPage[drafts[index].id] = SplitProposal(
                u: trim.u,
                source: .leftFold,
                prominence: 0,
                continuity: 0,
                confidence: confidence,
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: trim.u).right
            )
            return outcome
        }
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        let diagnosis = analysis.diagnosis
        outcome.spineU = diagnosis.bestU
        outcome.prominence = diagnosis.prominence
        outcome.continuity = diagnosis.continuity
        if let spine = analysis.spine {
            outcome.reason = "spine"
            let confidence = SplitProposalConfidence.spine(
                prominence: diagnosis.prominence,
                continuity: diagnosis.continuity
            )
            proposalsByPage[drafts[index].id] = SplitProposal(
                u: spine.u,
                source: .spine,
                prominence: diagnosis.prominence,
                continuity: diagnosis.continuity,
                confidence: confidence,
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: spine.u).right
            )
            return outcome
        }
        if let gutter = SpreadSplitter.analyzeGutter(inRectified: rectified) {
            outcome.reason = "gutter"
            outcome.spineU = gutter.u
            outcome.prominence = gutter.contrast
            outcome.continuity = gutter.width
            proposalsByPage[drafts[index].id] = SplitProposal(
                u: gutter.u,
                source: .gutter,
                prominence: gutter.contrast,
                continuity: gutter.width,
                confidence: gutter.confidence,
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: gutter.u).right
            )
            return outcome
        }
        outcome.reason = diagnosis.reason.isEmpty ? "noSpine" : diagnosis.reason
        return outcome
    }

    /// 现场计算当前页提案的纯函数版本（拆分工具打开时用；不写 quad）。
    private static func makeSplitProposal(quad: Quad, data: Data) -> SplitProposal? {
        guard let image = uprightImage(from: data) else { return nil }
        guard let rectified = rectifiedImage(image, quad: quad) else { return nil }
        if let trim = SpreadSplitter.leftFoldTrim(inRectified: rectified) {
            return SplitProposal(
                u: trim.u,
                source: .leftFold,
                prominence: 0,
                continuity: 0,
                confidence: SplitProposalConfidence.leftFold(stripDepth: trim.stripDepth),
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: trim.u).right
            )
        }
        let analysis = SpreadSplitter.analyzeSpine(inRectified: rectified)
        if let spine = analysis.spine {
            return SplitProposal(
                u: spine.u,
                source: .spine,
                prominence: analysis.diagnosis.prominence,
                continuity: analysis.diagnosis.continuity,
                confidence: SplitProposalConfidence.spine(
                    prominence: analysis.diagnosis.prominence,
                    continuity: analysis.diagnosis.continuity
                ),
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: spine.u).right
            )
        }
        if let gutter = SpreadSplitter.analyzeGutter(inRectified: rectified) {
            return SplitProposal(
                u: gutter.u,
                source: .gutter,
                prominence: gutter.contrast,
                continuity: gutter.width,
                confidence: gutter.confidence,
                quadBefore: quad,
                quadAfter: SpreadSplitter.split(quad, at: gutter.u).right
            )
        }
        return nil
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
