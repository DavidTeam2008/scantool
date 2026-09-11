import Foundation
import ImageIO

actor DocxExportService: DocxRendering {
    func makeDocx(_ document: ReconstructDocument, fileName: String, tier: R2OutputTier = .structured) async throws -> URL {
        guard document.hasContent else {
            throw ZhixiaError.reconstructFailed
        }
        var media: [(name: String, data: Data)] = []
        var imageRels: [(id: String, target: String)] = []
        var nextImage = 1
        var nextDocPr = 1
        let xml = documentXML(
            document,
            tier: tier,
            media: &media,
            imageRels: &imageRels,
            nextImage: &nextImage,
            nextDocPr: &nextDocPr
        )
        var entries: [(name: String, data: Data)] = [
            (name: "[Content_Types].xml", data: Data(contentTypes(hasPNG: !media.isEmpty).utf8)),
            (name: "_rels/.rels", data: Data(Self.rootRels.utf8)),
            (name: "word/_rels/document.xml.rels", data: Data(documentRels(imageRels).utf8)),
            (name: "word/styles.xml", data: Data(Self.styles.utf8)),
            (name: "word/document.xml", data: Data(xml.utf8))
        ]
        entries.append(contentsOf: media)
        let zip = ZipArchive.data(entries: entries)
        let output = FileManager.default.temporaryDirectory
            .appending(path: "Zhixia", directoryHint: .isDirectory)
            .appending(path: fileName)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try zip.write(to: output, options: .atomic)
        return output
    }

    private func documentXML(
        _ document: ReconstructDocument,
        tier: R2OutputTier,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String {
        var body = ""
        // C 档：把每页最大可用图（或原图）作为 behindDoc 衬底
        if tier == .background {
            for page in document.pages {
                if let bg = backgroundDrawingXML(
                    page: page,
                    media: &media,
                    imageRels: &imageRels,
                    nextImage: &nextImage,
                    nextDocPr: &nextDocPr
                ) {
                    body += bg
                }
            }
        }
        for (index, page) in document.pages.enumerated() {
            if document.pages.count > 1 {
                body += paragraphXML(
                    String(localized: "ocr.pageHeader \(index + 1)"),
                    style: "Heading2",
                    bold: true,
                    size: 28
                )
            }
            for block in page.blocks {
                switch block.kind {
                case .heading:
                    body += paragraphXML(block.text, style: "Heading1", bold: true, size: 36)
                case .table:
                    body += tableXML(block.table) ?? paragraphXML(block.displayText, style: "Normal", bold: false, size: 24)
                case .figure, .barcode:
                    // B 档：用 anchor 浮于页面相应位置；A/C 档走 inline
                    let useAnchor = (tier == .anchored) && block.bbox != .zero
                    if let drawing = imageDrawingXML(
                        path: block.figureRelativePath,
                        anchor: useAnchor ? block.bbox : nil,
                        media: &media,
                        imageRels: &imageRels,
                        nextImage: &nextImage,
                        nextDocPr: &nextDocPr
                    ) {
                        body += drawing
                    }
                    let caption = block.kind == .barcode
                        ? (block.barcodePayload ?? block.text)
                        : block.text
                    if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body += paragraphXML(caption, style: "Normal", bold: false, size: 20)
                    }
                default:
                    body += paragraphXML(block.text, style: "Normal", bold: block.style.isBold, size: 24)
                }
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <w:body>
        \(body)
            <w:sectPr>
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
    }

    private func paragraphXML(_ text: String, style: String, bold: Bool, size: Int) -> String {
        let runs = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let boldXML = bold ? "<w:b/>" : ""
            return """
                  <w:r>
                    <w:rPr>\(boldXML)<w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
                    <w:t xml:space="preserve">\(escape(String(line)))</w:t>
                  </w:r>
            """
        }.joined(separator: "\n                  <w:r><w:br/></w:r>\n")
        return """
            <w:p>
              <w:pPr><w:pStyle w:val="\(style)"/></w:pPr>
        \(runs)
            </w:p>

        """
    }

    private func tableXML(_ table: ReconstructTable?) -> String? {
        guard let table, !table.rows.isEmpty else { return nil }
        let columns = max(table.columnCount, 1)
        let width = max(9000 / columns, 1200)
        let rows = table.rows.map { row in
            let padded = row + Array(repeating: "", count: max(0, columns - row.count))
            let cells = padded.prefix(columns).map { cell in
                """
                      <w:tc>
                        <w:tcPr><w:tcW w:w="\(width)" w:type="dxa"/></w:tcPr>
                        <w:p><w:r><w:t xml:space="preserve">\(escape(cell))</w:t></w:r></w:p>
                      </w:tc>
                """
            }.joined()
            return "                    <w:tr>\n\(cells)\n                    </w:tr>"
        }.joined(separator: "\n")
        return """
            <w:tbl>
              <w:tblPr>
                <w:tblW w:w="0" w:type="auto"/>
                <w:tblBorders>
                  <w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:insideH w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                  <w:insideV w:val="single" w:sz="4" w:space="0" w:color="000000"/>
                </w:tblBorders>
              </w:tblPr>
        \(rows)
            </w:tbl>

        """
    }

    private func imageDrawingXML(
        path: String?,
        anchor: CGRect? = nil,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return nil
        }
        let index = nextImage
        nextImage += 1
        let docPr = nextDocPr
        nextDocPr += 1
        let fileName = "image\(index).png"
        media.append((name: "word/media/\(fileName)", data: data))
        let relID = "rId\(index + 1)"
        imageRels.append((id: relID, target: "media/\(fileName)"))
        let size = pixelSize(of: data) ?? (width: 400, height: 300)
        let (cx, cy) = emus(width: size.width, height: size.height)
        // A 档走 inline；B 档走 anchor 浮于页面 anchor bbox
        if let anchor, anchor != .zero {
            return anchoredDrawingXML(anchor: anchor, cx: cx, cy: cy, docPr: docPr, fileName: fileName, relID: relID)
        }
        return """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0">
                    <wp:extent cx="\(cx)" cy="\(cy)"/>
                    <wp:effectExtent l="0" t="0" r="0" b="0"/>
                    <wp:docPr id="\(docPr)" name="Picture \(docPr)"/>
                    <wp:cNvGraphicFramePr>
                      <a:graphicFrameLocks noChangeAspect="1"/>
                    </wp:cNvGraphicFramePr>
                    <a:graphic>
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic>
                          <pic:nvPicPr>
                            <pic:cNvPr id="0" name="\(fileName)"/>
                            <pic:cNvPicPr/>
                          </pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="\(relID)"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm>
                              <a:off x="0" y="0"/>
                              <a:ext cx="\(cx)" cy="\(cy)"/>
                            </a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:inline>
                </w:drawing>
              </w:r>
            </w:p>

        """
    }

    /// B 档：把图按 anchor.bbox 浮于页面对应位置（dxa = EMU/635，1 in = 1440 dxa）。
    /// Vision 坐标是归一化 0~1，page 是 A4 默认 11906×16838 dxa。
    private func anchoredDrawingXML(
        anchor: CGRect,
        cx: Int64,
        cy: Int64,
        docPr: Int,
        fileName: String,
        relID: String
    ) -> String {
        let pageWidth: Double = 11906
        let pageHeight: Double = 16838
        let posX = Int64((anchor.minX) * pageWidth)
        let posY = Int64((1.0 - anchor.maxY) * pageHeight)  // Vision y 翻转
        let sizeX = min(cx, Int64(anchor.width * pageWidth))
        let sizeY = min(cy, Int64(anchor.height * pageHeight))
        return """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:anchor distT="0" distB="0" distL="114300" distR="114300"
                             simplePos="0" relativeHeight="\(docPr)" behindDoc="0"
                             locked="0" layoutInCell="1" allowOverlap="1">
                    <wp:simplePos x="0" y="0"/>
                    <wp:positionH relativeFrom="page"><wp:posOffset>\(posX)</wp:posOffset></wp:positionH>
                    <wp:positionV relativeFrom="page"><wp:posOffset>\(posY)</wp:posOffset></wp:positionV>
                    <wp:extent cx="\(sizeX)" cy="\(sizeY)"/>
                    <wp:effectExtent l="0" t="0" r="0" b="0"/>
                    <wp:docPr id="\(docPr)" name="Picture \(docPr)"/>
                    <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
                    <a:graphic>
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic>
                          <pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="\(relID)"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm>
                              <a:off x="0" y="0"/>
                              <a:ext cx="\(sizeX)" cy="\(sizeY)"/>
                            </a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:anchor>
                </w:drawing>
              </w:r>
            </w:p>

        """
    }

    /// C 档：把页面最大图（或原图）作为 behindDoc 衬底。
    /// 当前样张没有原图缓存，先用最大 figure 替代；以后接 `originalImageRelativePath` 即可换源。
    private func backgroundDrawingXML(
        page: ReconstructPage,
        media: inout [(name: String, data: Data)],
        imageRels: inout [(id: String, target: String)],
        nextImage: inout Int,
        nextDocPr: inout Int
    ) -> String? {
        // 找 page 中面积最大的 figure/barcode
        let candidates = page.blocks.filter { $0.kind == .figure || $0.kind == .barcode }
        let best = candidates.max { lhs, rhs in
            (lhs.bbox.width * lhs.bbox.height) < (rhs.bbox.width * rhs.bbox.height)
        }
        guard let best, let path = best.figureRelativePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty
        else {
            return nil
        }
        let size = pixelSize(of: data) ?? (width: 11906, height: 16838)
        // 把图压成页面大小（full page A4）
        let (cx, cy) = emus(width: size.width, height: size.height)
        let fullCx = Int64(5_486_400)  // A4 宽 8.5 in
        let fullCy = Int64(7_315_200)  // A4 高 11 in
        let scaleX = Double(fullCx) / Double(cx)
        let scaleY = Double(fullCy) / Double(cy)
        let scale = min(scaleX, scaleY)
        let finalCx = Int64(Double(cx) * scale)
        let finalCy = Int64(Double(cy) * scale)
        let index = nextImage
        nextImage += 1
        let docPr = nextDocPr
        nextDocPr += 1
        let fileName = "bg\(index).png"
        media.append((name: "word/media/\(fileName)", data: data))
        let relID = "rId\(index + 1)"
        imageRels.append((id: relID, target: "media/\(fileName)"))
        return """
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:anchor distT="0" distB="0" distL="0" distR="0"
                             simplePos="0" relativeHeight="\(docPr)" behindDoc="1"
                             locked="0" layoutInCell="1" allowOverlap="1">
                    <wp:simplePos x="0" y="0"/>
                    <wp:positionH relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionH>
                    <wp:positionV relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionV>
                    <wp:extent cx="\(finalCx)" cy="\(finalCy)"/>
                    <wp:effectExtent l="0" t="0" r="0" b="0"/>
                    <wp:docPr id="\(docPr)" name="Background \(docPr)"/>
                    <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="0"/></wp:cNvGraphicFramePr>
                    <a:graphic>
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic>
                          <pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="\(relID)"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm>
                              <a:off x="0" y="0"/>
                              <a:ext cx="\(finalCx)" cy="\(finalCy)"/>
                            </a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:anchor>
                </w:drawing>
              </w:r>
            </w:p>

        """
    }

    private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    private func emus(width: Int, height: Int) -> (Int64, Int64) {
        let maxWidth: Double = 5_486_400
        let maxHeight: Double = 7_315_200
        var w = Double(max(width, 1)) * 9525
        var h = Double(max(height, 1)) * 9525
        let scale = min(maxWidth / w, maxHeight / h, 1)
        w *= scale
        h *= scale
        return (Int64(w.rounded()), Int64(h.rounded()))
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func contentTypes(hasPNG: Bool) -> String {
        let png = hasPNG
            ? "\n      <Default Extension=\"png\" ContentType=\"image/png\"/>"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>\(png)
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private func documentRels(_ imageRels: [(id: String, target: String)]) -> String {
        let extras = imageRels.map { rel in
            """
              <Relationship Id="\(rel.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(rel.target)"/>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \(extras)
        </Relationships>
        """
    }

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/>
        <w:qFormat/>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading1">
        <w:name w:val="heading 1"/>
        <w:basedOn w:val="Normal"/>
        <w:qFormat/>
        <w:pPr><w:outlineLvl w:val="0"/></w:pPr>
        <w:rPr><w:b/><w:sz w:val="36"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading2">
        <w:name w:val="heading 2"/>
        <w:basedOn w:val="Normal"/>
        <w:qFormat/>
        <w:pPr><w:outlineLvl w:val="1"/></w:pPr>
        <w:rPr><w:b/><w:sz w:val="28"/></w:rPr>
      </w:style>
    </w:styles>
    """
}
