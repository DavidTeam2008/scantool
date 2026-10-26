import CoreGraphics
import Testing
@testable import Zhixia

struct PageCropSafetyTests {
    private static func page(_ rows: [[String]]?) -> StructuredDocumentPage {
        let tables = rows.map {
            [DetectedTable(
                table: ReconstructTable(rows: $0, columnRatios: nil),
                bbox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
            )]
        } ?? []
        return StructuredDocumentPage(
            lines: [],
            tables: tables,
            barcodes: [],
            source: .documentRequest
        )
    }

    @Test("原页无表时裁切安全")
    func noTableIsSafe() {
        #expect(PageCropSafety.isSafe(original: Self.page(nil), cropped: Self.page(nil)))
    }

    @Test("裁切丢失表格时拒绝")
    func lostTableIsUnsafe() {
        let original = Self.page([["a", "b"], ["c", "d"]])
        #expect(!PageCropSafety.isSafe(original: original, cropped: Self.page(nil)))
    }

    @Test("行列一致且文本一致时安全；文本变化时拒绝")
    func sameShapeAndText() {
        let original = Self.page([["a", "b"], ["c", "d"]])
        let same = Self.page([["a", "b"], ["c", "d"]])
        let changed = Self.page([["a", "b"], ["c", "x"]])
        #expect(PageCropSafety.isSafe(original: original, cropped: same))
        #expect(!PageCropSafety.isSafe(original: original, cropped: changed))
    }

    @Test("页级左缘内收：表格在裁切线右侧时几何安全")
    func geometryClearOfLeftInset() {
        let page = Self.page([["a", "b"], ["c", "d"]])
        #expect(PageCropSafety.tablesClear(ofLeftFraction: 0.01, in: page))
        #expect(PageCropSafety.tablesClear(ofLeftFraction: 0.09, in: page))
        #expect(!PageCropSafety.tablesClear(ofLeftFraction: 0.1, in: page))
        #expect(!PageCropSafety.tablesClear(ofLeftFraction: 0.01, in: Self.page(nil)))
        #expect(!PageCropSafety.tablesClear(ofLeftFraction: 0, in: page))
    }

    @Test("整体裁切：表格 bbox 在裁切框内才几何安全（含 y 翻轴）")
    func geometryClearOfCropRect() {
        let page = Self.page([["a", "b"], ["c", "d"]])
        // 页面夹具 table bbox = (0.1,0.1,0.8,0.5)，Vision 左下原点，
        // 转成左上后为 y=0.4...0.9。
        #expect(
            PageCropSafety.tablesClear(
                of: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.6),
                in: page
            )
        )
        #expect(
            !PageCropSafety.tablesClear(
                of: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.5),
                in: page
            )
        )
        #expect(!PageCropSafety.tablesClear(of: .init(x: 0, y: 0, width: 1, height: 1), in: Self.page(nil)))
    }
}
