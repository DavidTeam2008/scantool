import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Zhixia

/// US3 坐标链兜底（plan D1/D3，FR-006~009）：live 检测在 ViewModel 摄入边界
/// 换算到照片空间；overlay 映射走解析链（OverlaySpaceMap，T019——探针退役
/// 为诊断对照）。
@MainActor
struct CaptureFallbackTests {
    // MARK: - (a) live 框经 FOVLayout 视频→照片换算再入库

    @Test("Still detection failure falls back to the photo-space converted live quad")
    func fallbackConvertsLiveQuadToPhotoSpace() async throws {
        // 模拟器典型组合：竖屏 16:9 视频（0.5625）→ 4:3 照片（0.75）。
        let camera = ScriptedCamera(
            geometry: CaptureGeometry(videoAspect: 720.0 / 1280.0, photoAspect: 3.0 / 4.0),
            frameCount: 1
        )
        let detector = ScriptedDetector(
            liveQuad: TestQuads.fullSpan,
            stillQuad: nil // 静态检测失败 → 回退 live 框
        )
        let viewModel = makeViewModel(camera: camera, detector: detector)

        await viewModel.start()
        #expect(await waitUntil { viewModel.imageQuad != nil })
        let liveQuad = try #require(viewModel.imageQuad)

        // 摄入边界换算：视频 x∈[0,1] → 照片横向中心跨度 [0.125, 0.875]。
        #expect(abs(liveQuad.topLeft.x - 0.125) < 1e-9)
        #expect(abs(liveQuad.bottomLeft.x - 0.125) < 1e-9)
        #expect(abs(liveQuad.topRight.x - 0.875) < 1e-9)
        #expect(abs(liveQuad.bottomRight.x - 0.875) < 1e-9)
        // y 恒等（长轴共享）。
        #expect(abs(liveQuad.topLeft.y - 0.0) < 1e-9)
        #expect(abs(liveQuad.bottomRight.y - 1.0) < 1e-9)

        // 取景几何透出（T021）：overlay 解析式映射（OverlaySpaceMap）的单一真值源。
        #expect(viewModel.geometry == CaptureGeometry(videoAspect: 720.0 / 1280.0, photoAspect: 3.0 / 4.0))

        await viewModel.capture()
        let draftQuad = try #require(viewModel.drafts.first?.quad)
        // 回退入库的框与 live 框同一空间（照片），跨度数值一致。
        #expect(abs(draftQuad.topLeft.x - 0.125) < 1e-9)
        #expect(abs(draftQuad.topRight.x - 0.875) < 1e-9)
        #expect(abs(draftQuad.bottomLeft.x - 0.125) < 1e-9)
        #expect(abs(draftQuad.bottomRight.x - 0.875) < 1e-9)
    }

    // MARK: - (b) overlay 解析式映射（T019）：探针退役，渲染真值 = 解析链

    @Test("Overlay maps the photo quad analytically through the analytic chain")
    func overlayMapsAnalytically() {
        // 模拟器典型组合：竖屏 16:9 视频（0.5625）× 4:3 照片（0.75）。
        let geometry = CaptureGeometry(videoAspect: 720.0 / 1280.0, photoAspect: 3.0 / 4.0)
        let viewSize = CGSize(width: 390, height: 844)

        // 诊断日志源（FR-007 / SC-004）：解析式仿射参数 = 视频帧 aspectFill 放置矩形。
        let analytic = EdgeOverlayView.analyticTransform(geometry: geometry, viewSize: viewSize)
        let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)
        #expect(abs(analytic.scaleX - placement.width) < 1e-9)
        #expect(abs(analytic.scaleY - placement.height) < 1e-9)
        #expect(abs(analytic.offsetX - placement.minX) < 1e-9)
        #expect(abs(analytic.offsetY - placement.minY) < 1e-9)

