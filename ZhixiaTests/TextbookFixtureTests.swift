import Foundation
import ImageIO
import Testing

@testable import Zhixia

/// 真实**双栏教材页**夹具（2026-09-12 用户实拍，`docs/fixtures/images/textbook-columns.jpg`）。
///
/// 为什么单独建一份样张：原先两份夹具（营养表 / 练习册）**都是单栏**，
/// 于是「页面是单栏」这个假设在测试里从来没有被挑战过 —— 而真机崩的恰好就是它。
/// 这一页同时具备两个把旧链路打穿的特征：
/// 1. **左右两栏** → 段落聚类与全局排序会把两栏逐行交错；
/// 2. **正文中嵌了一张照片** → 几何的「空白连通域」区分不了照片和白纸，照片整个丢失。
///
/// ⚠️ 这组测试跑真实的 `RecognizeDocumentsRequest`，因此依赖 Apple 的识别结果。
/// 断言只针对**结构性质**（分了几栏、有没有图、左右顺序），不针对具体文字，
/// 以免 Vision 版本更新就把测试变红。
struct TextbookFixtureTests {

    private func recognize() async -> StructuredDocumentPage? {
        guard #available(iOS 26.0, *) else { return nil }
        let image = ReconstructSampleImage.url("textbook-columns.jpg")
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }
        return await VisionDocumentStructureRecognizer().recognize(imageURL: image, pageID: UUID())
    }

    @Test("真实双栏页必须被切成两栏")
    func realPageSplitsIntoTwoColumns() async throws {
        guard let page = await recognize() else { return }

        let columns = PageColumnSplitter.split(page.lines)
        #expect(columns.count == 2, "没切成两栏（lines=\(page.lines.count)）")
        guard columns.count == 2 else { return }

        // 左边一栏整体在右边一栏的左侧，且各自都有足够多的行
        #expect(columns[0].xRange.upperBound < columns[1].xRange.lowerBound)
        #expect(columns[0].lines.count >= 4)
        #expect(columns[1].lines.count >= 4)
        // 无损：一行都不能丢
        #expect(columns.flatMap(\.lines).count == page.lines.count)
    }

    @Test("真实页里的照片必须被检出（几何通路本来会漏掉它）")
    func realPagePhotoIsFound() async throws {
        guard let page = await recognize() else { return }
        let image = ReconstructSampleImage.url("textbook-columns.jpg")
        let source = try #require(
            CGImageSourceCreateWithURL(image as CFURL, nil)
        )
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let boxes = InkFigureDetector.boxes(.init(image: cgImage, textBoxes: page.lines.map(\.boundingBox)))
        #expect(boxes.isEmpty == false, "照片没有被检出")

        // 照片在右栏的上半部分
        if let photo = boxes.first(where: { $0.midX > 0.5 }) {
            #expect(photo.width > 0.2)
            #expect(photo.height > 0.15)
        } else {
            Issue.record("检出的配图都不在右半边：\(boxes)")
        }
    }

    @Test("端到端：左栏整段排在右栏之前，且照片进了块流")
    func realPageBlocksAreColumnOrdered() async throws {
        guard #available(iOS 26.0, *) else { return }
        let image = ReconstructSampleImage.url("textbook-columns.jpg")
        guard FileManager.default.fileExists(atPath: image.path) else { return }

        let parser = OnDeviceDocumentParser(
            recognizer: EmptyTextRecognizer(),
            structureRecognizer: VisionDocumentStructureRecognizer()
        )
        let page = try await parser.parse(imageURL: image, pageID: UUID(), scene: .plain)

        // 1. 照片进了块流（这是本轮修复的目标）
        let figures = page.blocks.filter { $0.kind == .figure }
        #expect(figures.isEmpty == false, "照片没有进块流")
        if let photo = figures.first(where: { $0.bbox.midX > 0.5 }) {
            #expect(photo.figureRelativePath != nil, "照片没有裁出图片文件")
        }

        // 2. 左右栏不交错：任一栏的块，其中心 x 不应横跨两栏
        let textBlocks = page.blocks.filter { $0.kind == .paragraph || $0.kind == .heading }
        for block in textBlocks {
            let width = block.bbox.width
            #expect(width < 0.6, "有个正文块横跨了大半页宽，八成是左右栏被合在了一起：\(block.text.prefix(40))")
        }

        // 3. 第一段正文来自左栏（左栏先读）
        if let firstBody = textBlocks.first {
            #expect(firstBody.bbox.midX < 0.55, "第一段正文来自右栏，列序反了")
        }
    }
}

private struct EmptyTextRecognizer: TextRecognizing {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: [])
    }
}
