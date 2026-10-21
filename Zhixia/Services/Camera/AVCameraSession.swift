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
    /// 几何测量值在多个队列间读写（帧队列写、快门回调写、sessionQueue 读），
    /// 统一用一把小锁保护；每帧一次 lock/unlock 的开销可忽略。
    private let geometryLock = NSLock()
    /// 实际送达帧的尺寸（emit 已转竖屏）——检测输入空间的真实度量。
    private var measuredFrameSize: CGSize?
    /// activeFormat 推得的照片竖屏宽高比估计；快门时以实际交付尺寸复核并自校正。
    private var photoAspectEstimate: Double?

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
        let photo: CapturedPhoto = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                // 会话未运行/未配置时，`AVCapturePhotoOutput.capturePhoto` 会抛
                // **ObjC 异常**（Swift 侧无法捕获 → 直接 SIGABRT 崩溃）。模拟器无
                // 相机、或相机启动失败后用户仍按快门时必现（2026-10-21 模拟器
                // 走查实测崩溃：`-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]`
                // → `objc_exception_throw` → abort）。这里前置守卫：不可用时抛
                // Swift 错误，由调用方转成用户可见提示。
                guard self.configured, self.session.isRunning else {
                    continuation.resume(throwing: ZhixiaError.cameraUnavailable)
                    return
                }
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
        crossCheckPhotoGeometry(pixelSize: photo.pixelSize)
        return photo
    }

    // MARK: - 取景几何（plan D2 / FR-007）

    /// 运行时测量的取景几何：视频宽高比取**实际送达帧**的尺寸，照片宽高比取
    /// `activeFormat` 尺寸估计（快门时以 `CapturedPhoto.pixelSize` 复核）。
    /// 不硬编码 16:9 / 4:3——模拟器与真机的组合差异正是本轮修复的对象。
    /// 未配置会话 → `CaptureGeometry.identity`（协议契约：恒等换算，不崩溃不变形）。
    func geometry() async -> CaptureGeometry {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.currentGeometry())
            }
        }
    }

    /// sessionQueue 上执行。
    private func currentGeometry() -> CaptureGeometry {
        guard configured else { return .identity }
        geometryLock.lock()
        let frameSize = measuredFrameSize
        let photoEstimate = photoAspectEstimate
        geometryLock.unlock()
        let photoAspect = photoEstimate ?? 1
        // 未收到帧时退回照片估计（真机 4:3 = 4:3 恒等；首帧到达后即被实测值取代）。
        let videoAspect: Double
        if let frameSize, frameSize.width > 0, frameSize.height > 0 {
            // emit 交付的帧已统一转竖屏，宽高比 = 宽 ÷ 高。
            videoAspect = Double(frameSize.width / frameSize.height)
        } else {
            videoAspect = photoAspect
        }
        return CaptureGeometry(videoAspect: videoAspect, photoAspect: photoAspect)
    }

    /// 快门复核（plan D2）：以实际交付照片尺寸校正照片宽高比估计，并记录差异日志。
    private func crossCheckPhotoGeometry(pixelSize: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        // 照片尺寸以传感器横向朝向交付（4032×3024）；竖屏宽高比与方向无关，
        // 取 min/max 即得（对竖向交付同样成立）。
        let capturedAspect = Double(
            min(pixelSize.width, pixelSize.height) / max(pixelSize.width, pixelSize.height)
        )
        geometryLock.lock()
        let previousEstimate = photoAspectEstimate
        photoAspectEstimate = capturedAspect
        geometryLock.unlock()
        let delta = previousEstimate.map { abs($0 - capturedAspect) } ?? 0
        let estimated = previousEstimate.map { String(format: "%.4f", $0) } ?? "nil"
        ZhixiaLog.capture.debug(
            "photoGeometry capturedAspect=\(capturedAspect, format: .fixed(precision: 4), privacy: .public) estimated=\(estimated, privacy: .public) delta=\(delta, format: .fixed(precision: 4), privacy: .public)"
        )
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
        // spec/frame-truth：分析帧长边 720→1080（1.5×线性）。真机证据：
        // 720p 帧上贴边吸附的逐边梯度峰值仅 0.05–0.07（阈值 0.08）——
        // 下采样把纸边糊成斜坡，锁定吸附全部零位移、框停在纸内。升到
        // 1080p 提升边缘锐度；检测请求按相对尺寸归一化，语义不变。
        let scale = min(1, 1080 / max(extent.width, extent.height))
        if scale < 1 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        geometryLock.lock()
        measuredFrameSize = CGSize(width: cgImage.width, height: cgImage.height)
        geometryLock.unlock()
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
        // 照片竖屏宽高比估计：activeFormat 尺寸在 .photo 预设下即照片输出FOV
        //（4032×3024 横向 → 竖屏 0.75）。快门时以 CapturedPhoto.pixelSize 复核。
        let dimensions = device.activeFormat.formatDescription.dimensions
        let formatWidth = Double(dimensions.width)
        let formatHeight = Double(dimensions.height)
        if formatWidth > 0, formatHeight > 0 {
            geometryLock.lock()
            photoAspectEstimate = min(formatWidth, formatHeight) / max(formatWidth, formatHeight)
            geometryLock.unlock()
        }
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
