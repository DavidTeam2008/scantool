import Testing
import Foundation

@testable import Zhixia

/// 档位切换的行为契约（spec/layout-restore plan D1）。
///
/// 背景（2026-09-12）：用户反馈「选了 A/B/C 页面没有任何变化」。两个原因：
/// 1. `setTier` 没清 `docxURL` → 导出按钮变成 ShareLink，分享的是旧文件；
/// 2. 预览只渲染结构化块流，**档位根本没接进预览管道** → 画面纹丝不动。
/// 这里锁住第 1 条；第 2 条是 `ReconstructView.preview` 的分档渲染，靠人工验收。
///
/// 2026-09-18：档位枚举迁移为 `.restored`（版面还原）+ `.structured`（结构化）两项，
/// 旧 B/C 档（`.anchored`/`.background`）删除；用例随枚举迁移。
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

    /// 2026-09-18 默认档切 `.restored`（plan D1/FR-006）后，"切档"方向随之翻转：
    /// 默认档 → `.structured` 才是真切换。
    @Test("切档必须作废已导出的 docx，否则分享的是旧文件")
    func switchingTierInvalidatesDocx() {
        let viewModel = makeViewModel()
        viewModel.docxURL = URL(fileURLWithPath: "/tmp/old.docx")

        viewModel.setTier(.structured)
        #expect(viewModel.outputTier == .structured)
        #expect(viewModel.docxURL == nil)
    }

    /// 重选默认档 `.restored`（= 当前档）不应作废产物。
    @Test("切到当前档位不应作废产物")
    func reselectingSameTierKeepsDocx() {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/keep.docx")
        viewModel.docxURL = url

        viewModel.setTier(.restored)
        #expect(viewModel.docxURL == url)
    }

    @Test("切档不影响 PDF 产物（PDF 导出不区分档位）")
    func switchingTierKeepsPDF() {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/keep.pdf")
        viewModel.pdfURL = url

        viewModel.setTier(.restored)
        #expect(viewModel.pdfURL == url)
        #expect(viewModel.docxURL == nil)
    }

    @Test("两档都有非空显示名")
    func tiersAreLabelled() {
        #expect(R2OutputTier.allCases.count == 2)
        for tier in R2OutputTier.allCases {
            #expect(tier.displayName.isEmpty == false)
        }
    }

    /// 2026-09-12 B/C 被下架时这条锁住「UI 只暴露 A 档」；
    /// 2026-09-18 版面还原特性落地后（plan D1/FR-006）：`.anchored`/`.background` 删除，
    /// `.restored` + `.structured` 两项**全部可选**，`.restored` 在前。
    @Test("可选档位 = 版面还原 + 结构化，且与全枚举一致")
    func selectableTiersAreRestoredAndStructured() {
        #expect(R2OutputTier.selectable == [.restored, .structured])
        #expect(R2OutputTier.selectable.count == R2OutputTier.allCases.count)
    }

    @Test("按页访问与拍扁块流内容一致（版面还原档按页渲染依赖这一点）")
    func pagesMatchFlattenedBlocks() async {
        let viewModel = makeViewModel()
        await viewModel.reconstruct()

        #expect(viewModel.pages.isEmpty == false)
        let flattened = viewModel.pages.flatMap(\.blocks)
        #expect(flattened.count == viewModel.blocks.count)
    }

    @Test("拿不到页面原图时 pageImageURL 返回 nil，版面还原档要能退化")
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
