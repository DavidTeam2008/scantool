import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// Phase 2 验证（spec/guided-capture T023 / SC-006）：10 张 fixture 跑拆分提案，
/// 统计三项指标——**0 静默误裁 / 10/10 可修正 / ≥8/10 提案 u 误差 ≤2%**。
///
/// ## fixture 说明
/// 仓库里没有真机采集的整书/折页标注集（本周期真机会话未做），因此这里用
/// **参数化合成图**（中央暗脊 / 左侧暗折条，位置已知）当 fixture：
/// 期望值（书脊/折条位置）由生成参数给出，测的是「提案的 u 误差」与
/// 「是否静默改框」——这两项不依赖真机样本即可判定。真实样本到位后按同
/// 结构补入即可（不改断言）。
@MainActor
struct ReviewSplitCorpusTests {
    /// 一个 fixture：合成图 + 拍摄框 + 期望分割位置。
    private struct Fixture {
        var name: String
        var jpeg: Data
        var quad: Quad
        var expectedU: Double
        var kind: Kind

        enum Kind { case spine, leftFold }
    }

    /// 整页拍摄框（覆盖整图）。
    private static let fullQuad = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// 合成中央暗脊的整书图（脊宽 4%）。
    private static func spineJPEG(spineU: Double) -> Data {
        let width = 400
        let height = 300
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.93, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.25, alpha: 1).setFill()
            let spineWidth = Double(width) * 0.04
            context.fill(
                CGRect(
                    x: spineU * Double(width) - spineWidth / 2,
                    y: 0,
                    width: spineWidth,
                    height: Double(height)
                )
            )
        }
        return image.jpegData(compressionQuality: 0.92)!
    }

    /// 合成左侧暗折条 + 亮页（折条右缘 = 期望裁切位置）。
    private static func foldJPEG(stripU: Double) -> Data {
        let width = 400
        let height = 300
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            let edge = stripU * Double(width)
            context.fill(
                CGRect(x: edge, y: 0, width: Double(width) - edge, height: Double(height))
            )
        }
        return image.jpegData(compressionQuality: 0.92)!
    }

    /// 10 个 fixture：7 个中央暗脊（位置各异）+ 3 个左侧暗折条。
    private static func fixtures() -> [Fixture] {
        var result: [Fixture] = []
        for spineU in [0.42, 0.45, 0.48, 0.50, 0.52, 0.55, 0.58] {
            result.append(
                Fixture(
                    name: String(format: "spine-%.2f", spineU),
                    jpeg: spineJPEG(spineU: spineU),
                    quad: fullQuad,
                    expectedU: spineU,
                    kind: .spine
                )
            )
        }
        for stripU in [0.06, 0.08, 0.10] {
            result.append(
                Fixture(
                    name: String(format: "fold-%.2f", stripU),
                    jpeg: foldJPEG(stripU: stripU),
                    quad: fullQuad,
                    expectedU: stripU,
                    kind: .leftFold
                )
            )
        }
        return result
    }

    private func makeViewModel(fixture: Fixture) async throws -> ReviewViewModel {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "split-corpus-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let page = UUID()
        _ = try await files.writeOriginal(session: session, page: page, data: fixture.jpeg)
        let defaults = UserDefaults(suiteName: "zhixia.split.corpus.\(UUID().uuidString)") ?? .standard
        return ReviewViewModel(
            drafts: [
                PageDraft(
                    id: page,
                    sessionID: session,
                    quad: fixture.quad,
                    enhancement: .original
                )
            ],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: CorpusStillDetector(quad: fixture.quad),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
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

    @Test("10 张 fixture：0 静默误裁、10/10 可修正、≥8/10 提案 u 误差 ≤2%")
    func corpusProposalMetrics() async throws {
        let fixtures = Self.fixtures()
        #expect(fixtures.count == 10)

        var silentCuts = 0
        var correctable = 0
        var withinTolerance = 0
        var lines: [String] = []

        for fixture in fixtures {
            let viewModel = try await makeViewModel(fixture: fixture)
            viewModel.appear()
            #expect(await waitUntil { viewModel.splitProposal != nil })

            // ① 静默误裁：提案生成后，裁切框必须原样。
            if viewModel.drafts.first?.quad != fixture.quad {
                silentCuts += 1
            }

            guard let proposal = viewModel.splitProposal else { continue }

            // ② 可修正：应用 → 撤销 → 回到原框。
            viewModel.applySplit(.right)
            let applied = viewModel.drafts.first?.quad
            viewModel.undoSplit()
            let restored = viewModel.drafts.first?.quad
            if applied != nil, restored == fixture.quad {
                correctable += 1
            }

            // ③ u 误差（相对框宽）。
            let error = abs(proposal.u - fixture.expectedU)
            if error <= 0.02 { withinTolerance += 1 }
            lines.append(
                "\(fixture.name): kind=\(fixture.kind) proposalU=\(String(format: "%.4f", proposal.u)) expectedU=\(String(format: "%.4f", fixture.expectedU)) err=\(String(format: "%.4f", error)) confidence=\(String(format: "%.3f", proposal.confidence))"
            )
        }

        // 基线留档（同时作为 xcresult 附件）。
        let baseline = (["=== ReviewSplit corpus ==="] + lines).joined(separator: "\n")
        print(baseline)
        Attachment.record(baseline, named: "review-split-corpus")

        #expect(silentCuts == 0, "静默误裁必须为 0（SC-006）")
        #expect(correctable == 10, "10/10 可一键修正（SC-006）")
        #expect(withinTolerance >= 8, "≥8/10 提案 u 误差 ≤2%（SC-006），实际 \(withinTolerance)")
    }
}

/// 固定静帧结果检测器（语料用例：静帧候选 = 拍摄框，身份锚定不改变框）。
private actor CorpusStillDetector: EdgeDetecting {
    private let quad: Quad
    init(quad: Quad) { self.quad = quad }
    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { nil }
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { quad }
}
