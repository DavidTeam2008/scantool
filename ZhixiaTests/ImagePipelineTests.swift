import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Zhixia

struct ImagePipelineTests {
    @Test("Grayscale output has near-zero saturation")
    func grayscaleDesaturates() async throws {
        let pipeline = ImagePipeline()
        let color = makeJPEG(color: UIColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
        let gray = try await pipeline.apply(imageData: color, enhancement: .grayscale)
        let saturation = await pipeline.averageSaturation(imageData: gray)
        #expect(saturation < 0.08)
    }

    @Test("Perspective correction of a square stays roughly square")
    func squareStaysSquare() async throws {
        let pipeline = ImagePipeline()
        let jpeg = makeJPEG(color: .white, size: CGSize(width: 200, height: 200))
        let url = FileManager.default.temporaryDirectory.appending(path: "persp-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        let inset = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let data = try await pipeline.correct(original: url, quad: inset, rotationTurns: 0)
        let image = UIImage(data: data)
        let size = image?.size ?? .zero
        #expect(size.width > 10)
        #expect(abs((size.width / size.height) - 1) < 0.08)
    }

    private func makeJPEG(color: UIColor, size: CGSize = CGSize(width: 64, height: 64)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }
}
