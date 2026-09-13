import CoreGraphics
import Foundation
import Vision

struct DetectedBarcode: Sendable, Equatable {
    var payload: String
    var bbox: CGRect
}

/// 条码检测能力的抽象。
///
/// 抽成协议是为了**可测**：实测（2026-09-12）`VNDetectBarcodesRequest` 在 iOS 模拟器上
/// **恒定返回 0 个结果** —— 拿真实样张、并显式打开全部 symbology 也是 0。
/// 所以任何依赖「模拟器里真能检出条码」的断言都是假绿。把检测注入进来，
/// 合并/去重这类**逻辑**才能在模拟器上被真正验证。
protocol BarcodeDetecting: Sendable {
    func detect(in image: CGImage) -> [DetectedBarcode]
}

/// 生产实现：`VNDetectBarcodesRequest`。⚠️ 模拟器上恒为空，必须真机验证。
struct VisionBarcodeDetector: BarcodeDetecting {
    func detect(in image: CGImage) -> [DetectedBarcode] {
        PageBarcodeDetector.detect(in: image)
    }
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
