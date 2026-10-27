import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// CU-T003：自动模式也必须把左/右页意图传给检测器；意图切换需清旧轨迹。
@MainActor
struct CaptureIntentFlowTests {
    @Test("自动模式逐帧检测携带当前左/右页意图")
    func liveDetectionReceivesIntent() async throws {
        let defaults = UserDefaults(suiteName: "zhixia.intent.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        let camera = IntentCamera()
        let detector = IntentRecordingDetector()
        let viewModel = CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "intent-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences
        )
        viewModel.setCaptureIntent(.leftPage)
        await viewModel.start()
        await camera.yieldFrame()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, await detector.seenIntents.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let seen = await detector.seenIntents
        #expect(seen.contains(.leftPage), "自动模式必须把左页意图传给 detector，实际 \(seen)")
    }
}

private final class IntentCamera: CameraCapturing, @unchecked Sendable {
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

private actor IntentRecordingDetector: EdgeDetecting {
    private(set) var seenIntents: [CaptureIntent] = []
    private let page = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { page }

    func detect(
        frame: VideoFrame,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> Quad? {
        seenIntents.append(intent)
        return page
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { page }
    func detect(
        imageData: Data,
        idCardWindow: Quad?,
        intent: CaptureIntent
    ) async -> Quad? { page }
}
