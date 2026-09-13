import Testing
import Foundation

@testable import Zhixia

/// A/B/C 三档切换的行为契约（2026-09-12）。
///
/// 背景：用户反馈「选了 A/B/C 页面没有任何变化」。两个原因：
/// 1. `setTier` 没清 `docxURL` → 导出按钮变成 ShareLink，分享的是旧文件；
/// 2. 预览只渲染结构化块流，**档位根本没接进预览管道** → 画面纹丝不动。
/// 这里锁住第 1 条；第 2 条是 `ReconstructView.preview` 的分档渲染，靠人工验收。
@MainActor
struct ReconstructTierTests {

    private func makeViewModel() -> ReconstructViewModel {
        let documentID = UUID()
        let pageID = UUID()
        let document = ScanDocument(
            id: documentID,
            title: "档位",
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
            enhancement: .original,
            rotationTurns: 0,
            originalRelativePath: "o",
            renderedRelativePath: "r",
            thumbnailRelativePath: "t"
        )
        return ReconstructViewModel(
            document: document,
            scanPages: [page],
            fileStore: FakePagePaths(),
            parser: OnDeviceDocumentParser(recognizer: PreviewRecognizer()),
            docx: DocxExportService(),
            searchablePDF: SearchablePDFExportService()
        )
    }

    @Test("切档必须作废已导出的 docx，否则分享的是旧文件")
    func switchingTierInvalidatesDocx() {
        let viewModel = makeViewModel()
        viewModel.docxURL = URL(fileURLWithPath: "/tmp/old.docx")

        viewModel.setTier(.anchored)
        #expect(viewModel.outputTier == .anchored)
        #expect(viewModel.docxURL == nil)
    }

    @Test("切到当前档位不应作废产物")
    func reselectingSameTierKeepsDocx() {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/keep.docx")
        viewModel.docxURL = url

        viewModel.setTier(.structured)   // 默认就是 A
        #expect(viewModel.docxURL == url)
    }

    @Test("切档不影响 PDF 产物（PDF 导出不区分档位）")
    func switchingTierKeepsPDF() {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/keep.pdf")
        viewModel.pdfURL = url

        viewModel.setTier(.background)
        #expect(viewModel.pdfURL == url)
        #expect(viewModel.docxURL == nil)
    }

    @Test("三档都有中文显示名，且默认 A 档")
    func tiersAreLabelled() {
        #expect(R2OutputTier.allCases.count == 3)
        for tier in R2OutputTier.allCases {
            #expect(tier.displayName.isEmpty == false)
        }
        #expect(makeViewModel().outputTier == .structured)
    }

    /// 2026-09-12：B/C 因「效果很差，没法用」被下架 —— 用户只在 UI 里能看到 A 档。
    /// 三档的**实现**仍在（枚举 3 个 case、导出分档照旧），被下架的只是入口。
    /// 这条测试锁住下架这个决定，避免有人顺手把 `selectable` 改回 `allCases` 而没意识到后果。
    @Test("UI 只暴露 A 档；B/C 的实现保留但不可选")
    func onlyStructuredIsSelectable() {
        #expect(R2OutputTier.selectable == [.structured])
        #expect(R2OutputTier.selectable.count < R2OutputTier.allCases.count)
    }

    @Test("按页访问与拍平块流内容一致（B/C 档按页渲染依赖这一点）")
    func pagesMatchFlattenedBlocks() async {
        let viewModel = makeViewModel()
        await viewModel.reconstruct()

        #expect(viewModel.pages.isEmpty == false)
        let flattened = viewModel.pages.flatMap(\.blocks)
        #expect(flattened.count == viewModel.blocks.count)
    }

    @Test("拿不到页面原图时 pageImageURL 返回 nil，C 档要能退化")
    func pageImageURLIsNilWhenMissing() async {
        let viewModel = makeViewModel()
        await viewModel.reconstruct()
        guard let pageID = viewModel.pages.first?.pageID else {
            Issue.record("还原结果为空，无法验证")
            return
        }
        // FakePagePaths 指向 /tmp/rendered.jpg，文件不存在 → 应返回 nil
        #expect(viewModel.pageImageURL(for: pageID) == nil)
        // 未知 pageID 也要安全返回 nil，不能崩
        #expect(viewModel.pageImageURL(for: UUID()) == nil)
    }
}
