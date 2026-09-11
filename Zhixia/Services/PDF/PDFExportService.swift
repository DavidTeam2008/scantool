import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

actor PDFExportService: PDFRendering {
    func makePDF(imageURLs: [URL], fileName: String) async throws -> URL {
        let document = PDFDocument()
        for (index, url) in imageURLs.enumerated() {
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
                document.insert(page, at: index)
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