        // 照片空间书框 x∈[0.125, 0.875] 恰是视频可见的中心跨度：
        // 照片→视频回到 x∈[0,1]，再随视频帧铺满放置矩形（宽度方向出屏裁切）。
        let screen = OverlaySpaceMap.screenQuad(
            fromPhotoQuad: TestQuads.photoSpan,
            geometry: geometry,
            viewSize: viewSize
        )
        #expect(abs(screen.topLeft.x - placement.minX) < 1e-9)
        #expect(abs(screen.topRight.x - placement.maxX) < 1e-9)
        // y-down 全链不翻转（FR-011）：y=0 → 屏幕顶部，y=1 → 屏幕底部。
        #expect(abs(screen.topLeft.y - 0) < 1e-9)
        #expect(abs(screen.bottomLeft.y - 844) < 1e-9)

        // 关键回归锚（旧缺陷「overlay 左右错位」的解析式版本）：放置宽度必须由
        // **视频**宽高比决定 —— 若误把照片宽高比直接 aspectFill 进屏幕，宽度会是
        // 0.75×844=633 而不是 0.5625×844=474.75，边框整体错位。
        #expect(abs(placement.width - 0.5625 * 844) < 1e-9)
        #expect(abs(placement.width - 0.75 * 844) > 1e-6)
    }

    // MARK: - (c) geometry 不可用 → 恒等换算不崩溃不变形

    @Test("Identity geometry leaves the live quad untouched")
    func identityGeometryIsNoOp() async throws {
        let camera = ScriptedCamera(geometry: .identity, frameCount: 1)
        let detector = ScriptedDetector(liveQuad: TestQuads.document, stillQuad: nil)
        let viewModel = makeViewModel(camera: camera, detector: detector)

        await viewModel.start()
        #expect(await waitUntil { viewModel.imageQuad != nil })

        // 恒等几何：不换算、不变形（FOVLayout 恒等分支原样返回）。
        #expect(viewModel.imageQuad == TestQuads.document)
        #expect(viewModel.geometry == .identity)

        await viewModel.capture()
        #expect(viewModel.drafts.first?.quad == TestQuads.document)
    }

    // MARK: - US4 可疑锁定门禁（plan D8，FR-010）

    @Test("Suspicious lock hugging the frame edge suppresses auto-capture")
    func suspiciousMarginSuppressesAutoCapture() async throws {
        // 贴边（左边距 0 < 1.5%，面积 0.792 < 0.95 → 单纯边距规则）。
        let camera = ScriptedCamera(geometry: .identity, frameCount: 15)
        let detector = ScriptedDetector(liveQuad: TestQuads.edgeHugging, stillQuad: nil)
        let viewModel = makeViewModel(camera: camera, detector: detector, autoCapture: true)

        await viewModel.start()
        // 15 帧恒定输入 ≈ 1s（fake 时钟：smoother 每稳定帧 +1/15s）→ 约 0.55s 锁定。
        #expect(await waitUntil { viewModel.overlayIsLocked })
        #expect(await waitUntil { viewModel.isAutoCaptureSuppressed })
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 可疑锁定：自动快门被抑制，等用户后退。
        #expect(viewModel.drafts.isEmpty)
    }

    @Test("Suspicious near-full lock suppresses auto-capture")
    func suspiciousAreaSuppressesAutoCapture() async throws {
        // 近满幅（面积 0.96 ≥ 0.95）。
        let camera = ScriptedCamera(geometry: .identity, frameCount: 15)
        let detector = ScriptedDetector(liveQuad: TestQuads.nearFull, stillQuad: nil)
        let viewModel = makeViewModel(camera: camera, detector: detector, autoCapture: true)

        await viewModel.start()
        #expect(await waitUntil { viewModel.overlayIsLocked })
        #expect(await waitUntil { viewModel.isAutoCaptureSuppressed })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(viewModel.drafts.isEmpty)
    }

    @Test("Normal lock auto-captures after the fake lock duration")
    func normalLockAutoCaptures() async throws {
        let camera = ScriptedCamera(geometry: .identity, frameCount: 15)
        let detector = ScriptedDetector(liveQuad: TestQuads.document, stillQuad: nil)
        let viewModel = makeViewModel(camera: camera, detector: detector, autoCapture: true)

        await viewModel.start()
        // 正常框（边距 ≥8%，面积 ≈0.65）：锁定后自动快门，行为与现状一致。
        #expect(await waitUntil { viewModel.drafts.count == 1 })
        #expect(viewModel.isAutoCaptureSuppressed == false)
    }

    @Test("Disabled auto-capture never fires regardless of lock state")
    func disabledAutoCaptureNeverFires() async throws {
        let camera = ScriptedCamera(geometry: .identity, frameCount: 15)
        let detector = ScriptedDetector(liveQuad: TestQuads.document, stillQuad: nil)
        let viewModel = makeViewModel(camera: camera, detector: detector, autoCapture: false)

        await viewModel.start()
        #expect(await waitUntil { viewModel.overlayIsLocked })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(viewModel.drafts.isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        camera: any CameraCapturing,
        detector: any EdgeDetecting,
        autoCapture: Bool = false
    ) -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.fallback.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        preferences.autoCapture = autoCapture
        return CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "fallback-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

