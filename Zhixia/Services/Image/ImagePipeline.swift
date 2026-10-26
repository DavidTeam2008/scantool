import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

actor ImagePipeline: PerspectiveCorrecting, Enhancing, Thumbnailing, ImageRendering {
    private let context: CIContext
    private let maxLongestEdge: CGFloat

    init(maxLongestEdge: CGFloat = 2200) {
        self.maxLongestEdge = maxLongestEdge
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context = CIContext(options: [
            .workingColorSpace: space,
            .useSoftwareRenderer: false
        ])
    }

    func correct(original: URL, quad: Quad, rotationTurns: Int) async throws -> Data {
        let image = try loadUpright(url: original)
        let corrected = try perspectiveCorrect(image, quad: quad)
        let rotated = rotate(corrected, turns: rotationTurns)
        return try jpegData(from: rotated, quality: 0.9)
    }

    func apply(imageData: Data, enhancement: Enhancement) async throws -> Data {
        guard let image = CIImage(data: imageData) else {
            throw ZhixiaError.perspectiveFailed
        }
        let filtered = applyRecipe(image, enhancement: enhancement)
        return try jpegData(from: filtered, quality: 0.82)
    }

    func makeThumbnail(imageData: Data, maxWidth: CGFloat) async throws -> Data {
        guard let image = CIImage(data: imageData) else {
            throw ZhixiaError.perspectiveFailed
        }
        let width = image.extent.width
        guard width > 0 else { throw ZhixiaError.perspectiveFailed }
        let scale = min(1, maxWidth / width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try jpegData(from: scaled, quality: 0.7)
    }

    func renderPage(original: URL, draft: PageDraft) async throws -> RenderedPageData {
        // P0 页面预处理：拍后/相册路径若四角检测退化或接近整图，用文档分割
        // 再试一次页面边界；只有检测框通过“提议框回退”才采用（不裁字优先）。
        let boundary = pageBoundary(original: original, proposed: draft.quad)
        var report = boundary.report
        let maxVertexDistance = zip(boundary.quad.points, draft.quad.points)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? 0
        let wantsCrop = maxVertexDistance > 0.005
            && boundary.quad.area < draft.quad.area - 0.0001
        let corrected: Data
        if wantsCrop {
            let croppedData = try await correct(
                original: original,
                quad: boundary.quad,
                rotationTurns: draft.rotationTurns
            )
            let safety = await cropIsTableSafe(
                original: original,
                referenceQuad: draft.quad,
                rotationTurns: draft.rotationTurns,
                leftInsetRatio: report.pageLeftInset,
                croppedData: croppedData
            )
            report.tableSafetyReference = safety.reference
            report.tableSafetyDecision = safety.decision
            report.tableSafetyOriginalShapes = safety.originalShapes
            report.tableSafetyCroppedShapes = safety.croppedShapes
            if safety.isSafe {
                report.cropApplied = true
                corrected = croppedData
            } else {
                report.cropApplied = false
                report.fallbackReason = "table_mismatch"
                corrected = try await correct(
                    original: original,
                    quad: draft.quad,
                    rotationTurns: draft.rotationTurns
                )
            }
        } else {
            report.cropApplied = false
            corrected = try await correct(
                original: original,
                quad: draft.quad,
                rotationTurns: draft.rotationTurns
            )
        }
        writePreprocessReport(report, original: original)
        let enhanced = try await apply(imageData: corrected, enhancement: draft.enhancement)
        let thumb = try await makeThumbnail(imageData: enhanced, maxWidth: 360)
        let size: CGSize
        if let image = CIImage(data: enhanced) {
            size = image.extent.size
        } else {
            size = .zero
        }
        return RenderedPageData(jpeg: enhanced, thumbnail: thumb, pixelSize: size)
    }

    func averageSaturation(imageData: Data) async -> Double {
        guard let image = CIImage(data: imageData) else { return 0 }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// 将 original 按 quad 透视矫正后的矩形 CGImage（供书脊/折页检测）。
    private func rectifiedCGImage(original: URL, quad: Quad) -> CGImage? {
        guard let source = try? loadUpright(url: original) else { return nil }
        guard let corrected = try? perspectiveCorrect(source, quad: quad) else { return nil }
        return context.createCGImage(corrected, from: corrected.extent)
    }

    /// 裁切前表格安全门：原页有表时，裁切页必须保留同样的表数量/行列/文本。
    /// 任一结构识别失败 → 不裁（宁可保留页外背景，不丢表）。
    ///
    /// 真机页级 quad 的参照图必须先按同一 quad 做正向矫正再识别：原图是
    /// EXIF 旋转后的宽幅/整页照片，`RecognizeDocumentsRequest` 直接吃原 URL
    /// 会得到 0 表，无法与裁切页做同签名 A/B。页级框用 `page_quad` 参照；
    /// 近整图只保留原有整图参照，避免改变模拟器全图裁切路径。
    private func cropIsTableSafe(
        original: URL,
        referenceQuad: Quad,
        rotationTurns: Int,
        leftInsetRatio: Double?,
        croppedData: Data
    ) async -> TableSafetyOutcome {
        let usePageReference = !referenceQuad.isDegenerate
            && referenceQuad.area >= 0.25
            && referenceQuad.area < 0.95
        let referenceLabel = usePageReference ? "page_quad" : "full_original"
        let tempRef: URL? = usePageReference
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("zhixia-preprocess-ref-\(UUID().uuidString).jpg")
            : nil
        let tempCrop = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhixia-preprocess-\(UUID().uuidString).jpg")
        defer {
            if let tempRef { try? FileManager.default.removeItem(at: tempRef) }
            try? FileManager.default.removeItem(at: tempCrop)
        }

        let referenceURL: URL
        if let tempRef {
            guard let data = try? await correct(
                original: original,
                quad: referenceQuad,
                rotationTurns: rotationTurns
            ), (try? data.write(to: tempRef)) != nil else {
                return TableSafetyOutcome(
                    isSafe: false,
                    reference: referenceLabel,
                    decision: "mismatch",
                    originalShapes: [],
                    croppedShapes: []
                )
            }
            referenceURL = tempRef
        } else {
            referenceURL = original
        }
        guard (try? croppedData.write(to: tempCrop)) != nil else {
            return TableSafetyOutcome(
                isSafe: false,
                reference: referenceLabel,
                decision: "mismatch",
                originalShapes: [],
                croppedShapes: []
            )
        }

        let recognizer = VisionDocumentStructureRecognizer()
        guard let originalPage = await recognizer.recognize(
            imageURL: referenceURL,
            pageID: UUID()
        ), let croppedPage = await recognizer.recognize(
            imageURL: tempCrop,
            pageID: UUID()
        ) else {
            return TableSafetyOutcome(
                isSafe: false,
                reference: referenceLabel,
                decision: "mismatch",
                originalShapes: [],
                croppedShapes: []
            )
        }
        let originalSignature = PageCropSafety.signature(originalPage)
        let croppedSignature = PageCropSafety.signature(croppedPage)
        let signatureSafe = PageCropSafety.isSafe(
            original: originalPage,
            cropped: croppedPage
        )
        let geometryClear = leftInsetRatio.map {
            PageCropSafety.tablesClear(ofLeftFraction: $0, in: originalPage)
        } ?? false
        // 页级左缘内收只移除页边空白；若参照页所有表都在裁切线右侧，即使
        // 裁切页的结构识别偶发返回 0 表，几何上也证明表未被裁掉。
        let isSafe = signatureSafe || (croppedSignature.tableCount == 0 && geometryClear)
        let decision: String
        if signatureSafe {
            decision = originalSignature.tableCount == 0 ? "no_tables" : "signature_match"
        } else if isSafe {
            decision = "geometry_clear"
        } else {
            decision = "mismatch"
        }
        return TableSafetyOutcome(
            isSafe: isSafe,
            reference: referenceLabel,
            decision: decision,
            originalShapes: originalSignature.shapes,
            croppedShapes: croppedSignature.shapes
        )
    }

    private struct TableSafetyOutcome {
        var isSafe: Bool
        var reference: String
        var decision: String
        var originalShapes: [[Int]]
        var croppedShapes: [[Int]]
    }

    /// 仅在提议四角退化/近整图时补跑文档分割，避免改变正常取景框。
    /// 检测成功后外扩 1% 安全边（各边约 1% 页宽/页高），并写可观测报告。
    private func pageBoundary(
        original: URL,
        proposed: Quad
    ) -> (quad: Quad, report: PagePreprocessReport) {
        let started = Date()
        let margin = 0.01
        // 真机边缘检测常给出面积 0.8~0.9 的页面四边形，仍然可能带左侧
        // 亮折条/页外背景；因此放宽到 0.70 再跑折页与内容框候选。
        // 正常单页若没有折条，后续 chosenNearProposed 会拒绝内容框裁切。
        guard proposed.isDegenerate || proposed.area >= 0.70 else {
            return (
                proposed,
                PagePreprocessReport(
                    source: original.path,
                    proposed: .init(proposed),
                    detected: nil,
                    chosen: .init(proposed),
                    detectionConfidence: nil,
                    detectedArea: nil,
                    safetyMarginRatio: margin,
                    elapsedMilliseconds: elapsedMilliseconds(since: started),
                    fallbackReason: "proposed_not_degenerate",
                    createdAt: Date()
                )
            )
        }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return (
                proposed,
                PagePreprocessReport(
                    source: original.path,
                    proposed: .init(proposed),
                    detected: nil,
                    chosen: .init(proposed),
                    detectionConfidence: nil,
                    detectedArea: nil,
                    safetyMarginRatio: margin,
                    elapsedMilliseconds: elapsedMilliseconds(since: started),
                    fallbackReason: "image_unreadable",
                    createdAt: Date()
                )
            )
        }
        let orientation: CGImagePropertyOrientation = {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let raw = properties[kCGImagePropertyOrientation] as? UInt32,
                  let value = CGImagePropertyOrientation(rawValue: raw)
            else { return .up }
            return value
        }()
        let detection = PageBoundaryDetector.detect(in: image, orientation: orientation)
        let textBoxes = PageBoundaryDetector.textBoxes(in: image, orientation: orientation)
        let textBounds = PageBoundaryDetector.textBounds(boxes: textBoxes)
        let pageLike = !proposed.isDegenerate
            && proposed.area >= 0.25
            && proposed.area < 0.95
        let insidePageTextBounds = pageLike
            ? PageBoundaryDetector.textBounds(
                boxes: PageBoundaryDetector.textBoxes(in: proposed, from: textBoxes)
            )
            : nil
        var pageTextLeft: Double? = insidePageTextBounds.map { Double($0.minX) }
        var pageLeftInsetRatio: Double?
        var chosen = PageBoundaryDetector.choose(
            proposed: proposed,
            detected: detection,
            inkBounds: textBounds
        )
        // 折页检测跑在**已选页面**上：真机边缘框可能已切掉折条，而文档
        // 分割框（detection）仍包含完整书页——在后者上才能看到亮折条。
        let foldQuad = chosen
        let foldImage = rectifiedCGImage(original: original, quad: foldQuad)
        let darkFold = foldImage.flatMap { SpreadSplitter.leftFoldTrim(inRectified: $0) }
        let brightFold = foldImage.flatMap { SpreadSplitter.leftBrightFoldTrim(inRectified: $0) }
        let paperRightEdge = foldImage.flatMap { SpreadSplitter.rightPaperEdge(inRectified: $0) }
        var foldTrim = darkFold ?? brightFold
        var foldTrimSource: String? = darkFold != nil
            ? "dark_fold"
            : (brightFold != nil ? "bright_fold" : nil)
        // 折页裁切必须能解释被丢掉的文字：只允许丢左侧折条，正文列不能被裁。
        // 上限 15% 是折条文字面积的经验值；超过则视为误检，回到内容框裁切。
        var foldTrimTextLossRatio: Double?
        var pageTextBounds = insidePageTextBounds ?? textBounds
        if let textBounds, let fold = foldTrim {
            let rightPage = SpreadSplitter.split(foldQuad, at: fold.u).right
            let retained = textBounds.intersection(rightPage.boundingRect)
            let loss = 1 - Double(retained.width * retained.height)
                / max(Double(textBounds.width * textBounds.height), 0.0001)
            foldTrimTextLossRatio = loss
            if retained.isEmpty || loss > 0.15 {
                foldTrim = nil
                foldTrimSource = nil
                foldTrimTextLossRatio = nil
            } else {
                pageTextBounds = retained
            }
        }
        let contentBaseQuad = foldTrim.map {
            SpreadSplitter.split(foldQuad, at: $0.u).right
        } ?? foldQuad
        // 内容裁切候选：文字框 + 0.3% 边；折页场景先把文字框夹到右页。
        // 只在原页面检测没能给出更贴合内容边界时启用（木桌/折页页）。
        var usedContentCrop = false
        // 正常单页检测已足够好时不做内容框裁切：0.3% 文字边可能切掉标题
        // 左侧的 W 等字形，且不会带来页外背景收益。折页场景必裁；其余仅当
        // 文档分割确实替换了提议框（chosen 已远离 proposed）时才裁。
        let chosenNearProposed = chosen.meanVertexDistance(to: proposed) < 0.02
        let needsContentCrop = foldTrim != nil
            || chosen.area < proposed.area - 0.01
            || (!chosenNearProposed && (detection?.area ?? 0) >= 0.90)
        if needsContentCrop, foldTrim == nil, let textBounds {
            // 检测框已经比提议框更贴页时，内容框必须夹在检测页内，否则
            // 文字包围盒会把左侧折条/页外背景重新带回来。
            pageTextBounds = textBounds.intersection(chosen.boundingRect)
        }
        if needsContentCrop, let pageTextBounds,
           let content = PageBoundaryDetector.contentQuad(
               textBounds: pageTextBounds,
               margin: foldTrim == nil ? 0.003 : 0.008
           ),
           content.area < chosen.area - 0.005 {
            var crop = content
            // 折页内容框的右缘会带入 0.5% 的页边阴影/木桌；左缘则要保留标题
            // 字形，所以只收右缘，不缩小左侧安全边。
            if foldTrim == nil {
                // 非折页：内容框夹在已选页面内，去掉页边/木桌，同时给
                // 标题保留 0.1% 的纸内边。
                let b = chosen.boundingRect
                crop.topLeft.x = max(crop.topLeft.x, b.minX + 0.001)
                crop.bottomLeft.x = max(crop.bottomLeft.x, b.minX + 0.001)
                crop.topLeft.y = max(crop.topLeft.y, b.minY + 0.001)
                crop.topRight.y = max(crop.topRight.y, b.minY + 0.001)
                crop.topRight.x = min(crop.topRight.x, b.maxX - 0.001)
                crop.bottomRight.x = min(crop.bottomRight.x, b.maxX - 0.001)
                crop.bottomLeft.y = min(crop.bottomLeft.y, b.maxY - 0.001)
                crop.bottomRight.y = min(crop.bottomRight.y, b.maxY - 0.001)
            } else {
                // 右缘：优先收在纸面右边界内，去掉木桌/页边阴影；仍保留
                // 文字框本身的 0.8% 安全边。
                // paperRightEdge 是矫正图上 u；换算回原始 proposal 的 x 再裁。
                let paperU = paperRightEdge ?? 1
                let paperRightFull = foldQuad.topLeft.x
                    + (foldQuad.topRight.x - foldQuad.topLeft.x) * paperU
                // 页脚页码比页面上缘更靠右：右边界做成斜边，上缘收在纸边、
                // 下缘保留页码，避免为了页码把整条木桌/阴影带回来。
                let topRight = min(crop.topRight.x, paperRightFull - 0.002)
                let bottomRight = min(crop.bottomRight.x, pageTextBounds.maxX + 0.003)
                crop.topRight.x = topRight
                crop.bottomRight.x = bottomRight
            }
            chosen = crop
            usedContentCrop = true
        } else if foldTrim != nil, pageTextBounds == nil {
            chosen = contentBaseQuad
            usedContentCrop = true
        }
        // 内容裁切框已包含极小的文字安全边；不再向外扩 1%，否则会把左侧折页带回来。
        // 页级边缘框同样不向外扩：边缘检测已经贴住纸页，再扩只会把左页边/
        // 桌面带回来。页级框若还能找到页内最左文字，则内收最多 1% 页宽。
        let leftInset: PageBoundaryDetector.LeftInset? = {
            guard !usedContentCrop, pageLike else { return nil }
            return PageBoundaryDetector.pageLeftInset(
                in: chosen,
                allTextBoxes: textBoxes
            )
        }()
        if let leftInset {
            pageLeftInsetRatio = leftInset.ratio
            pageTextLeft = Double(leftInset.textLeft)
        }
        let expanded: Quad
        if usedContentCrop {
            expanded = chosen
        } else if pageLike {
            expanded = leftInset?.quad ?? chosen
        } else {
            expanded = chosen.expanded(by: margin)
        }
        let coverage: Double? = {
            guard let pageTextBounds, !pageTextBounds.isEmpty else { return nil }
            let intersection = expanded.boundingRect.intersection(pageTextBounds)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return Double(intersection.width * intersection.height / max(pageTextBounds.width * pageTextBounds.height, 0.0001))
        }()
        let angles = PageBoundaryMetrics.edgeAnglesDegrees(expanded)
        let parallel = PageBoundaryMetrics.parallelErrorsDegrees(expanded)
        let reason: String
        if usedContentCrop, foldTrim != nil {
            reason = "fold_trim"
        } else if usedContentCrop {
            reason = "content_bounds"
        } else if pageLeftInsetRatio != nil {
            reason = "page_left_inset"
        } else if detection == nil {
            reason = "no_detection"
        } else if chosen.meanVertexDistance(to: proposed) < 0.01 {
            reason = "detected_near_proposed"
        } else {
            reason = "detected_used"
        }
        let report = PagePreprocessReport(
            source: original.path,
            proposed: .init(proposed),
            detected: detection.map { .init($0.quad) },
            chosen: .init(expanded),
            detectionConfidence: detection?.confidence,
            detectedArea: detection?.area,
            textBounds: textBounds.map { PagePreprocessReport.QuadPayload(CGRectPayload: $0) },
            textCoverage: coverage,
            outsideAreaRatio: PageBoundaryMetrics.outsideAreaRatio(expanded),
            edgeAnglesDegrees: angles,
            parallelErrorsDegrees: [parallel.horizontal, parallel.vertical],
            safetyMarginRatio: margin,
            foldTrimU: foldTrim?.u,
            foldTrimSource: foldTrimSource,
            foldTrimTextLossRatio: foldTrimTextLossRatio,
            paperRightEdge: paperRightEdge,
            pageTextLeft: pageTextLeft,
            pageLeftInset: pageLeftInsetRatio,
            cropApplied: false,
            elapsedMilliseconds: elapsedMilliseconds(since: started),
            fallbackReason: reason,
            createdAt: Date()
        )
        return (expanded, report)
    }

    private func writePreprocessReport(_ report: PagePreprocessReport, original: URL) {
        let url = original
            .deletingPathExtension()
            .appendingPathExtension("preprocess.json")
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func loadUpright(url: URL) throws -> CIImage {
        guard var image = CIImage(contentsOf: url) else {
            throw ZhixiaError.perspectiveFailed
        }
        if let raw = image.properties[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw)
        {
            image = image.oriented(orientation)
        }
        return image
    }

    private func perspectiveCorrect(_ image: CIImage, quad: Quad) throws -> CIImage {
        let working = quad.isDegenerate ? Quad.fullImage : quad
        let size = image.extent.size
        let pixels = working.pixelPoints(imageSize: size)
        let top = hypot(pixels.1.x - pixels.0.x, pixels.1.y - pixels.0.y)
        let bottom = hypot(pixels.2.x - pixels.3.x, pixels.2.y - pixels.3.y)
        let left = hypot(pixels.3.x - pixels.0.x, pixels.3.y - pixels.0.y)
        let right = hypot(pixels.2.x - pixels.1.x, pixels.2.y - pixels.1.y)
        var width = (top + bottom) / 2
        var height = (left + right) / 2
        guard width > 8, height > 8 else {
            return image
        }
        let longest = max(width, height)
        if longest > maxLongestEdge {
            let scale = maxLongestEdge / longest
            width *= scale
            height *= scale
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = ciPoint(pixels.0, height: size.height)
        filter.topRight = ciPoint(pixels.1, height: size.height)
        filter.bottomRight = ciPoint(pixels.2, height: size.height)
        filter.bottomLeft = ciPoint(pixels.3, height: size.height)
        guard var output = filter.outputImage else {
            return image
        }
        let current = output.extent.size
        if current.width > 0, current.height > 0 {
            let scaleX = width / current.width
            let scaleY = height / current.height
            output = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        return output
    }

    private func rotate(_ image: CIImage, turns: Int) -> CIImage {
        let steps = ((turns % 4) + 4) % 4
        guard steps > 0 else { return image }
        var result = image
        for _ in 0..<steps {
            let extent = result.extent
            result = result
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            let rotated = result.extent
            result = result.transformed(by: CGAffineTransform(translationX: -rotated.origin.x, y: -rotated.origin.y))
        }
        return result
    }

    private func applyRecipe(_ image: CIImage, enhancement: Enhancement) -> CIImage {
        guard let recipe = EnhancementRecipe.recipe(for: enhancement) else {
            return image
        }
        var current = image
        let shadow = CIFilter.highlightShadowAdjust()
        shadow.inputImage = current
        shadow.shadowAmount = Float(recipe.shadows)
        shadow.highlightAmount = Float(1 + recipe.highlights)
        if let output = shadow.outputImage {
            current = output
        }
        let color = CIFilter.colorControls()
        color.inputImage = current
        color.contrast = Float(recipe.contrast)
        color.saturation = Float(recipe.saturation)
        color.brightness = Float(recipe.brightness)
        if let output = color.outputImage {
            current = output
        }
        if recipe.temperature != 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = current
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6500 + recipe.temperature * 1500, y: 0)
            if let output = temp.outputImage {
                current = output
            }
        }
        if recipe.sharpness > 0 {
            let sharp = CIFilter.sharpenLuminance()
            sharp.inputImage = current
            sharp.sharpness = Float(recipe.sharpness)
            if let output = sharp.outputImage {
                current = output
            }
        }
        return current
    }

    private func jpegData(from image: CIImage, quality: CGFloat) throws -> Data {
        let extent = image.extent.integral
        guard let cgImage = context.createCGImage(image, from: extent) else {
            throw ZhixiaError.perspectiveFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ZhixiaError.perspectiveFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ZhixiaError.perspectiveFailed
        }
        return data as Data
    }

    private func ciPoint(_ uiPoint: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: uiPoint.x, y: height - uiPoint.y)
    }
}
