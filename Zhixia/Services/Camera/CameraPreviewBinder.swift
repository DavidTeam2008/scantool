import Foundation

@MainActor
final class CameraPreviewBinder: CameraPreviewAttaching {
    private let bind: (AnyObject) -> Void

    init(bind: @escaping (AnyObject) -> Void) {
        self.bind = bind
    }

    convenience init(camera: AVCameraSession) {
        self.init { layer in
            camera.bindPreview(layer)
        }
    }

    func attachPreview(to layer: AnyObject) {
        bind(layer)
    }
}
