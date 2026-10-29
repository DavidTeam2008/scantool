import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// Phase 2 拆分提案（spec/guided-capture T020~T023 / FR-008 / plan D5）。
///
/// 断言锚点（**语义翻转点**）：
/// - 提案**不写 quad**——上一周期这里静默改写（静默误裁的来源）；
/// - 只有 `applySplit` 才写 quad，并置 `userAdjustedQuad = true`；
/// - 整页 / 左页 / 右页三种应用结果正确；可撤销回提案前的框；
/// - 低置信提案同样**不被自动应用**（只降级为虚线提示）；
/// - 引导页（`userAdjustedQuad == true`）不生成提案；
/// - 切页后不跨页复用提案。
@MainActor
struct ReviewSplitProposalTests {
    // MARK: - 辅助

    /// 合成摊开书：400×300，左右亮页 + 中央暗脊（x 0.48..0.52，贯穿全高）。
    private static func spreadJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.93, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.25, alpha: 1).setFill()
            context.fill(CGRect(x: 192, y: 0, width: 16, height: 300))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// 合成折页书：400×300，左侧 8% 暗折条 + 右侧亮页。
    private static func foldStripJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 32, y: 0, width: 368, height: 300))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// 合成「白内边距书脊」：两个文字块之间是一条亮空白带（视频 8 场景）。
    private static func brightGutterJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.18, alpha: 1).setFill()
            for y in stride(from: 16, to: 284, by: 14) {
                context.fill(CGRect(x: 32, y: y, width: 156, height: 4))
                context.fill(CGRect(x: 212, y: y, width: 156, height: 4))
            }
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// 合成无书脊的平坦纸面（输出意图回退安全网用：不得硬拆）。
    private static func flatJPEG() -> Data {
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private static let spreadQuad = Quad(
        topLeft: CGPoint(x: 0.02, y: 0.05),
        topRight: CGPoint(x: 0.98, y: 0.05),
        bottomRight: CGPoint(x: 0.98, y: 0.95),
        bottomLeft: CGPoint(x: 0.02, y: 0.95)
    )

    /// 造一个带原始图的 ReviewViewModel。
    private func makeViewModel(
        jpeg: Data,
        quad: Quad,
        userAdjusted: Bool = false,
        outputIntent: CaptureIntent? = nil,
        quadRole: PageQuadRole? = nil,
        extraPages: [PageDraft] = []
    ) async throws -> (ReviewViewModel, PageFileStore) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "split-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let page = UUID()
        _ = try await files.writeOriginal(session: session, page: page, data: jpeg)
        let defaults = UserDefaults(suiteName: "zhixia.split.\(UUID().uuidString)") ?? .standard
        let drafts = [
            PageDraft(
                id: page,
                sessionID: session,
                quad: quad,
                enhancement: .original,
                userAdjustedQuad: userAdjusted,
                outputIntent: outputIntent,
                quadRole: quadRole
            )
        ] + extraPages
        let viewModel = ReviewViewModel(
            drafts: drafts,
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: FixedStillDetector(quad: quad),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        return (viewModel, files)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - 用例

    @Test("提案不修改 quad；应用后才写 quad 并可撤销")
    func proposalDoesNotWriteQuad() async throws {
        let (viewModel, _) = try await makeViewModel(jpeg: Self.spreadJPEG(), quad: Self.spreadQuad)
        viewModel.appear()
        #expect(await waitUntil { viewModel.splitProposal != nil })

        // 提案生成后，裁切框**保持原样**（静默误裁消失）。
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad)

        let proposal = try #require(viewModel.splitProposal)
        #expect(proposal.source == .spine)
        #expect(proposal.u > 0.42 && proposal.u < 0.58, "分割线应落在书脊 ≈0.5，实际 \(proposal.u)")

        viewModel.applySplit(.right)
        let applied = try #require(viewModel.drafts.first?.quad)
        #expect(applied != Self.spreadQuad, "应用后必须改写 quad")
        #expect(applied.topLeft.x > 0.42 && applied.topLeft.x < 0.58)
        #expect(applied.area < Self.spreadQuad.area * 0.75)
        #expect(viewModel.drafts.first?.userAdjustedQuad == true)
        #expect(viewModel.splitProposal == nil, "应用后提案作废")

        // 撤销 → 回到提案前的框。
        #expect(viewModel.canUndoSplit)
        viewModel.undoSplit()
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad)
    }

    @Test("CF-T005：左页/右页输出意图在高置信书脊上自动落地目标页")
    func outputIntentAutoAppliesHighConfidenceSpine() async throws {
        for intent in [CaptureIntent.leftPage, .rightPage] {
            let (viewModel, _) = try await makeViewModel(
                jpeg: Self.spreadJPEG(),
                quad: Self.spreadQuad,
                outputIntent: intent
            )
            viewModel.appear()
            #expect(await waitUntil { viewModel.drafts.first?.userAdjustedQuad == true })

            let applied = try #require(viewModel.drafts.first?.quad)
            #expect(applied.area < Self.spreadQuad.area * 0.75, "应拆成单页面积")
            #expect(viewModel.splitProposal == nil, "高置信已自动落地，不再留待确认")
            #expect(viewModel.canUndoSplit, "自动落地仍可撤销")
            switch intent {
            case .leftPage:
                #expect(applied.topRight.x > 0.42 && applied.topRight.x < 0.58, "左页右缘应落在书脊")
                #expect(applied.center.x < 0.5)
            case .rightPage:
                #expect(applied.topLeft.x > 0.42 && applied.topLeft.x < 0.58, "右页左缘应落在书脊")
                #expect(applied.center.x > 0.5)
            case .wholePage:
                break
            }

            viewModel.undoSplit()
            #expect(viewModel.drafts.first?.quad == Self.spreadQuad)
        }
    }

    @Test("视频 8 回归：包络拍摄 + 左页意图，亮缝拆分落地左页")
    func envelopeCaptureWithBrightGutterSplitsLeftPage() async throws {
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.brightGutterJPEG(),
            quad: Self.spreadQuad,
            outputIntent: .leftPage,
            quadRole: .envelope
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.drafts.first?.userAdjustedQuad == true })

        let applied = try #require(viewModel.drafts.first?.quad)
        #expect(applied.center.x < Self.spreadQuad.center.x, "成片应是左页，不是整摊")
        #expect(applied.topRight.x > 0.40 && applied.topRight.x < 0.60, "左页右缘应落在亮缝")
        #expect(applied.area < Self.spreadQuad.area * 0.7)
        #expect(viewModel.splitProposal == nil, "高置信亮缝应自动落地")
        #expect(viewModel.canUndoSplit, "自动落地仍可撤销")
    }

    @Test("目标页拍摄 + 左页意图：不二次拆分")
    func targetQuadSkipsSplitForLeftIntent() async throws {
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.brightGutterJPEG(),
            quad: Self.spreadQuad,
            outputIntent: .leftPage,
            quadRole: .target
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.didRefineQuads })
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad, "目标页不得再被拆")
        #expect(viewModel.drafts.first?.userAdjustedQuad == false)
        #expect(viewModel.splitProposal == nil)
    }

    @Test("包络拍摄但没有亮缝/书脊证据：保留包络，不硬拆")
    func envelopeWithoutEvidenceKeepsQuad() async throws {
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.flatJPEG(),
            quad: Self.spreadQuad,
            outputIntent: .leftPage,
            quadRole: .envelope
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.didRefineQuads })
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad)
        #expect(viewModel.drafts.first?.userAdjustedQuad == false)
        #expect(viewModel.splitProposal == nil)
    }

    @Test("CF-T005：没有书脊证据时不硬拆，保留整摊包络")
    func outputIntentFallsBackWithoutSpine() async throws {
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.flatJPEG(),
            quad: Self.spreadQuad,
            outputIntent: .rightPage
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.didRefineQuads })
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad, "无书脊时不得硬拆整摊")
        #expect(viewModel.drafts.first?.userAdjustedQuad == false)
        #expect(viewModel.splitProposal == nil)
    }

    @Test("整页 / 左页 / 右页三种应用结果正确")
    func selectionResults() async throws {
        let (viewModel, _) = try await makeViewModel(jpeg: Self.spreadJPEG(), quad: Self.spreadQuad)
        viewModel.appear()
        #expect(await waitUntil { viewModel.splitProposal != nil })
        let proposal = try #require(viewModel.splitProposal)

        // 右页 = 提案默认结果。
        viewModel.applySplit(.right)
        #expect(viewModel.drafts.first?.quad == proposal.quadAfter)

        // 左页 = 镜像侧。
        viewModel.undoSplit()
        viewModel.applySplit(.left)
        let left = try #require(viewModel.drafts.first?.quad)
        #expect(left.area < Self.spreadQuad.area * 0.75)
        #expect(left.topLeft.x < proposal.u, "左页应在分割线左侧")

        // 整页 = 恢复提案前的框。
        viewModel.undoSplit()
        viewModel.applySplit(.whole)
        #expect(viewModel.drafts.first?.quad == Self.spreadQuad)
    }

    @Test("左折条场景：提案来源 = leftFold，应用后裁掉折条")
    func leftFoldProposal() async throws {
        let captured = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.02),
            topRight: CGPoint(x: 0.98, y: 0.02),
            bottomRight: CGPoint(x: 0.98, y: 0.98),
            bottomLeft: CGPoint(x: 0.02, y: 0.98)
        )
        let (viewModel, _) = try await makeViewModel(jpeg: Self.foldStripJPEG(), quad: captured)
        viewModel.appear()
        #expect(await waitUntil { viewModel.splitProposal != nil })

        #expect(viewModel.drafts.first?.quad == captured, "提案不得静默改写")
        let proposal = try #require(viewModel.splitProposal)
        #expect(proposal.source == .leftFold)

        viewModel.applySplit(.right)
        let applied = try #require(viewModel.drafts.first?.quad)
        #expect(applied.topLeft.x > 0.05 && applied.topLeft.x < 0.15, "折条应被裁掉")
        #expect(applied.area < captured.area * 0.97)
    }

    @Test("CF-T005：右页意图且单页框带折条时，高置信自动裁掉折条")
    func outputIntentRightFoldAutoApplies() async throws {
        // 折页书右页：单页框左缘仍带折起条（宽高比 <0.95，不能走书脊拆分）。
        let captured = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.02),
            topRight: CGPoint(x: 0.62, y: 0.02),
            bottomRight: CGPoint(x: 0.62, y: 0.98),
            bottomLeft: CGPoint(x: 0.02, y: 0.98)
        )
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.foldStripJPEG(),
            quad: captured,
            outputIntent: .rightPage
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.drafts.first?.userAdjustedQuad == true })
        let applied = try #require(viewModel.drafts.first?.quad)
        #expect(applied.topLeft.x > 0.04 && applied.topLeft.x < 0.15, "折条应被裁掉")
        #expect(applied.area < captured.area * 0.97)
        #expect(viewModel.splitProposal == nil)
        #expect(viewModel.canUndoSplit)
    }

    @Test("低置信提案不被自动应用（只降级为提示）")
    func lowConfidenceIsNotAutoApplied() {
        // 置信度公式（D5）：明显不足 → <0.5。
        let confidence = SplitProposalConfidence.spine(prominence: 0.06, continuity: 0.70)
        #expect(confidence < SplitProposalConfidence.applyThreshold)
        #expect(SplitProposalConfidence.leftFold(stripDepth: 0.10) < SplitProposalConfidence.applyThreshold)
        // 高置信（明显书脊）→ ≥0.5。
        #expect(
            SplitProposalConfidence.spine(prominence: 0.15, continuity: 0.95)
                >= SplitProposalConfidence.applyThreshold
        )
        #expect(
            SplitProposalConfidence.leftFold(stripDepth: 0.40)
                >= SplitProposalConfidence.applyThreshold
        )
    }

    @Test("引导页（用户已定框）不生成提案")
    func guidedPageSkipsProposal() async throws {
        let (viewModel, _) = try await makeViewModel(
            jpeg: Self.spreadJPEG(),
            quad: Self.spreadQuad,
            userAdjusted: true
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.previewImage != nil })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(viewModel.splitProposal == nil, "引导框就是用户意图，不再给拆分建议")
    }

    @Test("切页不跨页复用提案")
    func switchingPageClearsProposal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "split-two-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let pageA = UUID()
        let pageB = UUID()
        _ = try await files.writeOriginal(session: session, page: pageA, data: Self.spreadJPEG())
        _ = try await files.writeOriginal(session: session, page: pageB, data: Self.spreadJPEG())
        let defaults = UserDefaults(suiteName: "zhixia.split.two.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [
                PageDraft(id: pageA, sessionID: session, quad: Self.spreadQuad, enhancement: .original),
                // 第二页标成用户已定框 → 不生成提案（用来验证「不跨页复用」）。
                PageDraft(
                    id: pageB,
                    sessionID: session,
                    quad: Self.spreadQuad,
                    enhancement: .original,
                    userAdjustedQuad: true
                )
            ],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: FixedStillDetector(quad: Self.spreadQuad),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        viewModel.appear()
        #expect(await waitUntil { viewModel.splitProposal != nil })

        viewModel.select(index: 1)
        #expect(viewModel.splitProposal == nil, "切到没有提案的页 → 无提案可复用")
    }

    @Test("手动改框 → 提案作废")
    func manualQuadEditClearsProposal() async throws {
        let (viewModel, _) = try await makeViewModel(jpeg: Self.spreadJPEG(), quad: Self.spreadQuad)
        viewModel.appear()
        #expect(await waitUntil { viewModel.splitProposal != nil })

        viewModel.updateQuad(
            Quad(
                topLeft: CGPoint(x: 0.1, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.1),
                bottomRight: CGPoint(x: 0.9, y: 0.9),
                bottomLeft: CGPoint(x: 0.1, y: 0.9)
            )
        )
        #expect(viewModel.splitProposal == nil)
    }
}

/// 固定静帧结果检测器（整理页用例）：live 恒 nil。
private actor FixedStillDetector: EdgeDetecting {
    private let quad: Quad
    init(quad: Quad) { self.quad = quad }
    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { nil }
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { quad }
}
