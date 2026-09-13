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
        // ⚠️ 视频输出连接**必须保持 0（不旋转）**，旋转只在 `emit` 里做一次。
        //
        // 真机反馈（2026-09-12）：拍照时的虚线框对不上书的边框，但成片是对的。
        // 根因是这里原本设了 90，而 `emit` 里又做了 `CIImage.oriented(.right)` ——
        // **转了两次**。预览层只转一次（`bindPreview` 的 90），于是检测出来的四边形
        // 坐标落在「多转了一次的画面」上：检测本身没错，但 `frameSize` 变成了横向
        // （720×405），`FrameMapper` 按 aspect-fill 算出 3.86 倍的水平拉伸，
        // 框被推到屏幕外 —— 看起来就是「虚线框捕不到书」。
        // 成片走的是 `AVCapturePhotoOutput` 的另一条链路，不受影响，所以一直是准的。
        //
        // 为什么设 0 而不是两个都留：`videoRotationAngle` 对 `AVCaptureVideoDataOutput`
        // 是否真的旋转 buffer，历史上随系统版本变过。**设 0 在两种情况下都成立** ——
        // 属性生效 → buffer 不旋转；属性不生效 → buffer 本来也是 sensor 原始朝向。
        // 两种结果都是「横向」，交给 `emit` 的 `.oriented(.right)` 统一转成竖向。
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
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
