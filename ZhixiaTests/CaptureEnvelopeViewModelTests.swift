import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// CF-T002：真实包络路径下，目标页缺失时仍显示/拍摄包络，不落 fullImage。
@MainActor
struct CaptureEnvelopeViewModelTests {
    @Test("目标页缺失时仍显示包络，快门使用包络而不是 fullImage")
    func envelopeFallbackSurvivesCapture() async throws {
        let envelope = Quad(
            topLeft: CGPoint(x: 0.08, y: 0.08),
            topRight: CGPoint(x: 0.92, y: 0.08),
            bottomRight: CGPoint(x: 0.92, y: 0.92),
            bottomLeft: CGPoint(x: 0.08, y: 0.92)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: envelope,
            target: nil,
            confidence: 0.8,
            intentSatisfied: false
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.imageQuad == envelope })
        #expect(viewModel.outputTargetQuad == nil)

        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == envelope)
        #expect(viewModel.drafts.last?.quad != .fullImage)
    }

    @Test("目标页可用时，快门使用目标页而不是整摊包络")
    func targetPageWinsAtShutter() async throws {
        let envelope = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.05),
            topRight: CGPoint(x: 0.98, y: 0.05),
            bottomRight: CGPoint(x: 0.98, y: 0.92),
            bottomLeft: CGPoint(x: 0.02, y: 0.92)
        )
        let rightPage = Quad(
            topLeft: CGPoint(x: 0.50, y: 0.08),
            topRight: CGPoint(x: 0.96, y: 0.08),
            bottomRight: CGPoint(x: 0.96, y: 0.90),
            bottomLeft: CGPoint(x: 0.50, y: 0.90)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: envelope,
            target: rightPage,
            confidence: 0.9,
            intentSatisfied: true
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.outputTargetQuad == rightPage })

        await viewModel.capture()
        #expect(viewModel.drafts.last?.quad == rightPage)
        #expect(viewModel.drafts.last?.quad != envelope)
    }

    private func makeViewModel(
        camera: EnvelopeCamera,
        detector: EnvelopeDetector
    ) -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.envelope.\(UUID().uuidString)") ?? .standard
        return CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "envelope-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private final class EnvelopeCamera: CameraCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private var index = 0

    func start() async throws {}
    func stop() async {}
    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(jpegData: PreviewImages.jpeg(), pixelSize: CGSize(width: 80, height: 100))
    }
    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}
    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }
    func geometry() async -> CaptureGeometry { .identity }

    func yieldFrame() async {
        let image = Self.plainImage
        while true {
            let continuation = lock.withLock { self.continuation }
            if let continuation {
                index += 1
                continuation.yield(VideoFrame(cgImage: image, timestamp: TimeInterval(index) / 30.0))
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let plainImage: CGImage = {
        let width = 8
        let height = 14
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

private actor EnvelopeDetector: EdgeDetecting, EnvelopeDetecting {
    private let observation: CaptureEnvelopeObservation?

    init(observation: CaptureEnvelopeObservation?) {
        self.observation = observation
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        observation?.envelope
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { nil }

    func observeEnvelope(
        frame: VideoFrame,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> CaptureEnvelopeObservation? {
        observation
    }

    func resetLiveTracking() async {}
    func resetEnvelopeTracking() async {}
}
