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
        #expect(viewModel.drafts.last?.outputIntent == .rightPage, "拍摄意图应带到整理页")
        #expect(
            viewModel.drafts.last?.quadRole == .envelope,
            "目标缺失时拍的是包络：Review 必须尝试拆分，不得用宽高比猜成目标页"
        )
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
        #expect(viewModel.drafts.last?.quadRole == .target, "目标页拍摄不再二次拆分")
    }

    @Test("左页目标：右角落在书脊上，仍作为快门目标")
    func leftPageTargetWinsAtShutter() async throws {
        let envelope = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.05),
            topRight: CGPoint(x: 0.98, y: 0.05),
            bottomRight: CGPoint(x: 0.98, y: 0.92),
            bottomLeft: CGPoint(x: 0.02, y: 0.92)
        )
        // 左页右缘 = 书脊，远在整摊包络右缘左侧；这正是视频 7 里
        // “左页右上/右下角始终不出现”的目标框。
        let leftPage = Quad(
            topLeft: CGPoint(x: 0.02, y: 0.08),
            topRight: CGPoint(x: 0.50, y: 0.08),
            bottomRight: CGPoint(x: 0.50, y: 0.90),
            bottomLeft: CGPoint(x: 0.02, y: 0.90)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: envelope,
            target: leftPage,
            confidence: 0.9,
            intentSatisfied: true
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        viewModel.setCaptureIntent(.leftPage)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.outputTargetQuad == leftPage })
        #expect(viewModel.outputTargetQuad?.topRight.x == 0.50)
        #expect(viewModel.outputTargetQuad?.bottomRight.x == 0.50)

        await viewModel.capture()
        #expect(viewModel.drafts.last?.quad == leftPage)
        #expect(viewModel.drafts.last?.outputIntent == .leftPage)
        #expect(viewModel.drafts.last?.quadRole == .target)
    }

    @Test("屏幕整幅观测不得成为包络，也不得拍出 fullImage")
    func screenEdgeObservationIsRejected() async throws {
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: .fullImage,
            target: nil,
            confidence: 1,
            intentSatisfied: false
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        await viewModel.start()
        await camera.yieldFrame()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(viewModel.imageQuad == nil, "整幅外框不是书页，必须保持无框搜索态")
        #expect(!viewModel.isCaptureReady, "无可信包络时快门不可用")

        await viewModel.capture()
        #expect(viewModel.drafts.isEmpty, "不得把整张照片当成页面落盘")
    }

    @Test("整页意图：整摊被画幅边裁切（书没完整进框）时未就绪、快门不得拍")
    func clippedSpreadEnvelopeIsNotReady() async throws {
        // 整摊宽高比 >0.95：书左右两边都出屏（视频 12 场景），必须后退；
        // 单页近距（见 closeUpPageEnvelopeIsReady）不受此限制。
        let clipped = Quad(
            topLeft: CGPoint(x: 0.0, y: 0.20),
            topRight: CGPoint(x: 1.0, y: 0.20),
            bottomRight: CGPoint(x: 1.0, y: 0.62),
            bottomLeft: CGPoint(x: 0.0, y: 0.62)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: clipped,
            target: nil,
            confidence: 0.9,
            intentSatisfied: true
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        viewModel.setCaptureIntent(.wholePage)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.imageQuad != nil })

        #expect(viewModel.isFrameClipped, "整摊两边贴边 → 书没完整进框")
        #expect(!viewModel.isCaptureReady, "未就绪时快门不可用")
        await viewModel.capture()
        #expect(viewModel.drafts.isEmpty, "不得把残摊当整页拍下")
    }

    @Test("整页意图：近距单页（纸边贴画幅）允许拍，不被裁切门误伤")
    func closeUpPageEnvelopeIsReady() async throws {
        // 视频 14：用户贴近拍右页，单页包络下缘只距画幅 ~1%（裁掉的是
        // 纸边白边，不是页面内容）。旧规则把整页意图一律置灰；修订后
        // 单页（page-like）允许拍，整摊才拦。
        let page = Quad(
            topLeft: CGPoint(x: 0.10, y: 0.20),
            topRight: CGPoint(x: 0.90, y: 0.20),
            bottomRight: CGPoint(x: 0.90, y: 1.02),
            bottomLeft: CGPoint(x: 0.10, y: 1.02)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: page,
            target: nil,
            confidence: 0.9,
            intentSatisfied: true
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        viewModel.setCaptureIntent(.wholePage)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.imageQuad != nil })

        #expect(!viewModel.isFrameClipped, "单页纸边贴画幅不算“整摊被裁”")
        #expect(viewModel.isCaptureReady, "近距单页必须可拍")
        await viewModel.capture()
        let quad = try #require(viewModel.drafts.last?.quad)
        #expect(abs(quad.bottomLeft.y - 1.0) < 1e-9, "画幅外顶点钳到 1.0")
        #expect(abs(quad.bottomRight.y - 1.0) < 1e-9)
    }

    @Test("左/右页意图：目标页缺失时允许拍包络回退，不因整摊贴边而置灰")
    func clippedSpreadFallbackIsReady() async throws {
        // 视频 13：左页/右页目标短暂丢失时，旧规则因整摊贴边把整个取景
        // 变成虚线+灰快门，与目标出现时的实线来回抖。修订后无目标仍可
        // 拍包络，交给 Review 拆分。
        let envelope = Quad(
            topLeft: CGPoint(x: 0.0, y: 0.20),
            topRight: CGPoint(x: 1.0, y: 0.20),
            bottomRight: CGPoint(x: 1.0, y: 0.62),
            bottomLeft: CGPoint(x: 0.0, y: 0.62)
        )
        let camera = EnvelopeCamera()
        let detector = EnvelopeDetector(observation: CaptureEnvelopeObservation(
            envelope: envelope,
            target: nil,
            confidence: 0.9,
            intentSatisfied: false
        ))
        let viewModel = makeViewModel(camera: camera, detector: detector)
        await viewModel.start()
        await camera.yieldFrame()
        #expect(await waitUntil { viewModel.imageQuad != nil })

        #expect(!viewModel.isFrameClipped, "无目标页时按拍包络回退处理")
        #expect(viewModel.isCaptureReady)
        await viewModel.capture()
        #expect(viewModel.drafts.last?.quad == envelope)
        #expect(viewModel.drafts.last?.quadRole == .envelope)
    }

    @Test("左/右页意图：目标页近距贴边（单页）仍可拍")
    func clippedTargetPageIsReady() async throws {
        let envelope = Quad(
            topLeft: CGPoint(x: 0.0, y: 0.10),
            topRight: CGPoint(x: 1.0, y: 0.10),
            bottomRight: CGPoint(x: 1.0, y: 0.90),
            bottomLeft: CGPoint(x: 0.0, y: 0.90)
        )
        let rightPage = Quad(
            topLeft: CGPoint(x: 0.52, y: 0.15),
            topRight: CGPoint(x: 1.0, y: 0.15),
            bottomRight: CGPoint(x: 1.0, y: 0.85),
            bottomLeft: CGPoint(x: 0.52, y: 0.85)
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

        #expect(!viewModel.isFrameClipped, "目标页是单页，近距贴边可拍")
        #expect(viewModel.isCaptureReady)
        await viewModel.capture()
        #expect(viewModel.drafts.last?.quad == rightPage)
    }

    @Test("左/右页意图：目标页完整时，整摊包络被画幅边裁掉仍可拍")
    func completeTargetSurvivesClippedEnvelope() async throws {
        // 整摊左右都贴边（对页出屏），但右页本身四边留白完整——这是
        // 视频 12“只拍右页、左页在框外”的合法形态，不能因为包络被裁而拦拍。
        let envelope = Quad(
            topLeft: CGPoint(x: 0.0, y: 0.10),
            topRight: CGPoint(x: 1.0, y: 0.10),
            bottomRight: CGPoint(x: 1.0, y: 0.90),
            bottomLeft: CGPoint(x: 0.0, y: 0.90)
        )
        let rightPage = Quad(
            topLeft: CGPoint(x: 0.52, y: 0.15),
            topRight: CGPoint(x: 0.96, y: 0.15),
            bottomRight: CGPoint(x: 0.96, y: 0.85),
            bottomLeft: CGPoint(x: 0.52, y: 0.85)
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

        #expect(!viewModel.isFrameClipped, "判定只看目标页，不看被裁的整摊")
        #expect(viewModel.isCaptureReady)
        await viewModel.capture()
        #expect(viewModel.drafts.last?.quad == rightPage)
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
