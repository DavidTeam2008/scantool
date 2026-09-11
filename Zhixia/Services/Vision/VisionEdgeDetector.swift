import CoreGraphics
import Foundation
import ImageIO
import Vision

actor VisionEdgeDetector: EdgeDetecting {
    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        detect(
            cgImage: frame.cgImage,
            orientation: .up,
            idCardWindow: idCardWindow,
            stillImage: false
        )
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return detect(
            cgImage: image,
            orientation: imageOrientation(from: source),
            idCardWindow: idCardWindow,
            stillImage: true
        )
    }

    private func detect(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        idCardWindow: Quad?,
        stillImage: Bool
    ) -> Quad? {
        let rectangles = detectRectangles(
            cgImage: cgImage,
            orientation: orientation,
            relaxed: stillImage
        )
        let segmented = stillImage
            ? detectDocumentQuad(cgImage: cgImage, orientation: orientation)
            : nil
        let candidates = ([segmented].compactMap { $0 } + rectangles)
            .filter { !$0.isDegenerate && $0.area > 0.08 && $0.area < 0.96 }

        if let window = idCardWindow {
            if let match = candidates
                .filter({ $0.iou(with: window) > 0.45 })
                .max(by: { $0.score() < $1.score() })
            {
                return match
            }
            return window
        }

        return candidates.max(by: { $0.score() < $1.score() })
    }

    private func detectRectangles(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        relaxed: Bool
    ) -> [Quad] {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = relaxed ? 0.35 : 0.6
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = relaxed ? 0.08 : 0.25
        request.maximumObservations = relaxed ? 8 : 4
        request.quadratureTolerance = relaxed ? 28 : 20

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.debug("Vision rectangle failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).map(observationToQuad)
    }

    private func detectDocumentQuad(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            ZhixiaLog.capture.debug("Document segmentation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let quad = observationToQuad(observation)
        guard !quad.isDegenerate, quad.area > 0.08, quad.area < 0.96 else {
            return nil
        }
        return quad
    }

    private func observationToQuad(_ observation: VNRectangleObservation) -> Quad {
        Quad(
            topLeft: flipY(observation.topLeft),
            topRight: flipY(observation.topRight),
            bottomRight: flipY(observation.bottomRight),
            bottomLeft: flipY(observation.bottomLeft)
        )
    }

    private func flipY(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    private func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }
}
