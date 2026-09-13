import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

actor PDFExportService: PDFRendering {
    func makePDF(imageURLs: [URL], fileName: String) async throws -> URL {
        let document = PDFDocument()
        // 用 `document.pageCount` 而不是 `enumerated()` 的输入下标。
        // 解码失败的图片会被 `continue` 跳过，输入下标随即与「已插入页数」脱钩，第 0 张缺失时
        // 会向空 PDF 插下标 1 —— 越界。
        // 实测（`ExportSafetyTests.pdfSkipsMissingImageKeepsPageOrder`）：PDFKit 对越界下标做了容忍，表现为追加，
        // 所以这**不是**一个已复现的崩溃，而是一处「依赖未文档化行为」的脆弱点。改成 pageCount
        // 之后不再依赖它，代价为零。
        for url in imageURLs {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                continue
            }
            let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            let pageBounds = Self.fit(pixelSize, into: CGSize(width: 595, height: 842))
            let data = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: pageBounds)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
            else {
                throw ZhixiaError.exportFailed
            }
            context.beginPage(mediaBox: &mediaBox)
            context.draw(cgImage, in: CGRect(origin: .zero, size: pageBounds))
            context.endPage()
            context.closePDF()
            if let pageDocument = PDFDocument(data: data as Data), let page = pageDocument.page(at: 0) {
                document.insert(page, at: document.pageCount)
            }
        }
        guard document.pageCount > 0 else {
            throw ZhixiaError.exportFailed
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: fileName)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        guard document.write(to: output) else {
            throw ZhixiaError.exportFailed
        }
        return output
    }

    private static func fit(_ size: CGSize, into maxSize: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maxSize }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
