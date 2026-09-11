import CoreGraphics
import Foundation
import Vision

struct DetectedBarcode: Sendable, Equatable {
    var payload: String
    var bbox: CGRect
}

enum PageBarcodeDetector {
    static func detect(in image: CGImage) -> [DetectedBarcode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .ean13, .ean8, .upce, .code128, .code39]
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let box = CGRect(
                x: observation.boundingBox.minX,
                y: observation.boundingBox.minY,
                width: observation.boundingBox.width,
                height: observation.boundingBox.height
            )
            guard box.width > 0.02, box.height > 0.02 else { return nil }
            return DetectedBarcode(payload: payload, bbox: box)
        }
    }
}
