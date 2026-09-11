@preconcurrency import AVFoundation
import UIKit

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let preview = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("CameraPreviewView must use AVCaptureVideoPreviewLayer")
        }
        return preview
    }
}
