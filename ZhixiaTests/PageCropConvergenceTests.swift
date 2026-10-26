import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// P0.1 真机样张回归：从**整图 draft** 走实际 `renderPage` 链路。
///
/// 这是 T050 的证据生成器，也是 T051/T053/T054 的门：
/// - 原图必须产生纸张/内容包络裁切，而不是继续保留整图；
/// - 文字覆盖率必须为 1；
/// - 裁切后页面外必须有白底画布；
/// - 三张用户中间图只记录结果，不强制裁切（它们的表格识别状态可能抖动）。
@Suite(.serialized)
struct PageCropConvergenceTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var evidenceDirectory: URL {
        repoRoot.appending(path: "build/page-preprocess/crop-convergence")
    }

    private func loadReport(for imageURL: URL) throws -> PagePreprocessReport {
        let url = imageURL.deletingPathExtension().appendingPathExtension("preprocess.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PagePreprocessReport.self, from: data)
    }

    private func copyInput(_ relative: String, as name: String) throws -> URL {
        let source = Self.repoRoot.appending(path: relative)
        let destination = Self.evidenceDirectory.appending(path: name)
        try FileManager.default.createDirectory(
            at: Self.evidenceDirectory,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    @Test("整图 draft：P0.1 包络裁切、文字覆盖与白底画布")
    func fullImageDraftCropsAndPads() async throws {
        let input = try copyInput("docs/media/IMG_7544.jpg", as: "T050-IMG_7544.jpg")
        let pipeline = ImagePipeline()
        let draft = PageDraft(
            sessionID: UUID(),
            quad: .fullImage,
            enhancement: .enhance
        )
        let rendered = try await pipeline.renderPage(original: input, draft: draft)
        let report = try loadReport(for: input)

        #expect(report.cropApplied)
        #expect(report.cropSource == "content_envelope")
        #expect((report.textCoverage ?? 0) >= 0.999)
        #expect((report.envelopeTextCoverage ?? 0) >= 0.999)
        #expect(report.fallbackReason == "content_envelope")
        #expect(report.chosen.topLeft != [0, 0])
        #expect(rendered.pixelSize.width > 0 && rendered.pixelSize.height > 0)

        let output = Self.evidenceDirectory.appending(path: "T050-IMG_7544-rendered.jpg")
        try rendered.jpeg.write(to: output)

        // 白底画布：裁切后输出图的左上角应是近白，而不是桌面/折页。
        let ui = try #require(UIImage(data: rendered.jpeg))
        let cg = try #require(ui.cgImage)
        let corner = try cornerRGB(cg, x: 2, y: 2)
        #expect(corner.0 > 235 && corner.1 > 235 && corner.2 > 235)

        // 幂等性：对输出的页面再跑一次整图 draft，裁切框不应继续明显收缩。
        let secondInput = Self.evidenceDirectory.appending(path: "T050-idempotence.jpg")
        try rendered.jpeg.write(to: secondInput)
        let second = try await ImagePipeline().renderPage(
            original: secondInput,
            draft: PageDraft(sessionID: UUID(), quad: .fullImage, enhancement: .enhance)
        )
        try second.jpeg.write(to: Self.evidenceDirectory.appending(path: "T050-idempotence-rendered.jpg"))
        _ = try loadReport(for: secondInput)
        // 输入已经带 0.6% 白底画布，第二次的归一化裁切框会从画布边缘起算，
        // 不能用两次的归一化面积直接比较；以最终输出页尺寸作为幂等性口径。
        #expect(abs(second.pixelSize.width - rendered.pixelSize.width) / rendered.pixelSize.width < 0.005)
        #expect(abs(second.pixelSize.height - rendered.pixelSize.height) / rendered.pixelSize.height < 0.005)
        #expect(second.pixelSize.width > 0)
    }

    @Test("三张中间图：实际 renderPage 只做诊断，不要求强制裁切")
    func intermediateImagesAreDiagnosticOnly() async throws {
        let inputs = [
            ("docs/media/optimize/myself-1-905BB50A-823F-43F8-AF77-14C3D465135B-rendered2.JPG",
             "T050-myself-1.JPG"),
            ("docs/media/optimize/myself-2-48CEE566-A11D-4BCF-908E-8E9EF773BAF7-rendered2.JPG",
             "T050-myself-2.JPG"),
            ("docs/media/optimize/myself-3-79B71462-24C5-4CFD-92C0-BE17D400D6E1.jpg",
             "T050-myself-3.jpg"),
        ]
        var summary: [[String: Any]] = []
        for (relative, copiedName) in inputs {
            let input = try copyInput(relative, as: copiedName)
            let pipeline = ImagePipeline()
            let draft = PageDraft(
                sessionID: UUID(),
                quad: .fullImage,
                enhancement: .enhance
            )
            let rendered = try await pipeline.renderPage(original: input, draft: draft)
            let report = try loadReport(for: input)
            let output = Self.evidenceDirectory
                .appending(path: copiedName)
                .deletingPathExtension()
                .appendingPathExtension("rendered.jpg")
            try rendered.jpeg.write(to: output)
            summary.append([
                "input": relative,
                "width": Int(rendered.pixelSize.width),
                "height": Int(rendered.pixelSize.height),
                "cropApplied": report.cropApplied,
                "cropSource": report.cropSource ?? "",
                "tableSafetyDecision": report.tableSafetyDecision ?? "",
                "fallbackReason": report.fallbackReason ?? "",
            ])
            #expect(rendered.pixelSize.width > 0)
            #expect(rendered.pixelSize.height > 0)
        }
        let data = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: Self.evidenceDirectory.appending(path: "T050-intermediate-summary.json"))
    }

    private func cornerRGB(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0, 0)
        }
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x),
                y: CGFloat(y - image.height + 1),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
