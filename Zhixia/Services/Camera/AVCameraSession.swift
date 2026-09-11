@preconcurrency import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import UIKit

final class AVCameraSession: CameraCapturing, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoDelegate = VideoFrameTap()
    private let photoDelegate = PhotoCaptureTap()
    private let sessionQueue = DispatchQueue(label: "zhixia.camera.session")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var configured = false
    private var flashAuto = false
    private var frameContinuation: AsyncStream<VideoFrame>.Continuation?

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            self.sessionQueue.async {
                self.frameContinuation = continuation
            }
            continuation.onTermination = { _ in
                self.sessionQueue.async {
                    self.frameContinuation = nil
                    self.videoDelegate.onFrame = nil
                }
            }
            self.videoDelegate.onFrame = { buffer in
                self.emit(buffer)
            }
        }
    }

    func start() async throws {
        let granted = await MainActor.run {
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
        guard granted else { throw ZhixiaError.cameraDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    guard !self.session.inputs.isEmpty else {
                        throw ZhixiaError.cameraUnavailable
                    }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func bindPreview(_ layer: AnyObject) {
        guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func capturePhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let settings = AVCapturePhotoSettings()
                if self.photoOutput.supportedFlashModes.contains(.auto), self.flashAuto {
                    settings.flashMode = .auto
                } else if self.photoOutput.supportedFlashModes.contains(.off) {
                    settings.flashMode = .off
                }
                self.photoDelegate.finish = { result in
                    continuation.resume(with: result)
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self.photoDelegate)
            }
        }
    }

    func setTorch(enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          device.hasTorch
                    else {
                        continuation.resume()
                        return
                    }
                    try device.lockForConfiguration()
                    device.torchMode = enabled ? .on : .off
                    device.unlockForConfiguration()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setFlashAuto(_ enabled: Bool) async {
        sessionQueue.async {
            self.flashAuto = enabled
        }
    }

    private func emit(_ buffer: CMSampleBuffer) {
        guard let continuation = frameContinuation else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: imageBuffer).oriented(.right)
        let extent = ciImage.extent
        let scale = min(1, 720 / max(extent.width, extent.height))
        if scale < 1 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        continuation.yield(VideoFrame(cgImage: cgImage, timestamp: CACurrentMediaTime()))
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            throw ZhixiaError.cameraUnavailable
        }
        session.addInput(input)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(videoDelegate, queue: DispatchQueue(label: "zhixia.camera.frames"))
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()
        configured = true
    }
}

private final class VideoFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((CMSampleBuffer) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame?(sampleBuffer)
    }
}

private final class PhotoCaptureTap: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    var finish: ((Result<CapturedPhoto, Error>) -> Void)?

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish?(.failure(error))
            finish = nil
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finish?(.failure(ZhixiaError.captureFailed))
            finish = nil
            return
        }
        let dimensions = photo.resolvedSettings.photoDimensions
        finish?(
            .success(
                CapturedPhoto(
                    jpegData: data,
                    pixelSize: CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
                )
            )
        )
        finish = nil
    }
}
