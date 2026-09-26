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
/// 2026-09-22（wps-parity-layout T006）：默认档从 `.restored` 翻回 `.structured`（流式），
/// 直接断言默认档语义的两条用例按 D8 例外做最小方向翻转，其余零修改。
/// 2026-09-24（wps-parity-layout T021）：US5 行为闭环 —— 默认 flow / 选择持久化
/// （ExportTier.preferenceKey 往返）/ 预览导出同源（同一 outputTier 的两档导出形态）。
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

    /// 2026-09-22 默认档切回 `.structured`（wps-parity-layout plan D1）后，"切档"方向翻转：
    /// 默认档 → `.restored` 才是真切换。
    /// （D8 修改记录：原断言方向 `.structured`→`.restored` 随默认档翻转，仅参数与期望值互换。）
    @Test("切档必须作废已导出的 docx，否则分享的是旧文件")
    func switchingTierInvalidatesDocx() {
        let viewModel = makeViewModel()
        viewModel.docxURL = URL(fileURLWithPath: "/tmp/old.docx")

        viewModel.setTier(.restored)
        #expect(viewModel.outputTier == .restored)
        #expect(viewModel.docxURL == nil)
    }

    /// 重选默认档 `.structured`（= 当前档）不应作废产物。
    /// （D8 修改记录：默认档翻转后，"当前档"从 `.restored` 变为 `.structured`，仅参数互换。）
    @Test("切到当前档位不应作废产物")
    func reselectingSameTierKeepsDocx() {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/keep.docx")
        viewModel.docxURL = url

        viewModel.setTier(.structured)
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

    // MARK: - wps-parity-layout US5 / T021（默认 flow + 选择持久化 + 预览/导出同源）

    /// FR-001/FR-009：默认档 = 流式。`ExportTier`（用户档位，T006）的默认值、
    /// 未设置/空串/非法持久化值的回退，与新 VM 的初始内部档位一致。
    @Test("默认档 = 流式：ExportTier 默认/回退与新 VM 初始档一致")
    func defaultTierIsFlow() {
        #expect(ExportTier.defaultTier == .flow, "FR-001：默认档必须是流式")
        #expect(ExportTier(persistedRawValue: nil) == .flow, "未设置时回退默认档 flow")
        #expect(ExportTier(persistedRawValue: "") == .flow, "空串回退默认档 flow")
        #expect(ExportTier(persistedRawValue: "bogus") == .flow, "非法值回退默认档 flow（老版本数据零破坏）")

        let viewModel = makeViewModel()
        #expect(viewModel.outputTier == .structured, "新 VM 默认 = flow 的内部映射 .structured")
        #expect(
            ExportTier(outputTier: viewModel.outputTier) == .flow,
            "新 VM 初始档反映的用户档位必须是 flow"
        )
    }

    /// 用户档位 ↔ 内部档位（R2OutputTier）↔ 持久化 rawValue 三者互逆 ——
    /// `ReconstructView` 的 @AppStorage 读写与 `.task` 同步（T020）依赖这套映射。
    @Test("档位三重映射互逆：rawValue / outputTier 往返还原")
    func tierMappingsRoundTrip() {
        for tier in ExportTier.allCases {
            #expect(ExportTier(persistedRawValue: tier.rawValue) == tier, "rawValue 往返必须还原")
            #expect(ExportTier(outputTier: tier.outputTier) == tier, "outputTier 反向映射必须互逆")
        }
        #expect(ExportTier.flow.outputTier == .structured)
        #expect(ExportTier.highFidelity.outputTier == .restored)
    }

    /// 切换持久化：`ExportTier.preferenceKey` 经 UserDefaults 往返（@AppStorage
    /// 的底层即 UserDefaults string）；写入还原一致、垃圾值回退默认档。
    @Test("档位选择经 UserDefaults 往返：写入还原一致，垃圾值回退 flow")
    func persistedTierRoundTripsThroughUserDefaults() throws {
        let suiteName = "t021-tier-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 未设置 → 默认 flow（ReconstructView 首次进入页面的读取路径）
        #expect(
            ExportTier(persistedRawValue: defaults.string(forKey: ExportTier.preferenceKey)) == .flow
        )

        // 写入 highFidelity → 还原 highFidelity，预览/导出档 = .restored
        defaults.set(ExportTier.highFidelity.rawValue, forKey: ExportTier.preferenceKey)
        let restored = ExportTier(persistedRawValue: defaults.string(forKey: ExportTier.preferenceKey))
        #expect(restored == .highFidelity)
        #expect(restored.outputTier == .restored)

        // 垃圾值 → 回退 flow（手工改库 / 老版本数据零破坏）
        defaults.set("not-a-tier", forKey: ExportTier.preferenceKey)
        #expect(
            ExportTier(persistedRawValue: defaults.string(forKey: ExportTier.preferenceKey)) == .flow
        )
    }

    /// 预览/导出同源（FR-009）：两者消费同一个 `viewModel.outputTier` ——
    /// 默认流式档的导出是段落流（零浮动文本框）；切高保真后同一次重建的
    /// 导出变为浮动文本框承载**同一段文本**。替身识别器（`PreviewRecognizer`
    /// 单行「房屋租赁合同」）驱动，fake 页面路径无图文件 → 高保真档无底座
    /// 也能发文本框（零 bbox 最小尺寸兜底），正好钉住「同源文本不丢」。
    @Test("预览/导出同源：默认流式导出零文本框，切高保真导出带同文本文本框")
    func previewAndExportShareTierSource() async throws {
        let viewModel = makeViewModel()
        await viewModel.reconstruct()
        #expect(viewModel.hasContent, "替身识别器应产出内容（预览数据源非空）")
        #expect(viewModel.outputTier == .structured, "未持久化选择时预览 = 默认流式档")

        // 默认流式：导出 = 段落流 —— 零浮动文本框，正文携带预览同源文本
        await viewModel.exportDocx()
        let flowURL = try #require(viewModel.docxURL, "流式导出失败：\(viewModel.error?.userMessage ?? "未知错误")")
        defer { try? FileManager.default.removeItem(at: flowURL) }
        let flowXML = try DocxProbe.documentXML(from: flowURL)
        #expect(
            DocxProbe.count(of: "<w:txbxContent>", in: flowXML) == 0,
            "流式档不得混入浮动文本框"
        )
        #expect(flowXML.contains("房屋租赁合同"), "流式档必须携带预览同源文本")

        // 切高保真：预览与导出随档切换（同一 outputTier），导出变文本框承载同一段文本
        viewModel.setTier(.restored)
        #expect(viewModel.docxURL == nil, "切档必须作废既有导出")
        await viewModel.exportDocx()
        let restoredURL = try #require(viewModel.docxURL, "高保真导出失败：\(viewModel.error?.userMessage ?? "未知错误")")
        defer { try? FileManager.default.removeItem(at: restoredURL) }
        let restoredXML = try DocxProbe.documentXML(from: restoredURL)
        #expect(restoredXML.contains("wps:txbx"), "高保真档应由浮动文本框承载文本")
        #expect(restoredXML.contains("房屋租赁合同"), "高保真档必须携带同一段文本（预览/导出同源）")
    }
}
