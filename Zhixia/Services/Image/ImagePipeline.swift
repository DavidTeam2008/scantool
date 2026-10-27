import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

actor ImagePipeline: PerspectiveCorrecting, Enhancing, Thumbnailing, ImageRendering {
    private let context: CIContext
    private let maxLongestEdge: CGFloat
    private let preprocessRecipe: PagePreprocessRecipe
    private let illuminationFlattener = PaperIlluminationFlattener()

    init(
        maxLongestEdge: CGFloat = 2200,
        preprocessRecipe: PagePreprocessRecipe = .paper
    ) {
        self.maxLongestEdge = maxLongestEdge
        self.preprocessRecipe = preprocessRecipe
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
        let boundary = pageBoundary(
            original: original,
            proposed: draft.quad,
            allowEnvelope: !draft.userAdjustedQuad
        )
        var report = boundary.report
        let maxVertexDistance = zip(boundary.quad.points, draft.quad.points)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? 0
        let boundaryRect = boundary.quad.boundingRect
        let draftRect = draft.quad.boundingRect
        // 候选可能只裁掉上/左边、同时把纸面底边补回提议框之外；不能用
        // “面积必须变小”作为唯一触发条件，否则这种横向/纵向收边会被漏掉。
        let trimsAnEdge = boundaryRect.minY > draftRect.minY + 0.005
            || boundaryRect.minX > draftRect.minX + 0.005
            || boundaryRect.maxY < draftRect.maxY - 0.005
            || boundaryRect.maxX < draftRect.maxX - 0.005
        let wantsCrop = maxVertexDistance > 0.005
            && (boundary.quad.area < draft.quad.area - 0.0001 || trimsAnEdge)
        let corrected: Data
        var protectedTableRects: [CGRect] = []
        var tableGuardAvailable = false
        var tableGuardAttempted = false
        var tableGuardSource: String?
        var backgroundWhiteningRect: CGRect?
        if wantsCrop {
            tableGuardAttempted = true
            var cropQuad = boundary.quad
            var croppedData = try await correct(
                original: original,
                quad: cropQuad,
                rotationTurns: draft.rotationTurns
            )
            let draftRect = draft.quad.boundingRect
            func referenceCropRect(_ quad: Quad) -> CGRect {
                let rect = quad.boundingRect
                return CGRect(
                    x: (rect.minX - draftRect.minX) / max(draftRect.width, 0.0001),
                    y: (rect.minY - draftRect.minY) / max(draftRect.height, 0.0001),
                    width: rect.width / max(draftRect.width, 0.0001),
                    height: rect.height / max(draftRect.height, 0.0001)
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            var safety = await cropIsTableSafe(
                original: original,
                referenceQuad: draft.quad,
                rotationTurns: draft.rotationTurns,
                leftInsetRatio: report.pageLeftInset,
                cropRect: referenceCropRect(cropQuad),
                croppedData: croppedData
            )
            // P0.1 refine：内容包络可能为了去掉折页而切到表格边缘，结构
            // 识别随之丢表。此时用参照页表格 bbox 把裁切框扩到包含所有表，
            // 只重算一次几何；仍不安全就回退整图。整个过程不重复 P1/JPEG。
            if !safety.isSafe,
               draft.quad.area >= 0.95,
               !safety.originalTableRects.isEmpty {
                var expanded = cropQuad.boundingRect
                for table in safety.originalTableRects {
                    expanded = expanded.union(table.insetBy(dx: -0.004, dy: -0.004))
                }
                expanded = expanded.intersection(draft.quad.boundingRect)
                let retryQuad = Quad(
                    topLeft: CGPoint(x: expanded.minX, y: expanded.minY),
                    topRight: CGPoint(x: expanded.maxX, y: expanded.minY),
                    bottomRight: CGPoint(x: expanded.maxX, y: expanded.maxY),
                    bottomLeft: CGPoint(x: expanded.minX, y: expanded.maxY)
                )
                if !retryQuad.isDegenerate,
                   retryQuad.area >= 0.20,
                   retryQuad.area < draft.quad.area - 0.0001,
                   retryQuad.meanVertexDistance(to: cropQuad) > 0.002 {
                    let retryData = try await correct(
                        original: original,
                        quad: retryQuad,
                        rotationTurns: draft.rotationTurns
                    )
                    let retrySafety = await cropIsTableSafe(
                        original: original,
                        referenceQuad: draft.quad,
                        rotationTurns: draft.rotationTurns,
                        leftInsetRatio: report.pageLeftInset,
                        cropRect: referenceCropRect(retryQuad),
                        croppedData: retryData
                    )
                    if retrySafety.isSafe {
                        cropQuad = retryQuad
                        croppedData = retryData
                        safety = retrySafety
                        report.envelopeRefineApplied = true
                        report.cropSource = "content_envelope_refine"
                        report.chosen = .init(retryQuad)
                    } else {
                        safety = retrySafety
                    }
                }
            }
            tableGuardAvailable = safety.tableRects.count > 0
                || (safety.originalShapes.isEmpty && safety.croppedShapes.isEmpty)
            if tableGuardAvailable { tableGuardSource = "p0_crop_safety" }
            report.illuminationTableGuardAvailable = tableGuardAvailable
            report.tableSafetyReference = safety.reference
            report.tableSafetyDecision = safety.decision
            report.tableSafetyOriginalShapes = safety.originalShapes
            report.tableSafetyCroppedShapes = safety.croppedShapes
            report.tableSafetyOriginalRects = safety.originalTableRects.map {
                PagePreprocessReport.QuadPayload(CGRectPayload: $0)
            }
            protectedTableRects = safety.tableRects
            if safety.isSafe {
                report.cropApplied = true
                corrected = croppedData
            } else {
                // 表格结构/识别抖动时不允许裁切，但页外背景仍然可见。
                // 保留原页尺寸/缩放（表格保护），只把候选框外的背景刷白；
                // 这既解决“顶部/底部背景没去掉”，又不把表格交给裁切后的
                // 结构识别重新解释。
                report.cropApplied = false
                report.fallbackReason = "table_mismatch_whitened"
                backgroundWhiteningRect = referenceCropRect(cropQuad)
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
        var workingImage: CIImage
        guard let correctedImage = CIImage(data: corrected) else {
            throw ZhixiaError.perspectiveFailed
        }
        // 透视采样在图像最外沿可能留下 1px 的黑色未定义边（真机 round1
        // 右侧黑线）；先去掉 1px，再由白底画布补回纸边。
        let correctedExtent = correctedImage.extent.integral
        let usableCorrected = correctedExtent.width > 3 && correctedExtent.height > 3
            ? correctedImage.cropped(to: correctedExtent.insetBy(dx: 1, dy: 1))
            : correctedImage
        workingImage = usableCorrected
        if let backgroundWhiteningRect {
            workingImage = whiteOutside(
                usableCorrected,
                rect: backgroundWhiteningRect
            )
            report.backgroundWhitened = true
        }
        // 未裁切页没有 P0 表格安全门；P1 前单独跑一次结构识别拿表框。
        // 只做一次，识别失败/空页则继续跳过 P1，保持安全回退。
        if draft.enhancement != .original,
           preprocessRecipe.flattensPaperIllumination,
           !tableGuardAvailable,
           !tableGuardAttempted {
            let guardOutcome = await detectTableGuard(correctedImage: workingImage)
            tableGuardAvailable = guardOutcome.isAvailable
            protectedTableRects = guardOutcome.tableRects
            tableGuardSource = guardOutcome.source
            report.illuminationTableGuardElapsedMilliseconds = guardOutcome.elapsedMilliseconds
        }
        report.illuminationTableGuardAvailable = tableGuardAvailable
        report.illuminationTableGuardSource = tableGuardSource
        // P1 与 EnhancementRecipe 完全隔离：只在 renderPage 的预处理阶段做。
        // 用户明确选「原图」时不改像素；其余滤镜都在压平后的页面上再增强。
        // 表格保护区来自 P0 表格安全门；未裁切页先用 `.enhance` 预览跑一次
        // 结构识别拿表框（vision_structure）。失败/空页才跳过 P1，宁可少做
        // 压平，也不让 RecognizeDocumentsRequest 丢表。
        if draft.enhancement == .original {
            report.illuminationApplied = false
            report.illuminationFallbackReason = "original_filter"
        } else if !preprocessRecipe.flattensPaperIllumination {
            report.illuminationApplied = false
            report.illuminationFallbackReason = "recipe_disabled"
        } else if !tableGuardAvailable {
            report.illuminationApplied = false
            report.illuminationFallbackReason = "table_guard_unavailable"
            report.illuminationTableGuardAvailable = false
        } else if let output = illuminationFlattener.flatten(
            workingImage,
            context: context,
            options: preprocessRecipe.illuminationOptions,
            protectedRects: protectedTableRects
        ) {
            workingImage = output.image
            let metrics = output.metrics
            report.illuminationApplied = metrics.applied
            report.illuminationFallbackReason = metrics.fallbackReason
            report.illuminationPaperCoverage = metrics.paperCoverage
            report.illuminationTargetLuminance = metrics.targetLuminance
            report.illuminationGainP50 = metrics.gainP50
            report.illuminationGainMax = metrics.gainMax
            report.illuminationVarianceBefore = metrics.varianceBefore
            report.illuminationVarianceAfter = metrics.varianceAfter
            report.illuminationElapsedMilliseconds = metrics.elapsedMilliseconds
            report.illuminationProtectedTableCount = protectedTableRects.count
        } else {
            report.illuminationApplied = false
            report.illuminationFallbackReason = "unavailable"
        }
        let filtered = applyRecipe(workingImage, enhancement: draft.enhancement)
        if preprocessRecipe.analyzesTextLines, draft.enhancement != .original {
            let analysisStarted = Date()
            if let cgImage = context.createCGImage(filtered, from: filtered.extent.integral) {
                let analysis = PageTextLineAnalyzer.analyze(in: cgImage)
                report.textLineCount = analysis.lines.count
                report.textLineBandCount = analysis.bands.count
                report.textLineMedianAngleDegrees = analysis.medianAbsAngleDegrees
                report.textLineP90AngleDegrees = analysis.p90AbsAngleDegrees
                report.textLineMaxAngleDegrees = analysis.maxAbsAngleDegrees
                report.textLineAnalysisElapsedMilliseconds = elapsedMilliseconds(since: analysisStarted)
            }
        }
        let outputImage = report.cropApplied && preprocessRecipe.scanCanvasBorderRatio > 0
            ? scanCanvas(
                filtered,
                borderRatio: CGFloat(preprocessRecipe.scanCanvasBorderRatio)
            )
            : filtered
        let enhanced = try jpegData(from: outputImage, quality: 0.82, trimEdge: true)
        writePreprocessReport(report, original: original)
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

    /// 将原图按 EXIF 方向转正后的 CGImage，供 P0.1 栅格包络检测使用。
    private func uprightCGImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return context.createCGImage(oriented, from: oriented.extent)
    }

    /// 将 original 按 quad 透视矫正后的矩形 CGImage（供书脊/折页检测）。
    private func rectifiedCGImage(original: URL, quad: Quad) -> CGImage? {
        guard let source = try? loadUpright(url: original) else { return nil }
        guard let corrected = try? perspectiveCorrect(source, quad: quad) else { return nil }
        return context.createCGImage(corrected, from: corrected.extent)
    }

    /// P1 的通用表格 guard：对未裁切页做一次结构识别，拿表框供增益 mask。
    /// 只复用 `RecognizeDocumentsRequest` 的表格 bbox，不参与 P0 裁切决策。
    private struct TableGuardOutcome {
        var isAvailable: Bool
        var tableRects: [CGRect]
        var source: String
        var elapsedMilliseconds: Int
    }

    private func detectTableGuard(correctedImage: CIImage) async -> TableGuardOutcome {
        let started = Date()
        // 直接在未增强校正页上识别，真机表格容易漏检；先用通用 `.enhance`
        // 生成一张“P1 前最终观感”预览，再识别。表框坐标是归一化的，可直接
        // 映射回校正页；预览仅用于 guard，不会作为最终输出。
        let preview = applyRecipe(correctedImage, enhancement: .enhance)
        guard let previewData = try? jpegData(from: preview, quality: 0.82) else {
            return TableGuardOutcome(
                isAvailable: false,
                tableRects: [],
                source: "unavailable",
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhixia-p1-guard-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? previewData.write(to: temp)) != nil else {
            return TableGuardOutcome(
                isAvailable: false,
                tableRects: [],
                source: "unavailable",
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        }
        let page = await VisionDocumentStructureRecognizer().recognize(
            imageURL: temp,
            pageID: UUID()
        )
        let tableRects = page?.tables.map(\.bbox) ?? []
        if !tableRects.isEmpty {
            return TableGuardOutcome(
                isAvailable: true,
                tableRects: tableRects,
                source: "vision_structure",
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        }
        // Vision 漏表时，先用深色内容块（常见表头）兜底，再用长横线/竖线
        // 网格兜底；宁可多保护一块区域，也不让 P1 无 mask 改到表格。
        if let cgImage = context.createCGImage(preview, from: preview.extent) {
            let contentRects = TableContentGuard().detect(in: cgImage)
            if !contentRects.isEmpty {
                return TableGuardOutcome(
                    isAvailable: true,
                    tableRects: contentRects,
                    source: "content_fallback",
                    elapsedMilliseconds: elapsedMilliseconds(since: started)
                )
            }
            if let grid = TableGridGuard().detect(in: cgImage) {
                return TableGuardOutcome(
                    isAvailable: true,
                    tableRects: grid.normalizedRects,
                    source: "grid_fallback",
                    elapsedMilliseconds: elapsedMilliseconds(since: started)
                )
            }
        }
        guard let page, page.hasContent else {
            return TableGuardOutcome(
                isAvailable: false,
                tableRects: [],
                source: "unavailable",
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            )
        }
        return TableGuardOutcome(
            isAvailable: true,
            tableRects: [],
            source: "vision_structure",
            elapsedMilliseconds: elapsedMilliseconds(since: started)
        )
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
        cropRect: CGRect?,
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
                    croppedShapes: [],
                    tableRects: []
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
                croppedShapes: [],
                tableRects: []
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
                croppedShapes: [],
                tableRects: []
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
        } ?? cropRect.map {
            PageCropSafety.tablesClear(of: $0, in: originalPage)
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
        let tableRects: [CGRect]
        if !croppedPage.tables.isEmpty {
            tableRects = croppedPage.tables.map(\.bbox)
        } else if usePageReference {
            // 页级左缘内收只裁掉页边空白；参照页表框稍后由 P1 外扩覆盖。
            tableRects = originalPage.tables.map(\.bbox)
        } else {
            tableRects = []
        }
        return TableSafetyOutcome(
            isSafe: isSafe,
            reference: referenceLabel,
            decision: decision,
            originalShapes: originalSignature.shapes,
            croppedShapes: croppedSignature.shapes,
            tableRects: tableRects,
            originalTableRects: originalPage.tables.map { table in
                // Vision 左下原点 → 左上原点。
                CGRect(
                    x: table.bbox.minX,
                    y: 1 - table.bbox.maxY,
                    width: table.bbox.width,
                    height: table.bbox.height
                )
            }
        )
    }

    private struct TableSafetyOutcome {
        var isSafe: Bool
        var reference: String
        var decision: String
        var originalShapes: [[Int]]
        var croppedShapes: [[Int]]
        var tableRects: [CGRect]
        /// 参照页表格 bbox（左上原点），用于 table-aware refine。
        var originalTableRects: [CGRect] = []
    }

    /// 仅在提议四角退化/近整图时补跑文档分割，避免改变正常取景框。
    /// 检测成功后外扩 1% 安全边（各边约 1% 页宽/页高），并写可观测报告。
    private func pageBoundary(
        original: URL,
        proposed: Quad,
        allowEnvelope: Bool = true
    ) -> (quad: Quad, report: PagePreprocessReport) {
        let started = Date()
        let margin = 0.01
        // 真机边缘检测常给出面积 0.8~0.9 的页面四边形，仍然可能带左侧
        // 亮折条/页外背景；因此放宽到 0.70 再跑折页与内容框候选。
        // 正常单页若没有折条，后续 chosenNearProposed 会拒绝内容框裁切。
        guard proposed.isDegenerate
            || proposed.area >= 0.70
            || (allowEnvelope && proposed.area >= 0.25)
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
        // P0.1：纸张/内容包络候选。只在提议框接近整图时接管，避免覆盖
        // 用户手动拖角或已经贴边的页级 quad；包络本身仍要过下面的文字/
        // 表格安全门。它解决的是“单次链路只会得到整图”的欠裁，不是
        // 用重复保存/重扫来碰运气。
        var envelopeCandidate: PageContentEnvelopeDetector.Candidate?
        var usedEnvelope = false
        var envelopeSkipReason: String?
        if allowEnvelope,
           (proposed.area >= 0.25 || proposed.isDegenerate),
           let upright = uprightCGImage(image, orientation: orientation),
           let envelope = PageContentEnvelopeDetector.detect(in: upright) {
            envelopeCandidate = envelope
            var rect = envelope.contentRect ?? envelope.paperRect
            // 左侧折页/对页常常也是白纸，会被内容包络带进来；以页内
            // 最左文字为锚，只在内容明显越过文字左侧时裁掉折页条。
            if let textBounds,
               rect.minX < textBounds.minX - 0.02 {
                rect.origin.x = max(0, textBounds.minX - 0.006)
                rect.size.width = max(0, envelope.paperRect.maxX - rect.origin.x)
            }
            if let textBounds {
                rect = rect.union(textBounds)
            }
            rect = rect.insetBy(dx: -0.004, dy: -0.004)
                .intersection(envelope.paperRect.insetBy(dx: -0.002, dy: -0.002))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if let textBounds {
                // 上/左页外背景（书脊、对页、桌面）可能在暗像素包络里，
                // 用页内文字作为上/左锚点；右/下仍保留图片/页码内容包络。
                // 上/左各留 0.8% 纸内边；其余由文字覆盖率和表格安全门兜底。
                rect.origin.y = max(rect.origin.y, textBounds.minY - 0.008)
                // 页码/页眉可能在 OCR 文本框之外（真机 IMG_7542 的右上
                // “2”就是这种情况）。纸面有明显上边距时，至少保留纸面
                // 顶部 1.5% 作为页眉安全带，避免把页码当背景裁掉。
                if envelope.paperRect.minY > 0.03 {
                    rect.origin.y = min(
                        rect.origin.y,
                        envelope.paperRect.minY - 0.015
                    )
                }
                rect.size.height = max(
                    0,
                    min(rect.maxY, textBounds.maxY + 0.008) - rect.origin.y
                )
                rect.origin.x = max(rect.origin.x, textBounds.minX - 0.008)
                rect.size.width = max(
                    0,
                    min(rect.maxX, textBounds.maxX + 0.008) - rect.origin.x
                )
            }
            if let textBounds,
               !rect.insetBy(dx: 0.001, dy: 0.001).contains(textBounds) {
                rect = rect.union(textBounds)
            }
            rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            // 重要：包络只能在当前页面框**内部**收边，不能把已经贴边的
            // 页面级 draft 重新扩回折页/右侧背景。之前 round1-2 的左侧
            // 折页和右侧背景就是这样被“扩”回来的。
            rect = rect.intersection(chosen.boundingRect)
            let candidate = Quad(
                topLeft: CGPoint(x: rect.minX, y: rect.minY),
                topRight: CGPoint(x: rect.maxX, y: rect.minY),
                bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
                bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            )
            let chosenRect = chosen.boundingRect
            let candidateRect = candidate.boundingRect
            let trimsAnEdge = candidateRect.minY > chosenRect.minY + 0.005
                || candidateRect.minX > chosenRect.minX + 0.005
                || candidateRect.maxY < chosenRect.maxY - 0.005
                || candidateRect.maxX < chosenRect.maxX - 0.005
            if candidate.isDegenerate {
                envelopeSkipReason = "degenerate"
            } else if candidate.area < 0.25 {
                envelopeSkipReason = "too_small"
            } else if !trimsAnEdge {
                // 候选可能把纸面底边补回提议框之外；只要四个方向都没有
                // 向内裁掉页面，就不值得改变现有框。
                envelopeSkipReason = "no_inward_trim"
            } else if candidate.area >= 0.995 {
                envelopeSkipReason = "too_large"
            } else {
                chosen = candidate
                usedEnvelope = true
            }
        } else if !allowEnvelope {
            envelopeSkipReason = "user_adjusted_quad"
        } else if proposed.area < 0.25 && !proposed.isDegenerate {
            envelopeSkipReason = "proposed_too_small"
        } else {
            envelopeSkipReason = "no_envelope"
        }
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
        let needsContentCrop = !usedEnvelope && (foldTrim != nil
            || chosen.area < proposed.area - 0.01
            || (!chosenNearProposed && (detection?.area ?? 0) >= 0.90))
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
            guard !usedEnvelope, !usedContentCrop, pageLike else { return nil }
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
        if usedEnvelope || usedContentCrop {
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
        let envelopeTextCoverage: Double? = {
            guard let textBounds, !textBounds.isEmpty else { return nil }
            let intersection = expanded.boundingRect.intersection(textBounds)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return Double(intersection.width * intersection.height / max(textBounds.width * textBounds.height, 0.0001))
        }()
        let cropSource: String = {
            if usedEnvelope { return "content_envelope" }
            if usedContentCrop, foldTrim != nil { return "fold_trim" }
            if usedContentCrop { return "content_bounds" }
            if pageLeftInsetRatio != nil { return "page_left_inset" }
            if detection != nil { return "detected" }
            return "proposed"
        }()
        let reason: String
        if usedEnvelope {
            reason = "content_envelope"
        } else if usedContentCrop, foldTrim != nil {
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
            cropSource: cropSource,
            paperEnvelope: envelopeCandidate.map {
                PagePreprocessReport.QuadPayload(CGRectPayload: $0.paperRect)
            },
            contentEnvelope: envelopeCandidate?.contentRect.map {
                PagePreprocessReport.QuadPayload(CGRectPayload: $0)
            },
            envelopeBackgroundResidual: envelopeCandidate?.backgroundResidual,
            envelopeTextCoverage: envelopeTextCoverage,
            envelopeRefineApplied: false,
            envelopeSkipReason: envelopeSkipReason,
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

    /// 表格安全门拒绝裁切时的保底：保留原页几何，只把候选框外背景刷白。
    /// `rect` 是归一化左上原点；CIImage 使用左下原点，需翻 y。
    private func whiteOutside(_ image: CIImage, rect: CGRect) -> CIImage {
        let extent = image.extent
        let clipped = rect.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard clipped.width > 0.01, clipped.height > 0.01 else { return image }
        let pixelRect = CGRect(
            x: clipped.minX * extent.width,
            y: (1 - clipped.maxY) * extent.height,
            width: clipped.width * extent.width,
            height: clipped.height * extent.height
        )
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: extent)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: extent)
        let whiteMask = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: pixelRect)
        let mask = whiteMask.composited(over: black).cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return image }
        filter.setValue(image, forKey: "inputImage")
        filter.setValue(white, forKey: "inputBackgroundImage")
        filter.setValue(mask, forKey: "inputMaskImage")
        return filter.outputImage ?? image
    }

    /// P0.1 扫描观感：页面裁切成功后铺一层白底画布，给纸边/标题留下
    /// 始终一致的安全边。只改变画布，不缩放或改写页面像素；白底在页面
    /// 外层，不会覆盖内容。
    private func scanCanvas(_ image: CIImage, borderRatio: CGFloat) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 8, extent.height > 8, borderRatio > 0 else {
            return image
        }
        let longEdge = max(extent.width, extent.height)
        let border = longEdge * borderRatio
        // 画布也必须遵守 maxLongestEdge；否则第一轮输出会超过上限，下一轮
        // correct 又把它缩回 2200，造成尺寸漂移（幂等性失败）。
        let available = max(8, maxLongestEdge - border * 2)
        let scale = min(1, available / longEdge)
        let pageWidth = extent.width * scale
        let pageHeight = extent.height * scale
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        // 多留 2px 白边，盖住 JPEG/CI 在最后一列留下的透明黑线。
        let edgePadding: CGFloat = 2
        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: pageWidth + border * 2 + edgePadding * 2,
            height: pageHeight + border * 2 + edgePadding * 2
        )
        let canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: canvasRect)
        let page = scaled.transformed(
            by: CGAffineTransform(
                translationX: border + edgePadding,
                y: border + edgePadding
            )
        )
        return page.composited(over: canvas)
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

    private func jpegData(
        from image: CIImage,
        quality: CGFloat,
        trimEdge: Bool = false
    ) throws -> Data {
        let rawExtent = image.extent.integral
        let extent = trimEdge
            ? rawExtent.insetBy(dx: 2, dy: 2)
            : rawExtent
        // 透明/未覆盖的边缘在 JPEG 里会变黑（真机 round1 右侧 1px 黑边）。
        // 先铺一层白底再编码，白画布/页面边缘不会被编码器吃成黑线。
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: extent)
        let flattened = image.composited(over: white)
        guard let cgImage = context.createCGImage(flattened, from: extent) else {
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
        let finalImage: CGImage = trimEdge && cgImage.width > 4
            ? (cgImage.cropping(
                to: CGRect(x: 0, y: 0, width: cgImage.width - 1, height: cgImage.height)
            ) ?? cgImage)
            : cgImage
        CGImageDestinationAddImage(destination, finalImage, [
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
