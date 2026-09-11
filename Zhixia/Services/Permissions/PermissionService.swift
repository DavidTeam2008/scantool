@preconcurrency import AVFoundation
import Foundation

struct PermissionService: PermissionGranting {
    func cameraStatus() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestCamera() async -> CameraAuthorization {
        let current = await cameraStatus()
        if current != .notDetermined {
            return current
        }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }
}
