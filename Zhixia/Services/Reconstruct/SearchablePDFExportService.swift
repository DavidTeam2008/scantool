import Foundation
import UIKit

actor SearchablePDFExportService: SearchablePDFRendering {
    func makeSearchablePDF(_ document: ReconstructDocument, fileName: String) async throws -> URL {
        guard document.hasContent else {
            throw ZhixiaError.reconstructFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for (index, page) in document.pages.enumerated() {
                context.beginPage()
                var y: CGFloat = 48
                if document.pages.count > 1 {
                    y = draw(
                        String(localized: "ocr.pageHeader \(index + 1)"),
                        font: .systemFont(ofSize: 12, weight: .semibold),
                        at: y,
                        bounds: bounds
                    )
                    y += 10
                }
                for block in page.blocks {
                    if y > bounds.height - 80 {
                        context.beginPage()
                        y = 48
                    }
                    switch block.kind {
                    case .table:
                        y = drawTable(block.table, at: y, bounds: bounds, context: context)
                        y += 10
                    case .figure, .barcode:
                        y = drawImage(path: block.figureRelativePath, at: y, bounds: bounds, context: context)
                        let caption = block.kind == .barcode
                            ? (block.barcodePayload ?? block.text)
                            : block.text
                        if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            y = draw(caption, font: .systemFont(ofSize: 10), at: y, bounds: bounds)
                            y += 8
                        } else {
                            y += 8
                        }
                    default:
                        let text = block.displayText
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let font: UIFont = block.kind == .heading
                            ? .systemFont(ofSize: 18, weight: .bold)
                            : .systemFont(ofSize: 12, weight: .regular)
                        y = draw(text, font: font, at: y, bounds: bounds)
                        y += block.kind == .heading ? 12 : 8
                    }
                }
            }
        }
        guard !data.isEmpty else {
            throw ZhixiaError.exportFailed
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: fileName)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try data.write(to: output, options: .atomic)
        return output
    }

    private func draw(_ text: String, font: UIFont, at y: CGFloat, bounds: CGRect) -> CGFloat {
        let width = bounds.width - 96
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]
        let box = CGRect(x: 48, y: y, width: width, height: 4000)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width, height: 4000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        (text as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        return y + ceil(measured.height)
    }

    private func drawTable(
        _ table: ReconstructTable?,
        at y: CGFloat,
        bounds: CGRect,
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        guard let table, !table.rows.isEmpty else { return y }
        let columns = max(table.columnCount, 1)
        let width = bounds.width - 96
        let colWidth = width / CGFloat(columns)
        let font = UIFont.systemFont(ofSize: 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]
        var cursor = y
        UIColor.black.setStroke()
        for row in table.rows {
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            let heights = padded.prefix(columns).map { cell in
                ceil((cell as NSString).boundingRect(
                    with: CGSize(width: colWidth - 10, height: 400),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                ).height) + 10
            }
            let rowHeight = max(heights.max() ?? 22, 22)
            if cursor + rowHeight > bounds.height - 48 {
                context.beginPage()
                cursor = 48
            }
            for (index, cell) in padded.prefix(columns).enumerated() {
                let rect = CGRect(x: 48 + CGFloat(index) * colWidth, y: cursor, width: colWidth, height: rowHeight)
                UIBezierPath(rect: rect).stroke()
                (cell as NSString).draw(
                    with: rect.insetBy(dx: 5, dy: 4),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
            }
            cursor += rowHeight
        }
        return cursor
    }

    private func drawImage(
        path: String?,
        at y: CGFloat,
        bounds: CGRect,
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        guard let path, let image = UIImage(contentsOfFile: path), image.size.width > 0 else {
            return y
        }
        let maxWidth = bounds.width - 96
        let maxHeight = min(320, bounds.height - 96)
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        var cursor = y
        if cursor + size.height > bounds.height - 48 {
            context.beginPage()
            cursor = 48
        }
        image.draw(in: CGRect(x: 48, y: cursor, width: size.width, height: size.height))
        return cursor + size.height + 6
    }
}
