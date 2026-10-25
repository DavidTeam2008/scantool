import CoreGraphics
import Foundation
import Testing
import SwiftUI
import UIKit

@testable import Zhixia

/// Word 导出保真度（spec/word-fidelity T001/T002/T003 / FR-002、FR-005）。
///
/// ## 夹具
/// `docs/media/IMG_7544.jpg`——真实拍摄的**教科书右页**（横幅标题 / 圆角提示框 /
/// 深色表头表格 / 双栏编号列表 / 灰底词框 / 照片 / 页码 / 页脚），是「稍微复杂
/// 一点的图片内容」的典型样本。
///
/// ## 断言锚点
/// ① **裁切不丢页**（T001）：静帧检测要么给出**页面**，要么**不裁**（整图当页面），
///    绝不能落到页面里的表格/色块/底边条（用户实测「只识别了右页的一部分」）；
/// ② **图片版结构**（T002）：`.pageImage` 档的 docx = 每页一张铺满页面的图，
///    **零浮动文本框 / 零 mask**（样式不可能乱）；
/// ③ **可编辑档不回归**（T022）：`.restored` 档结构不变（既有断言零修改）。
///
/// ## 端到端保真度
/// 本测试把「页面图 + 两种 docx」写到 `build/word-fidelity/`，由
/// `Tools/word-fidelity/check.sh` 渲染成图并算 SSIM（宿主侧：qlmanage 渲染 +
/// ffmpeg SSIM）——见 `make word-fidelity`。
@MainActor
@Suite(.serialized)
struct WordFidelityExportTests {
    /// 仓库根（测试跑在模拟器里，宿主机文件系统可读/可写）。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var outputDirectory: URL {
        repoRoot.appending(path: "build/word-fidelity")
    }

    static var sourceImageURL: URL {
        repoRoot.appending(path: "docs/media/IMG_7544.jpg")
    }

    /// 夹具：整页照片 → 页面图（透视矫正 + 增强）。
    struct Fixture {
        var pageImageURL: URL
        var pixelSize: CGSize
        var detectedQuad: Quad?
    }

    /// 走一遍 App 的真实链路：静帧检测 → 裁切 → 增强 → 页面图。
    static func makeFixture() async throws -> Fixture {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let source = sourceImageURL
        let data = try Data(contentsOf: source)

        // ① 静帧检测（相册导入路径用的就是它）。
        let detector = VisionEdgeDetector()
        let quad = await detector.detect(imageData: data, idCardWindow: nil)

        // ② 裁切 + 增强 = App 落盘的 rendered 页（`ImagePipeline.renderPage`）。
        let pipeline = ImagePipeline()
        let corrected = try await pipeline.correct(
            original: source,
            quad: quad ?? .fullImage,
            rotationTurns: 0
        )
        let enhanced = try await pipeline.apply(imageData: corrected, enhancement: .enhance)
        let pageImageURL = outputDirectory.appending(path: "page.jpg")
        try enhanced.write(to: pageImageURL)

        let image = try #require(UIImage(data: enhanced))
        return Fixture(
            pageImageURL: pageImageURL,
            pixelSize: image.size,
            detectedQuad: quad
        )
    }

    /// 造一个可导出的文档（页面图 + 识别块）。
    static func makeDocument(fixture: Fixture) async throws -> ReconstructDocument {
        let parser = OnDeviceDocumentParser(recognizer: FixedLineRecognizer())
        let page = try await parser.parse(
            imageURL: fixture.pageImageURL,
            pageID: UUID(),
            scene: .auto
        )
        return ReconstructDocument(
            documentID: UUID(),
            title: "word-fidelity",
            pages: [
                ReconstructPage(
                    pageID: page.pageID,
                    size: fixture.pixelSize,
                    scene: page.scene,
                    usedCloud: false,
                    blocks: page.blocks,
                    baseImageRelativePath: fixture.pageImageURL.path
                )
            ]
        )
    }


    /// 真 OCR 文档（**不是** `FixedLineRecognizer` 的单行夹具）：走 App 的
    /// `VisionTextRecognizer` + iOS 26 `VisionDocumentStructureRecognizer`，
    /// 与真机「相册导入 → 版面还原」同一识别链路。用于钉住真实字号/表格/遮罩，
    /// 防止自动门限被单行假夹具的 0.96 误判为通过。
    static func makeRealDocument(fixture: Fixture) async throws -> ReconstructDocument {
        let parser = OnDeviceDocumentParser(
            recognizer: VisionTextRecognizer(),
            structureRecognizer: VisionDocumentStructureRecognizer()
        )
        let page = try await parser.parse(
            imageURL: fixture.pageImageURL,
            pageID: UUID(),
            scene: .auto
        )
        return ReconstructDocument(
            documentID: UUID(),
            title: "word-fidelity-real",
            pages: [
                ReconstructPage(
                    pageID: page.pageID,
                    size: fixture.pixelSize,
                    scene: page.scene,
                    usedCloud: false,
                    blocks: page.blocks,
                    baseImageRelativePath: fixture.pageImageURL.path
                )
            ]
        )
    }

    @Test("T001 静帧检测不裁到页面里的子框（给页面框或整图，绝不给表格/底边条）")
    func stillDetectionNeverCropsToSubRegion() async throws {
        let fixture = try await Self.makeFixture()
        guard let quad = fixture.detectedQuad else {
            // 认不出页面 → 不裁（整图当页面）：调用方回退 `.fullImage`，内容不丢。
            return
        }
        // 给了框，它必须是**页面级**的框（覆盖画面 ≥ 50%），不是页面里的
        // 表格（0.098）/ 底边条（0.250）这类子框。
        #expect(quad.area > 0.5, "静帧框必须是页面级（≥50% 画面），实际 \(quad.area)")
    }

    @Test("T002 图片版 docx = 每页一张铺满页面的图（零文本框 / 零 mask）")
    func pageImageTierIsPurePageImage() async throws {
        let fixture = try await Self.makeFixture()
        let document = try await Self.makeDocument(fixture: fixture)
        let service = DocxExportService()
        let url = try await service.makeDocx(
            document,
            fileName: "word-fidelity-pageimage.docx",
            tier: .pageImage
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        // 页面图 = **内联图**铺页（inline = OOXML 最基础构造，Word / Pages /
        // QuickLook / LibreOffice 一致支持；锚定图在部分预览器上不落图）。
        #expect(xml.contains("<wp:inline"), "图片版必须用内联图铺页")
        #expect(xml.contains("pic:pic"), "图片版必须内嵌图片")
        // 零浮动文本框 / 零 mask（样式不可能乱）
        #expect(!xml.contains("txbxContent"), "图片版不得混入浮动文本框")
        #expect(!xml.contains("wps:wsp"), "图片版不得混入 mask 覆盖层")
        #expect(!xml.contains("<wp:anchor"), "图片版不得混入锚定对象")
        // 页边距全 0（图片铺满）
        #expect(xml.contains("w:top=\"0\"") && xml.contains("w:left=\"0\""))
    }

    @Test("T003 可编辑档（版面还原）结构不变：仍有浮动文本框承载文本")
    func restoredTierStillCarriesText() async throws {
        let fixture = try await Self.makeFixture()
        let document = try await Self.makeDocument(fixture: fixture)
        let service = DocxExportService()
        let url = try await service.makeDocx(
            document,
            fileName: "word-fidelity-restored.docx",
            tier: .restored
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = try DocxProbe.documentXML(from: url)
        #expect(xml.contains("wps:txbx"), "版面还原档仍应使用浮动文本框")
    }

    @Test("T010 导出模型离屏渲染（App 侧真值：预览 == 导出模型，与渲染器无关）")
    func rendersExportModelOffscreen() async throws {
        let fixture = try await Self.makeFixture()
        let document = try await Self.makeDocument(fixture: fixture)
        guard let page = document.pages.first else {
            Issue.record("文档缺页")
            return
        }
        // ① 版面还原档的模型渲染：底图 + 净化遮罩 + 浮动文本框（与导出一一对应，
        //    坐标映射同源 `PageLayoutMapper`）——**不依赖任何外部渲染器**。
        let restoredImage = Self.renderOffscreen(
            LayoutCanvas(
                page: page,
                backgroundImageURL: fixture.pageImageURL
            )
        )
        let restoredURL = Self.outputDirectory.appending(path: "preview-restored.png")
        try restoredImage.pngData()?.write(to: restoredURL)

        // ② 图片版的模型渲染：整页图（即导出产物本身）。
        let pageImage = Self.renderOffscreen(
            PageImageCanvas(
                page: page,
                backgroundImageURL: fixture.pageImageURL
            )
        )
        let pageImageURL = Self.outputDirectory.appending(path: "preview-pageimage.png")
        try pageImage.pngData()?.write(to: pageImageURL)

        #expect(restoredImage.size.width > 0, "还原档模型必须渲染出内容")
        #expect(pageImage.size.width > 0, "图片版模型必须渲染出内容")
    }

    /// 离屏渲染一个 SwiftUI 视图（`ImageRenderer`）。
    private static func renderOffscreen<V: View>(_ view: V, width: CGFloat = 1000) -> UIImage {
        let renderer = ImageRenderer(
            content: view.frame(width: width).background(Color.white)
        )
        renderer.scale = 1
        return renderer.uiImage ?? UIImage()
    }


    @Test("T004 真 OCR 回归：真实样张导出可编辑档（供宿主 WPS/QuickLook 比对）")
    func realOCRExportArtifact() async throws {
        let fixture = try await Self.makeFixture()
        let document = try await Self.makeRealDocument(fixture: fixture)
        let page = try #require(document.pages.first)
        let kinds = page.blocks.map { "\($0.kind)" }.joined(separator: ",")
        let structure = await VisionDocumentStructureRecognizer().recognize(
            imageURL: fixture.pageImageURL,
            pageID: UUID()
        )
        #expect(
            page.blocks.contains { $0.kind == .table },
            "真 OCR 应识别出表格；blocks=[\(kinds)] structureTables=\(structure?.tables.count ?? -1) structureLines=\(structure?.lines.count ?? -1)"
        )
        let table = try #require(page.blocks.first { $0.kind == .table }?.table)
        #expect(table.rows.count >= 2, "真 OCR 表格应有至少两行")
        #expect(
            page.blocks.contains { !$0.text.isEmpty && $0.kind != .table },
            "真 OCR 应识别出正文块"
        )
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "word-fidelity-restored-real.docx",
            tier: .restored
        )
        let destination = Self.outputDirectory.appending(path: "out-restored-real.docx")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        let xml = try DocxProbe.documentXML(from: destination)
        #expect(xml.contains("TableBox"), "正文页表格应进 TableBox（WPS 单页约束）")
        #expect(xml.contains("textAlignment w:val=\"center\""), "底图承载段应带 textAlignment=center")
    }


    @Test("T005 真实 UI 底图回归：用验收产物 original-base.jpg 重跑结构识别")
    func realUIBaseExportArtifact() async throws {
        let base = Self.repoRoot.appending(path: "build/word-fidelity/experiments/acceptance-media/original-base.jpg")
        guard FileManager.default.fileExists(atPath: base.path),
              let image = UIImage(contentsOfFile: base.path) else {
            Issue.record("缺少真实 UI 底图：\(base.path)")
            return
        }
        let parser = OnDeviceDocumentParser(
            recognizer: VisionTextRecognizer(),
            structureRecognizer: VisionDocumentStructureRecognizer()
        )
        let page = try await parser.parse(imageURL: base, pageID: UUID(), scene: .auto)
        let kinds = page.blocks.map { "\($0.kind)" }.joined(separator: ",")
        let debugURL = Self.outputDirectory.appending(path: "realbase-page.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(page) {
            try? data.write(to: debugURL)
        }
        if let cg = image.cgImage {
            let mask = LayoutMaskBuilder.build(
                blocks: page.restoredBlocks ?? page.blocks,
                baseImage: cg,
                granularity: .line
            )
            struct FillDump: Encodable {
                let x: Double
                let y: Double
                let width: Double
                let height: Double
                let red: UInt8
                let green: UInt8
                let blue: UInt8
            }
            let fills = mask.fills.map {
                FillDump(
                    x: $0.rect.minX, y: $0.rect.minY,
                    width: $0.rect.width, height: $0.rect.height,
                    red: $0.red, green: $0.green, blue: $0.blue
                )
            }
            if let data = try? encoder.encode(fills) {
                try? data.write(to: Self.outputDirectory.appending(path: "realbase-mask-line.json"))
            }
        }
        let table = page.blocks.first { $0.kind == .table && $0.table?.rows.isEmpty == false }
        #expect(table != nil, "真实 UI 底图应识别出表格；blocks=[\(kinds)]")
        let document = ReconstructDocument(
            documentID: UUID(),
            title: "word-fidelity-realbase",
            pages: [
                ReconstructPage(
                    pageID: page.pageID,
                    size: image.size,
                    scene: page.scene,
                    usedCloud: false,
                    blocks: page.blocks,
                    layout: page.layout,
                    baseImageRelativePath: base.path,
                    restoredBlocks: page.restoredBlocks
                )
            ]
        )
        let url = try await DocxExportService().makeDocx(
            document,
            fileName: "word-fidelity-restored-realbase.docx",
            tier: .restored
        )
        let destination = Self.outputDirectory.appending(path: "out-restored-realbase.docx")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    @Test("T003 端到端产物落盘（供 make word-fidelity 渲染比对）")
    func exportsArtifactsForHostSideComparison() async throws {
        let fixture = try await Self.makeFixture()
        let document = try await Self.makeDocument(fixture: fixture)
        let service = DocxExportService()
        for (tier, name) in [(R2OutputTier.pageImage, "out-pageimage.docx"), (.restored, "out-restored.docx")] {
            let url = try await service.makeDocx(document, fileName: name, tier: tier)
            let destination = Self.outputDirectory.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        // 参考图（原图）也复制一份，宿主侧脚本同目录取用。
        let reference = Self.outputDirectory.appending(path: "reference.jpg")
        try? FileManager.default.removeItem(at: reference)
        try FileManager.default.copyItem(at: Self.sourceImageURL, to: reference)
    }
}

/// 固定单行识别器（结构断言用，不依赖模拟器 Vision 质量）。
private struct FixedLineRecognizer: TextRecognizing {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(
            pageID: pageID,
            lines: [
                OCRLine(
                    text: "Writing Part 2",
                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.06)
                )
            ]
        )
    }
}
