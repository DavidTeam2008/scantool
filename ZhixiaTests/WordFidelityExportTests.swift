import CoreGraphics
import Foundation
import Testing
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