// MARK: - 测试脚手架

/// 可注入几何与帧数的脚本相机：`geometry()` 返回构造值，帧流产出 N 帧后结束。
private final class ScriptedCamera: CameraCapturing, @unchecked Sendable {
    private let capturedGeometry: CaptureGeometry
    private let frameCount: Int

    init(geometry: CaptureGeometry, frameCount: Int) {
        self.capturedGeometry = geometry
        self.frameCount = frameCount
    }

    func start() async throws {}
    func stop() async {}

    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(
            jpegData: PreviewImages.jpeg(),
            pixelSize: CGSize(width: 4032, height: 3024)
        )
    }

    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            let image = ScriptedCamera.plainImage
            for index in 0..<frameCount {
                continuation.yield(VideoFrame(cgImage: image, timestamp: TimeInterval(index) / 15.0))
            }
            continuation.finish()
        }
    }

    func geometry() async -> CaptureGeometry { capturedGeometry }

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

/// 可注入 live/still 结果的脚本检测器。
private actor ScriptedDetector: EdgeDetecting {
    private let liveQuad: Quad?
    private let stillQuad: Quad?

    init(liveQuad: Quad?, stillQuad: Quad?) {
        self.liveQuad = liveQuad
        self.stillQuad = stillQuad
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { liveQuad }
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { stillQuad }
}

private enum TestQuads {
    /// 视频空间满幅：x∈[0,1]（换算后应为照片空间 [0.125, 0.875]）。
    static let fullSpan = Quad(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    /// 照片空间书框：x∈[0.125, 0.875]。
    static let photoSpan = Quad(
        topLeft: CGPoint(x: 0.125, y: 0),
        topRight: CGPoint(x: 0.875, y: 0),
        bottomRight: CGPoint(x: 0.875, y: 1),
        bottomLeft: CGPoint(x: 0.125, y: 1)
    )

    /// 常规文档框（恒等断言用，顶点带倾斜以暴露任何意外变形）。
    static let document = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.12),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.88, y: 0.9),
        bottomLeft: CGPoint(x: 0.08, y: 0.88)
    )

    /// 贴边框（US4 边距规则）：左边距 0 < 1.5%，面积 0.792 < 0.95。
    static let edgeHugging = Quad(
        topLeft: CGPoint(x: 0.0, y: 0.1),
        topRight: CGPoint(x: 0.99, y: 0.1),
        bottomRight: CGPoint(x: 0.99, y: 0.9),
        bottomLeft: CGPoint(x: 0.0, y: 0.9)
    )

    /// 近满幅框（US4 面积规则）：面积 0.96 ≥ 0.95。
    static let nearFull = Quad(
        topLeft: CGPoint(x: 0.0, y: 0.0),
        topRight: CGPoint(x: 1.0, y: 0.0),
        bottomRight: CGPoint(x: 1.0, y: 0.96),
        bottomLeft: CGPoint(x: 0.0, y: 0.96)
    )
}
